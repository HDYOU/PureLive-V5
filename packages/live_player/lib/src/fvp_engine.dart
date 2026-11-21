import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show AppLifecycleState;
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver;
import 'package:fvp/mdk.dart' as mdk;
import 'package:live_media/live_media.dart';
import 'package:live_player/src/engine.dart';
import 'package:live_player/src/playback_stats.dart';

/// The platforms fvp runs on, for its decoder names.
enum FvpPlatform {
  /// Android.
  android,

  /// iOS.
  ios,

  /// Windows.
  windows,

  /// Linux.
  linux,

  /// macOS.
  macos,
}

/// The [FvpPlatform] of a Flutter [platform]; null on Fuchsia.
FvpPlatform? fvpPlatformOf(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => FvpPlatform.android,
  TargetPlatform.iOS => FvpPlatform.ios,
  TargetPlatform.windows => FvpPlatform.windows,
  TargetPlatform.linux => FvpPlatform.linux,
  TargetPlatform.macOS => FvpPlatform.macos,
  TargetPlatform.fuchsia => null,
};

/// How `FvpEngine` configures libmdk (the subset of the player settings the
/// second engine reads, G01). The mpv-only settings (output drivers, the
/// custom `hwdec` name, RTX VSR, compatibility mode) have no meaning here.
@immutable
final class FvpEngineConfig {
  /// Creates a configuration; the defaults are 3.x's default settings.
  const new({
    this.platform = FvpPlatform.android,
    this.hardwareDecoding = true,
    this.volumeGainDb = 0,
    this.prepareTimeoutMs = 8000,
  });

  /// The platform the decoder names are for.
  final FvpPlatform platform;

  /// 3.x's "硬件解码" (`enableCodec`): libmdk's hardware decoder first.
  final bool hardwareDecoding;

  /// "音量增强": gain in dB applied on top of the volume; 0 leaves the
  /// sound alone. libmdk has no mpv `volume-gain`, so the gain multiplies
  /// the volume of this engine instead.
  final int volumeGainDb;

  /// The largest [volumeGainDb] (mpv's own `volume-gain-max` is 12).
  static const maxVolumeGainDb = 12;

  /// How long an open's [mdk.Player.prepare] is waited for before the open
  /// is abandoned and the current picture kept. A line that stalls in prepare
  /// (a dead CDN, a slow network) then does not hold the player black; the
  /// session can retry or fail it.
  final int prepareTimeoutMs;
}

/// The video decoders libmdk tries, in order: when decoding by hardware the
/// platform's hardware decoders come first (each in the order that suits the
/// platform's own hardware), then FFmpeg's software decoders and the
/// stand-alone `dav1d` AV1 one, so a profile a hardware decoder rejects still
/// plays (3.x's own fvp adapter relied on the same fallback). Hardware
/// decoding off decodes with FFmpeg alone.
///
/// The Linux entry is device-dependent; the reference ordering picks it from
/// the device (Rockchip, a Raspberry Pi, or a generic desktop GPU), here the
/// generic desktop order (VAAPI, CUDA, VDPAU, ...) is used: `fvpVideoDecoders`
/// stays framework-agnostic, and a device-specific Linux build can override
/// it.
List<String> fvpVideoDecoders(FvpPlatform platform, {required bool hardwareDecoding}) {
  if (!hardwareDecoding) return const ['FFmpeg'];
  final hardware = switch (platform) {
    FvpPlatform.android => const ['AMediaCodec', 'MediaCodec', 'FFmpeg', 'dav1d'],
    FvpPlatform.ios => const ['VT', 'FFmpeg', 'dav1d'],
    FvpPlatform.macos => const ['VT', 'hap', 'FFmpeg', 'dav1d'],
    FvpPlatform.windows => const ['MFT:d3d=11', 'D3D11', 'DXVA', 'CUDA', 'hap', 'FFmpeg', 'dav1d'],
    // The generic desktop Linux order; a Rockchip or Pi build picks its own
    // (rockchip / rkmpp, or V4L2M2M / drm) ahead of these.
    FvpPlatform.linux => const ['VAAPI', 'CUDA', 'VDPAU', 'hap', 'FFmpeg', 'dav1d'],
  };
  return hardware;
}

/// The request headers as libmdk's `avio.headers` value: one
/// `Name: value\r\n` line each; empty for none.
String fvpHeaderLines(Map<String, String> headers) =>
    [for (final MapEntry(:key, :value) in headers.entries) '$key: $value\r\n'].join();

/// The displayed size of a video stream: the sample aspect ratio applied to
/// the coded height, then a quarter turn swapped (3.x's
/// `resolveVideoParamsDisplaySize`, which mpv reports the same way).
({int width, int height})? fvpDisplaySizeOf({
  required int width,
  required int height,
  double par = 1,
  int rotation = 0,
}) {
  if (width <= 0 || height <= 0) return null;
  var displayWidth = width;
  var displayHeight = par > 0 && par != 1 ? (height / par).round() : height;
  if (displayHeight <= 0) displayHeight = height;
  if (rotation % 180 == 90) (displayWidth, displayHeight) = (displayHeight, displayWidth);
  return (width: displayWidth, height: displayHeight);
}

/// One libmdk player with its subscriptions and its per-instance state. The
/// engine keeps two of these: [_currentPlayer] (the picture being shown) and
/// [_nextPlayer] (a prepare in progress that takes over on success).
class _PlayerInstance {
  _PlayerInstance(this.player, this.config, this.tag);

  /// The libmdk player.
  final mdk.Player player;

  /// The engine's configuration.
  final FvpEngineConfig config;

  /// A log tag: `current` or `next`, so a line's own prepare and teardowns
  /// read in order in the logs.
  final String tag;

  final List<StreamSubscription<Object?>> subscriptions = [];
  var hasSource = false;
  var buffering = false;
  var audioOnly = false;
  var externalAudio = false;
  ({int width, int height})? lastSize;
  double? lastFrameRate;
  var mediaInfoReported = false;

  /// Re-applies the persistent libmdk properties to [player].
  void configure() {
    player
      // A hardware video decoder without the extra shader resources.
      ..setProperty('video.decoder', 'shader_resource=0')
      // Accept the experimental stream formats and segment files 3.x plays
      // (its own player set these on creation).
      ..setProperty('avformat.strict', 'experimental')
      ..setProperty('avformat.safe', '0')
      // A live line that drops is reconnected by libmdk itself; the session
      // still sees the stall through the position and its buffering flags.
      ..setProperty('avio.reconnect', '1')
      ..setProperty('avio.reconnect_delay_max', '7')
      // An RTSP line rides over TCP, and the extension picker accepts every
      // segment file type.
      ..setProperty('avformat.rtsp_transport', 'tcp')
      ..setProperty('avformat.extension_picky', '0')
      ..setProperty('avformat.allowed_segment_extensions', 'ALL');
  }

  /// Cancels this instance's stream subscriptions.
  void disposeSubscriptions() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    subscriptions.clear();
  }

  /// Releases this instance's player, dropping its texture and native
  /// resources. Errors are logged, never thrown: teardown must not fail.
  Future<void> safeDispose() async {
    disposeSubscriptions();
    try {
      await player.updateTexture(width: -1);
    } catch (e, st) {
      debugPrint('[$tag] safeDispose updateTexture error: $e\n$st');
    }
    try {
      await player.disposeAsync();
    } catch (e, st) {
      debugPrint('[$tag] safeDispose disposeAsync error: $e\n$st');
    }
    debugPrint('[$tag] player disposed');
  }
}

/// The fvp (libmdk) [PlayerEngine]: the second engine of the player page
/// (`Settings.playbackEngine`, G01), drawn through a Flutter texture
/// ([TextureVideoHost]) instead of media_kit's `Video`.
///
/// - Every open prepares a **new** native player (`_nextPlayer`) with the
///   request headers, the proxy and the decoder order, then loads the media
///   with its external audio (a split stream's rendition,
///   `setMedia(type: audio)`) and prepares it at the start position.
/// - **On a successful prepare, the new player takes over atomically**: it
///   becomes [_currentPlayer], its streams are bound, its texture is created
///   and it starts playing, while the old [_currentPlayer] is released
///   asynchronously (its picture stays up until the switch is done, so a
///   line switch never shows a black gap). A failed or timed-out prepare
///   discards the new player and keeps the current one, throwing so the
///   session treats the line as failing.
/// - libmdk reports playback state, media status (buffering, end, invalid)
///   and events; the position is read four times a second, as the session
///   judges a live source by whether it moves.
/// - Audio-only mode disables the video track in the current player instead
///   of reopening, as mpv turns its video output off.
/// - Windows reports no presented frames here (`reportsFrames` false), so
///   the frame watchdog does not apply to this engine.
final class FvpEngine implements PlayerEngine, PlaybackRate, PlaybackStatsSource, VolumeGainControl, TextureVideoHost {
  new _(this.config) {
    _initCurrentPlayer();
  }

  /// Creates the current native player and the app-lifecycle observer. Needs
  /// a Flutter binding and libmdk for this platform (the fvp plugin's build
  /// hook provides it).
  static Future<FvpEngine> create({FvpEngineConfig? config}) async {
    final resolved = config ?? const FvpEngineConfig();
    try {
      final engine = FvpEngine._(resolved);
      // When the app returns from the background, libmdk's texture may have
      // been dropped; the observer reopens so the picture comes back.
      engine._lifecycleObserver.bind(engine);
      WidgetsBinding.instance.addObserver(engine._lifecycleObserver);
      return engine;
    } on Object catch (error, stack) {
      throw PlayerException(
        message: 'The fvp engine could not start: $error',
        type: PlayerErrorType.native,
        code: 'fvp_engine_create',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// The libmdk player currently showing the picture; null before the first
  /// open or after stop.
  _PlayerInstance? _currentPlayer;

  /// A prepare in progress that will become [_currentPlayer] on success;
  /// null while no open is pending.
  _PlayerInstance? _nextPlayer;

  /// Configuration.
  final FvpEngineConfig config;

  late final StreamController<EngineEvent> _events = StreamController.broadcast(sync: true);
  late final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  late final ValueNotifier<Size?> _frameSize = ValueNotifier<Size?>(null);

  Timer? _ticker;
  var _disposed = false;
  var _opens = 0; // A sequence number: a stale async open cannot clobber a newer state.
  var _volume = 1.0;
  var _gainDb = 0;
  EngineMedia? _lastMedia;
  var _lifecycleObserver = _TextureLifecycleObserver();

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  bool get reportsFrames => false;

  @override
  ValueListenable<int?> get textureId => _textureId;

  @override
  ValueListenable<Size?> get frameSize => _frameSize;

  void _add(EngineEvent event) {
    if (!_disposed) _events.add(event);
  }

  /// The settings that stay on a player between sources.
  void _initCurrentPlayer() {
    final ins = _PlayerInstance(mdk.Player(), config, 'current');
    ins.configure();
    _currentPlayer = ins;
    debugPrint('[FvpEngine] init currentPlayer ok');
  }

  /// Binds [ins]'s streams to the engine's event stream. Safe to call again
  /// after a new player was created: it first cancels the previous bindings.
  void _bindCurrentPlayer(_PlayerInstance ins) {
    ins.disposeSubscriptions();
    ins.subscriptions
      ..add(
        ins.player.onStateChanged.listen((event) {
          if (_disposed) return;
          switch (event.newValue) {
            case mdk.PlaybackState.playing:
              _add(const EnginePlaying(playing: true));
            case mdk.PlaybackState.paused:
              _add(const EnginePlaying(playing: false));
            case mdk.PlaybackState.stopped || mdk.PlaybackState.notRunning || mdk.PlaybackState.running:
              break;
          }
        }),
      )
      ..add(
        ins.player.onMediaStatus.listen((event) {
          if (_disposed) return;
          _onStatus(ins, event.newValue);
        }),
      )
      ..add(
        ins.player.onEvent.listen((event) {
          if (_disposed) return;
          // The first decoded frame tells the picture's size when the probe
          // did not (libmdk fills `mediaInfo.video` at load).
          if (event.category == 'decoder.video') _emitSize(ins);
          _logEvent(event, ins.tag);
        }),
      );
  }

  void _onStatus(_PlayerInstance ins, mdk.MediaStatus status) {
    if (status.test(mdk.MediaStatus.invalid) && ins.hasSource) {
      ins.hasSource = false;
      _stopTicker();
      _add(
        const EngineError(
          PlayerException(
            message: 'libmdk rejected the source',
            type: PlayerErrorType.source,
            code: 'fvp_source_invalid',
          ),
        ),
      );
      return;
    }
    if (status.test(mdk.MediaStatus.end)) _add(const EngineCompleted());
    final buffering = status.test(mdk.MediaStatus.buffering) || status.test(mdk.MediaStatus.stalled);
    if (buffering != ins.buffering) {
      ins.buffering = buffering;
      _add(EngineBuffering(buffering: buffering));
    }
    if (status.test(mdk.MediaStatus.loaded)) _emitSize(ins);
  }

  /// Prints a libmdk event that carries an error code, so a failing source
  /// (a dropped connection, a refused line, a decode fault) is visible in
  /// the logs. The `error` field doubles as buffering progress when the
  /// category is `reader.buffering`, which is not an error and is skipped.
  void _logEvent(mdk.MediaEvent event, String tag) {
    if (event.error == 0) return;
    if (event.category == 'reader.buffering') return;
    debugPrint('[$tag] fvp error: code=${event.error} category=${event.category} detail=${event.detail}');
  }

  /// Reports the picture's size of [ins] once per open when it is known.
  void _emitSize(_PlayerInstance? ins) {
    if (_disposed) return;
    final target = ins ?? _currentPlayer;
    if (target == null) return;
    final ({int width, int height})? size;
    try {
      final streams = target.player.mediaInfo.video;
      if (streams == null || streams.isEmpty) return;
      final stream = streams.first;
      size = fvpDisplaySizeOf(
        width: stream.codec.width,
        height: stream.codec.height,
        par: stream.codec.par,
        rotation: stream.rotation,
      );
    } on Object {
      return;
    }
    if (size == null || size == target.lastSize) {
      _emitFrameRate(target);
      return;
    }
    target.lastSize = size;
    _frameSize.value = Size(size.width.toDouble(), size.height.toDouble());
    _add(EngineVideoSize(size.width, size.height));
    _emitFrameRate(target);
  }

  /// Reports the source's frame rate once per open when it is known. libmdk
  /// fills `mediaInfo.video.codec.frameRate` as the video track is probed
  /// (the `loaded` status), so a line whose rate is missing from the first
  /// probe still reports it once the probe completes.
  void _emitFrameRate(_PlayerInstance target) {
    if (_disposed) return;
    final fps = _videoFrameRate(target);
    if (fps != null && fps != target.lastFrameRate) {
      target.lastFrameRate = fps;
      _add(EngineFrameRate(fps));
    }
  }

  int _durationMs(_PlayerInstance? ins) {
    try {
      return (ins ?? _currentPlayer)?.player.mediaInfo.duration ?? 0;
    } on Object {
      return 0;
    }
  }

  double? _videoFrameRate(_PlayerInstance target) {
    try {
      final streams = target.player.mediaInfo.video;
      final fps = streams == null || streams.isEmpty ? 0.0 : streams.first.codec.frameRate;
      return fps > 0 && fps.isFinite ? fps : null;
    } on Object {
      return null;
    }
  }

  /// A one-shot re-check of [ins]' frame rate, run a moment after a switch so
  /// a live source whose frameRate probe lands after prepare is still
  /// reported. [openSeq] guards against a newer open having taken over: only
  /// the instance still showing the picture (the current player) is re-checked.
  void _reopenFrameRateCheck(int openSeq, _PlayerInstance ins) {
    if (_disposed || openSeq != _opens) return;
    if (!identical(_currentPlayer, ins)) return;
    _emitFrameRate(ins);
  }

  /// The per-open properties of [ins]: headers, proxy and the decoder order.
  void _applyInstanceProperties(_PlayerInstance ins, EngineMedia media) {
    ins.player
      ..setProperty('avio.headers', media.headers.isEmpty ? '' : fvpHeaderLines(media.headers))
      ..setProperty('avio.http_proxy', media.proxyUrl)
      ..setProperty('avformat.http_proxy', media.proxyUrl)
      ..videoDecoders = fvpVideoDecoders(
        config.platform,
        hardwareDecoding: media.decoder == DecoderMode.hardware && config.hardwareDecoding,
      );
  }

  /// 【核心 open 双播放器逻辑】
  ///
  /// 1. 创建 nextPlayer（预加载实例），设置媒体，带超时执行 prepare。
  /// 2. prepare 成功：原子切换——旧 current 异步释放，next 升级为 current，
  ///    绑定事件、创建 texture、开始输出画面。
  /// 3. prepare 失败 / 超时 / 被更新的 open 取代：销毁 nextPlayer，
  ///    current 保持原样，失败则抛出异常让会话判定该线路失败。
  @override
  Future<void> open(EngineMedia media) async {
    final openSeq = ++_opens;
    _lastMedia = media;
    if (_disposed) return;

    debugPrint('[FvpEngine][seq=$openSeq] open start uri=${media.uri}');
    // 1. 创建 nextPlayer（预加载实例）。
    final nextIns = _PlayerInstance(mdk.Player(), config, 'next');
    nextIns.configure();
    _nextPlayer = nextIns;

    try {
      // 设置 headers/proxy/decoder。
      _applyInstanceProperties(nextIns, media);
      nextIns.player.media = media.uri.toString();
      final audio = media.audio;
      nextIns.externalAudio = audio != null;
      if (audio != null) {
        // A split stream's sound (A17.6): an external audio source of this
        // player, fetched with the same headers and proxy as the video.
        nextIns.player.setMedia(audio.uri.toString(), mdk.MediaType.audio);
      }
      final start = media.start?.inMilliseconds ?? 0;

      // 带超时的 prepare：超时则放弃该线路，current 维持原样。
      final prepareRet = await Future.any<int>([
        nextIns.player.prepare(position: math.max(0, start)),
        Future<void>.delayed(Duration(milliseconds: config.prepareTimeoutMs))
            .then(
              (_) => throw PlayerException(
                message: 'nextPlayer prepare timeout ${config.prepareTimeoutMs}ms',
                type: PlayerErrorType.source,
                code: 'fvp_prepare_timeout',
              ),
            ),
      ]);

      if (_disposed || openSeq != _opens) {
        debugPrint('[FvpEngine][seq=$openSeq] open discarded, newer open arrived');
        await nextIns.safeDispose();
        _nextPlayer = null;
        return;
      }

      if (prepareRet < 0) {
        throw PlayerException(
          message: 'libmdk could not prepare the source ($prepareRet)',
          type: PlayerErrorType.source,
          code: 'fvp_open_${prepareRet.clamp(-99, -1)}',
        );
      }

      // ---------------- prepare 成功：执行切换 ----------------
      debugPrint('[FvpEngine][seq=$openSeq] next prepare success, start switch');
      final oldCurrent = _currentPlayer;

      // nextPlayer 设置音视频轨道。
      await _setInstanceVideoTrack(nextIns, enabled: !media.audioOnly);
      nextIns.hasSource = true;

      // 绑定对外事件到新 current。
      _bindCurrentPlayer(nextIns);

      // 创建 texture。
      if (!media.audioOnly) {
        await _createInstanceTexture(nextIns, openSeq);
      }

      // 状态迁移。
      _currentPlayer = nextIns;
      _nextPlayer = null;

      // 旧播放器异步释放，不阻塞 open 流程，旧画面会维持到切换完成。
      unawaited(oldCurrent?.safeDispose());
      debugPrint('[FvpEngine][seq=$openSeq] switch done, old current dispose async');

      // 新实例开始播放。
      nextIns.player.state = mdk.PlaybackState.playing;
      _applyVolume(nextIns);

      // 上报时长、帧率。
      final duration = _durationMs(nextIns);
      if (media.onDemand && duration > 0) {
        _add(EngineDuration(Duration(milliseconds: duration)));
      }
      // Report the frame rate now if the probe already filled it; a live
      // source's frameRate often lands after prepare, so a delayed re-check
      // below picks it up once the probe completes.
      _emitFrameRate(nextIns);
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 800))
            .then((_) => _reopenFrameRateCheck(openSeq, nextIns)),
      );

      _emitSize(nextIns);
      _startTicker();
    } on PlayerException {
      // nextPlayer 失败，销毁 next，保留 currentPlayer。
      debugPrint('[FvpEngine][seq=$openSeq] next prepare failed, keep current, error rethrow');
      await nextIns.safeDispose();
      _nextPlayer = null;
      rethrow;
    } on Object catch (error, stack) {
      debugPrint('[FvpEngine][seq=$openSeq] next prepare unknown error $error');
      await nextIns.safeDispose();
      _nextPlayer = null;
      throw PlayerException(
        message: 'libmdk could not open the source: $error',
        type: PlayerErrorType.source,
        code: 'fvp_open_failed',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// Reopens the source after the app returns from the background, when
  /// libmdk has dropped its texture and decoder. Re-calling [open] prepares
  /// a fresh native player and re-creates the texture, so a new frame is
  /// pulled through the decoder instead of the last frozen one.
  Future<void> _onAppResumed() async {
    final media = _lastMedia;
    if (_disposed || _currentPlayer?.hasSource != true || media == null) return;
    try {
      await open(media);
    } on Object {
      // A failed reopen keeps the last picture state; the next open
      // recovers it.
    }
  }

  /// Creates the texture of [ins]'s picture (libmdk sizes it to the video's
  /// own frame, so the view keeps the aspect ratio). A failure throws
  /// instead of leaving a silent black picture.
  Future<void> _createInstanceTexture(_PlayerInstance ins, int openSeq) async {
    final id = await ins.player.updateTexture();
    if (id < 0) {
      throw PlayerException(
        message: 'libmdk could not create the video texture (updateTexture returned $id)',
        type: PlayerErrorType.native,
        code: 'fvp_texture_failed',
      );
    }
    if (_disposed || openSeq != _opens) {
      // A newer open took over while the texture was being made: drop it
      // without showing the old picture.
      try {
        await ins.player.updateTexture(width: -1);
      } on Object {
        // The player may already have dropped it.
      }
      return;
    }
    _textureId.value = id;
    debugPrint('[${ins.tag}] textureId=$id');
  }

  /// Turns [ins]' video track off or on without reopening, as mpv turns its
  /// video output off (`audio-only` mode).
  Future<void> _setInstanceVideoTrack(_PlayerInstance ins, {required bool enabled}) async {
    if (enabled == !ins.audioOnly) return;
    // Turning video off drops the picture, and back on re-reports its size
    // even when it is the same as before.
    if (!enabled) {
      ins.lastSize = null;
      ins.lastFrameRate = null;
      ins.mediaInfoReported = false;
    }
    ins.player.setActiveTracks(mdk.MediaType.video, enabled ? const [0] : const []);
    ins.audioOnly = !enabled;
  }

  /// Reports the position of the current source four times a second (mpv's
  /// `time-pos` stream, which the session uses to tell moving playback from
  /// a stall).
  void _startTicker() {
    _stopTicker();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final ins = _currentPlayer;
      if (_disposed || ins == null || !ins.hasSource) return;
      try {
        _add(EnginePosition(Duration(milliseconds: ins.player.position)));
      } on Object {
        _stopTicker();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  Future<void> play() async {
    final ins = _currentPlayer;
    if (_disposed || ins == null) return;
    ins.player.state = mdk.PlaybackState.playing;
  }

  @override
  Future<void> pause() async {
    final ins = _currentPlayer;
    if (_disposed || ins == null) return;
    ins.player.state = mdk.PlaybackState.paused;
  }

  @override
  Future<void> stop() async {
    _opens++;
    _lastMedia = null;
    _stopTicker();
    if (_disposed) return;
    // 停止 next 预加载。
    await _nextPlayer?.safeDispose();
    _nextPlayer = null;

    final curr = _currentPlayer;
    if (curr != null) {
      curr.player.state = mdk.PlaybackState.stopped;
      try {
        await curr.player.updateTexture(width: -1);
      } on Object {
        // The player may already have dropped the texture.
      }
      curr.hasSource = false;
      curr.lastSize = null;
    }
    _frameSize.value = null;
    _textureId.value = null;
    debugPrint('[FvpEngine] stop');
  }

  @override
  Future<void> seek(Duration position) async {
    final ins = _currentPlayer;
    if (_disposed || ins == null || !ins.hasSource) return;
    await ins.player.seek(position: math.max(0, position.inMilliseconds));
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1).toDouble();
    _applyVolume(_currentPlayer);
  }

  @override
  Future<void> setVolumeGainDb(int? decibels) async {
    final gain = decibels?.clamp(-FvpEngineConfig.maxVolumeGainDb, FvpEngineConfig.maxVolumeGainDb);
    _gainDb = gain ?? config.volumeGainDb;
    _applyVolume(_currentPlayer);
  }

  /// libmdk multiplies the source volume; the gain is folded into it (mpv
  /// keeps them apart).
  void _applyVolume(_PlayerInstance? ins) {
    if (_disposed || ins == null) return;
    final gain = math.pow(10, _gainDb / 20).toDouble();
    ins.player.volume = (_volume * gain).clamp(0, 8).toDouble();
  }

  @override
  Future<void> setRate(double rate) async {
    final ins = _currentPlayer;
    if (_disposed || ins == null) return;
    ins.player.playbackRate = rate.clamp(0.25, 4).toDouble();
  }

  @override
  Future<void> setAudioOnly({required bool enabled}) async {
    final ins = _currentPlayer;
    if (_disposed || ins == null || !ins.hasSource) return;
    await _setInstanceVideoTrack(ins, enabled: !enabled);
    if (enabled) return;
    _emitSize(ins);
    await _createInstanceTexture(ins, _opens);
  }

  @override
  Future<PlaybackStats> readStats() async {
    final ins = _currentPlayer;
    if (_disposed || ins == null) return const PlaybackStats();
    try {
      final info = ins.player.mediaInfo;
      // A diagnostic of the libmdk media info, once per open. The panel polls
      // readStats each second, so the flag keeps it from spamming. libmdk's
      // MediaInfo carries FFI byte lists, so its own toString (which formats
      // every field) is what can be logged, not jsonEncode of the object.
      if (ins.hasSource && !ins.mediaInfoReported) {
        ins.mediaInfoReported = true;
        debugPrint('fvp mediaInfo: $info');
      }
      final video = info.video?.isEmpty ?? true ? null : info.video!.first;
      final audio = info.audio?.isEmpty ?? true ? null : info.audio!.first;

      // Seconds of media held in libmdk's cache; the panel's "缓冲" row.
      int? bufferedMs;
      try {
        bufferedMs = ins.player.buffered();
      } on Object {
        bufferedMs = null;
      }
      final bufferSeconds = bufferedMs == null || bufferedMs <= 0 ? null : bufferedMs / 1000;

      // The current download bit rate in bytes a second; libmdk updates
      // `mediaInfo.bitRate` to the realtime value while playing. The panel
      // smooths it over a few polls, as it does for mpv's cache-speed.
      final bitrate = info.bitRate;
      final downloadBytesPerSecond = bitrate > 0 ? bitrate / 8.0 : null;

      // libmdk's build version (the integer `MDK_version`); shown as
      // "mdk-N" next to the engine name where it is available. There is no
      // FFmpeg version to read.
      int? mdkVersion;
      try {
        mdkVersion = mdk.version();
      } on Object {
        mdkVersion = null;
      }
      final mdkBuild = mdkVersion == null ? null : 'mdk-$mdkVersion';

      return PlaybackStats(
        width: video?.codec.width,
        height: video?.codec.height,
        videoFormat: video?.codec.codec,
        videoCodec: video?.codec.codec,
        encoder: _encoderMetadata(video) ?? _encoderMetadata(audio),
        sampleRate: audio?.codec.sampleRate,
        channels: audio?.codec.channels,
        audioBitrate: audio?.codec.bitRate,
        audioCodec: audio?.codec.codec,
        bufferSeconds: bufferSeconds,
        downloadBytesPerSecond: downloadBytesPerSecond,
        mpvVersion: mdkBuild,
      );
    } on Object {
      return const PlaybackStats();
    }
  }

  /// The encoder tag the source streamer wrote into a track's metadata
  /// (OBS writes `obs-output module …` on the video track). Some sources spell
  /// the key uppercase, and many carry no encoder tag at all, so both case
  /// variants are read and a missing tag is null.
  String? _encoderMetadata(mdk.StreamInfo? stream) {
    if (stream == null) return null;
    final metadata = stream.metadata;
    final encoder = metadata['encoder'] ?? metadata['ENCODER'];
    return encoder == null || encoder.isEmpty ? null : encoder;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _opens++;
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _stopTicker();

    await _nextPlayer?.safeDispose();
    _nextPlayer = null;
    await _currentPlayer?.safeDispose();
    _currentPlayer = null;

    _textureId.dispose();
    _frameSize.dispose();
    await _events.close();
    debugPrint('[FvpEngine] dispose complete');
  }
}

/// An [EngineFactory] creating [FvpEngine]s with [config].
EngineFactory fvpEngineFactory([FvpEngineConfig? config]) =>
    () => FvpEngine.create(config: config);

/// Watches the app's lifecycle and asks [FvpEngine] to reopen its source when
/// it comes back to the foreground.
final class _TextureLifecycleObserver extends WidgetsBindingObserver {
  FvpEngine? _engine;

  /// Watches [engine]'s lifecycle.
  void bind(FvpEngine engine) => _engine = engine;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _engine?._onAppResumed();
  }
}
