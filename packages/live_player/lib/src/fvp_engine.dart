import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
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
  const new({this.platform = FvpPlatform.android, this.hardwareDecoding = true, this.volumeGainDb = 0});

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

/// The fvp (libmdk) [PlayerEngine]: the second engine of the player page
/// (`Settings.playbackEngine`, G01), drawn through a Flutter texture
/// ([TextureVideoHost]) instead of media_kit's `Video`.
///
/// - Each open sets the request headers (`avio.headers`), the proxy
///   (`avio.http_proxy`, `avformat.http_proxy`) and the decoder order, then
///   loads the media with its external audio (a split stream's rendition,
///   `setMedia(type: audio)`) and prepares it at the start position. A
///   failed prepare throws, which the session treats as the source failing.
/// - **Each open recreates the native libmdk player**, releasing the old one
///   first: switching lines then cannot inherit a stale decoder, texture or
///   network state from the previous source (which showed as a black picture
///   on the new line).
/// - libmdk reports playback state, media status (buffering, end, invalid)
///   and events; the position is read four times a second, as the session
///   judges a live source by whether it moves.
/// - Audio-only mode disables the video track in the native player instead
///   of reopening, as mpv turns its video output off.
/// - Windows reports no presented frames here (`reportsFrames` false), so
///   the frame watchdog does not apply to this engine.
final class FvpEngine implements PlayerEngine, PlaybackRate, PlaybackStatsSource, VolumeGainControl, TextureVideoHost {
  new _(this._player, this.config) {
    _bind();
  }

  /// Creates the native player and its event bindings. Needs a Flutter
  /// binding and libmdk for this platform (the fvp plugin's build hook
  /// provides it).
  static Future<FvpEngine> create({FvpEngineConfig? config}) async {
    final resolved = config ?? const FvpEngineConfig();
    try {
      return FvpEngine._(mdk.Player(), resolved).._configure();
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

  /// The current libmdk player. Replaced on every [open] (`_recreatePlayer`),
  /// so no decoder, texture or network state survives a line switch.
  mdk.Player _player;

  /// The libmdk player currently in use (kept for callers that read it).
  mdk.Player get player => _player;

  /// Configuration.
  final FvpEngineConfig config;

  final StreamController<EngineEvent> _events = StreamController.broadcast(sync: true);
  List<StreamSubscription<Object?>> _subscriptions = [];
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<Size?> _frameSize = ValueNotifier<Size?>(null);

  Timer? _ticker;
  ({int width, int height})? _lastSize;
  double? _lastFrameRate;
  var _buffering = false;
  var _hasSource = false;
  var _audioOnly = false;
  var _disposed = false;
  var _opens = 0;
  var _volume = 1.0;
  var _gainDb = 0;

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

  /// The settings that stay on this player between sources.
  void _configure() {
    _gainDb = config.volumeGainDb.clamp(-FvpEngineConfig.maxVolumeGainDb, FvpEngineConfig.maxVolumeGainDb);
    _player
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

  /// Binds the player's streams. Safe to call again after a new player was
  /// created: it first cancels the previous bindings.
  void _bind() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions = [];
    _subscriptions
      ..add(
        _player.onStateChanged.listen((event) {
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
        _player.onMediaStatus.listen((event) {
          if (_disposed) return;
          _onStatus(event.newValue);
        }),
      )
      ..add(
        _player.onEvent.listen((event) {
          if (_disposed) return;
          // The first decoded frame tells the picture's size when the
          // probe did not (libmdk fills `mediaInfo.video` at load).
          if (event.category == 'decoder.video') _emitSize();
        }),
      );
  }

  void _onStatus(mdk.MediaStatus status) {
    if (status.test(mdk.MediaStatus.invalid) && _hasSource) {
      _hasSource = false;
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
    if (buffering != _buffering) {
      _buffering = buffering;
      _add(EngineBuffering(buffering: buffering));
    }
    if (status.test(mdk.MediaStatus.loaded)) _emitSize();
  }

  /// Reports the picture's size once per open when it is known.
  void _emitSize() {
    if (_disposed) return;
    final ({int width, int height})? size;
    try {
      final streams = _player.mediaInfo.video;
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
    if (size == null || size == _lastSize) {
      _emitFrameRate();
      return;
    }
    _lastSize = size;
    _frameSize.value = Size(size.width.toDouble(), size.height.toDouble());
    _add(EngineVideoSize(size.width, size.height));
    _emitFrameRate();
  }

  /// Reports the source's frame rate once per open when it is known. libmdk
  /// fills `mediaInfo.video.codec.frameRate` as the video track is probed
  /// (the `loaded` status), so a line whose rate is missing from the first
  /// probe still reports it once the probe completes.
  void _emitFrameRate() {
    if (_disposed) return;
    final fps = _videoFrameRate();
    if (fps != null && fps != _lastFrameRate) _add(EngineFrameRate(fps));
  }

  int _durationMs() {
    try {
      return _player.mediaInfo.duration;
    } on Object {
      return 0;
    }
  }

  double? _videoFrameRate() {
    try {
      final streams = _player.mediaInfo.video;
      final fps = streams == null || streams.isEmpty ? 0.0 : streams.first.codec.frameRate;
      return fps > 0 && fps.isFinite ? fps : null;
    } on Object {
      return null;
    }
  }

  /// Releases the current native player and creates a fresh one, then
  /// re-applies the persistent configuration and re-binds the streams.
  ///
  /// The old player is disposed before the new one is made, so a line switch
  /// cannot inherit a stale decoder, texture, avio connection or a pending
  /// reconnect from the previous source. The replacement costs a native
  /// init (a few dozen to a few hundred milliseconds) per open; the old code
  /// reused one player and left that stale state behind, which showed as a
  /// black picture after switching lines.
  Future<void> _recreatePlayer() async {
    // Drop the old bindings first so the teardown cannot emit into the
    // engine while the player is being released.
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions = [];
    _stopTicker();
    _hasSource = false;
    _buffering = false;
    _lastSize = null;
    _lastFrameRate = null;
    _frameSize.value = null;
    _textureId.value = null;

    final old = _player;
    try {
      await old.updateTexture(width: -1);
    } on Object {
      // The native player may already have dropped the texture.
    }
    try {
      await old.disposeAsync();
    } on Object {
      // The native player may already be gone.
    }

    _player = mdk.Player();
    _configure();
    _bind();
  }

  @override
  Future<void> open(EngineMedia media) async {
    final open = ++_opens;
    _hasSource = false;
    _buffering = false;
    _lastSize = null;
    _lastFrameRate = null;
    _frameSize.value = null;
    _textureId.value = null;

    // Every open gets a new native player: a line switch then cannot reuse a
    // decoder, texture or avio state from the previous source.
    await _recreatePlayer();
    if (_disposed || open != _opens) return;

    try {
      _applyProperties(media);
      _player.media = media.uri.toString();
      final audio = media.audio;
      if (audio != null) {
        // A split stream's sound (A17.6): an external audio source of this
        // player, fetched with the same headers and proxy as the video.
        _player.setMedia(audio.uri.toString(), mdk.MediaType.audio);
      }
      final start = media.start?.inMilliseconds ?? 0;
      final result = await _player.prepare(position: math.max(0, start));
      if (_disposed || open != _opens) return;
      if (result < 0) {
        throw PlayerException(
          message: 'libmdk could not prepare the source ($result)',
          type: PlayerErrorType.source,
          code: 'fvp_open_${result.clamp(-99, -1)}',
        );
      }
      await _setVideoTrack(enabled: !media.audioOnly);
      if (_disposed || open != _opens) return;
      _emitSize();
      if (!media.audioOnly) await _createTexture(open);
      if (_disposed || open != _opens) return;
      _hasSource = true;
      _applyVolume();
      _player.state = mdk.PlaybackState.playing;
      final duration = _durationMs();
      if (media.onDemand && duration > 0) _add(EngineDuration(Duration(milliseconds: duration)));
      _emitFrameRate();
      _startTicker();
    } on PlayerException {
      rethrow;
    } on Object catch (error, stack) {
      _hasSource = false;
      _stopTicker();
      throw PlayerException(
        message: 'libmdk could not open the source: $error',
        type: PlayerErrorType.source,
        code: 'fvp_open_failed',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// The per-open properties: headers, proxy and the decoder order.
  void _applyProperties(EngineMedia media) {
    _player
      ..setProperty('avio.headers', media.headers.isEmpty ? '' : fvpHeaderLines(media.headers))
      ..setProperty('avio.http_proxy', media.proxyUrl)
      ..setProperty('avformat.http_proxy', media.proxyUrl)
      ..videoDecoders = fvpVideoDecoders(
        config.platform,
        hardwareDecoding: media.decoder == DecoderMode.hardware && config.hardwareDecoding,
      );
  }

  /// Creates the texture for this open's picture (libmdk sizes it to the
  /// video's own frame, so the view keeps the aspect ratio). A failure throws
  /// instead of leaving a silent black picture.
  Future<void> _createTexture(int open) async {
    final id = await _player.updateTexture();
    if (id < 0) {
      throw PlayerException(
        message: 'libmdk could not create the video texture (updateTexture returned $id)',
        type: PlayerErrorType.native,
        code: 'fvp_texture_failed',
      );
    }
    if (_disposed || open != _opens) {
      // A newer open took over while the texture was being made: drop it
      // without showing the old picture.
      await _releaseTexture();
      return;
    }
    _textureId.value = id;
  }

  Future<void> _releaseTexture() async {
    _textureId.value = null;
    if ((_player.textureId.value ?? -1) < 0) return;
    try {
      await _player.updateTexture(width: -1);
    } on Object {
      // Native teardown may refuse; the player keeps the texture until it
      // is disposed.
    }
  }

  /// Turns the native player's video track off or on without reopening, as
  /// mpv turns its video output off (`audio-only` mode).
  Future<void> _setVideoTrack({required bool enabled}) async {
    if (enabled == !_audioOnly) return;
    // Turning video off drops the picture, and back on re-reports its size
    // even when it is the same as before.
    if (!enabled) {
      await _releaseTexture();
      _lastSize = null;
      _lastFrameRate = null;
    }
    _player.setActiveTracks(mdk.MediaType.video, enabled ? const [0] : const []);
    _audioOnly = !enabled;
  }

  /// Reports the position of the source four times a second (mpv's
  /// `time-pos` stream, which the session uses to tell moving playback from
  /// a stall).
  void _startTicker() {
    _stopTicker();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed || !_hasSource) return;
      try {
        _add(EnginePosition(Duration(milliseconds: _player.position)));
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
    if (_disposed) return;
    _player.state = mdk.PlaybackState.playing;
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _player.state = mdk.PlaybackState.paused;
  }

  @override
  Future<void> stop() async {
    _opens++;
    _hasSource = false;
    _buffering = false;
    _lastSize = null;
    _lastFrameRate = null;
    _stopTicker();
    if (_disposed) return;
    _player.state = mdk.PlaybackState.stopped;
    await _releaseTexture();
    _frameSize.value = null;
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed || !_hasSource) return;
    await _player.seek(position: math.max(0, position.inMilliseconds));
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1).toDouble();
    _applyVolume();
  }

  @override
  Future<void> setVolumeGainDb(int? decibels) async {
    final gain = decibels?.clamp(-FvpEngineConfig.maxVolumeGainDb, FvpEngineConfig.maxVolumeGainDb);
    _gainDb = gain ?? config.volumeGainDb;
    _applyVolume();
  }

  /// libmdk multiplies the source volume; the gain is folded into it (mpv
  /// keeps them apart).
  void _applyVolume() {
    if (_disposed) return;
    final gain = math.pow(10, _gainDb / 20).toDouble();
    _player.volume = (_volume * gain).clamp(0, 8).toDouble();
  }

  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    _player.playbackRate = rate.clamp(0.25, 4).toDouble();
  }

  @override
  Future<void> setAudioOnly({required bool enabled}) async {
    if (_disposed || !_hasSource) return;
    await _setVideoTrack(enabled: !enabled);
    if (enabled) return;
    _emitSize();
    await _createTexture(_opens);
  }

  @override
  Future<PlaybackStats> readStats() async {
    if (_disposed) return const PlaybackStats();
    try {
      final info = _player.mediaInfo;
      final video = info.video?.isEmpty ?? true ? null : info.video!.first;
      final audio = info.audio?.isEmpty ?? true ? null : info.audio!.first;

      // Seconds of media held in libmdk's cache; the panel's "缓冲" row.
      int? bufferedMs;
      try {
        bufferedMs = _player.buffered();
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
        encoder: video?.metadata['encoder'] ?? audio?.metadata['encoder'],
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

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _opens++;
    _stopTicker();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions = [];
    try {
      await _player.disposeAsync();
    } on Object {
      // The native player may already be gone.
    }
    _textureId.dispose();
    _frameSize.dispose();
    await _events.close();
  }
}

/// An [EngineFactory] creating [FvpEngine]s with [config].
EngineFactory fvpEngineFactory([FvpEngineConfig? config]) =>
    () => FvpEngine.create(config: config);
