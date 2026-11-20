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

/// The video decoders libmdk tries, in order: the platform's hardware one
/// first when decoding by hardware, then FFmpeg's software decoders (so a
/// profile the hardware decoder rejects still plays; 3.x's own fvp adapter
/// relied on the same fallback).
List<String> fvpVideoDecoders(FvpPlatform platform, {required bool hardwareDecoding}) {
  if (!hardwareDecoding) return const ['FFmpeg'];
  final hardware = switch (platform) {
    FvpPlatform.android => 'MediaCodec',
    FvpPlatform.ios || FvpPlatform.macos => 'VideoToolbox',
    FvpPlatform.windows => 'D3D11',
    FvpPlatform.linux => 'VAAPI',
  };
  return [hardware, 'FFmpeg'];
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
/// - libmdk reports playback state, media status (buffering, end, invalid)
///   and events; the position is read four times a second, as the session
///   judges a live source by whether it moves.
/// - Audio-only mode disables the video track in the native player instead
///   of reopening, as mpv turns its video output off.
/// - Windows reports no presented frames here (`reportsFrames` false), so
///   the frame watchdog does not apply to this engine.
final class FvpEngine implements PlayerEngine, PlaybackRate, PlaybackStatsSource, VolumeGainControl, TextureVideoHost {
  new _(this.player, this.config) {
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

  /// The libmdk player.
  final mdk.Player player;

  /// Configuration.
  final FvpEngineConfig config;

  final StreamController<EngineEvent> _events = StreamController.broadcast(sync: true);
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<Size?> _frameSize = ValueNotifier<Size?>(null);

  Timer? _ticker;
  ({int width, int height})? _lastSize;
  var _buffering = false;
  var _hasSource = false;
  var _audioOnly = false;
  var _externalAudio = false;
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
    // A live line that drops is reconnected by libmdk itself; the session
    // still sees the stall through the position and its buffering flags.
    player
      ..setProperty('avio.reconnect', '1')
      ..setProperty('avio.reconnect_delay_max', '7');
  }

  void _bind() {
    _subscriptions
      ..add(
        player.onStateChanged.listen((event) {
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
        player.onMediaStatus.listen((event) {
          if (_disposed) return;
          _onStatus(event.newValue);
        }),
      )
      ..add(
        player.onEvent.listen((event) {
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
      final streams = player.mediaInfo.video;
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
    if (size == null || size == _lastSize) return;
    _lastSize = size;
    _frameSize.value = Size(size.width.toDouble(), size.height.toDouble());
    _add(EngineVideoSize(size.width, size.height));
  }

  int _durationMs() {
    try {
      return player.mediaInfo.duration;
    } on Object {
      return 0;
    }
  }

  double? _videoFrameRate() {
    try {
      final streams = player.mediaInfo.video;
      final fps = streams == null || streams.isEmpty ? 0.0 : streams.first.codec.frameRate;
      return fps > 0 && fps.isFinite ? fps : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> open(EngineMedia media) async {
    final open = ++_opens;
    _hasSource = false;
    _buffering = false;
    _lastSize = null;
    _frameSize.value = null;
    _textureId.value = null;
    try {
      _applyProperties(media);
      player.media = media.uri.toString();
      final audio = media.audio;
      if (audio != null || _externalAudio) {
        // A split stream's sound (A17.6): an external audio source of this
        // player, fetched with the same headers and proxy as the video.
        player.setMedia(audio?.uri.toString() ?? '', mdk.MediaType.audio);
        _externalAudio = audio != null;
      }
      final start = media.start?.inMilliseconds ?? 0;
      final result = await player.prepare(position: math.max(0, start));
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
      player.state = mdk.PlaybackState.playing;
      final duration = _durationMs();
      if (media.onDemand && duration > 0) _add(EngineDuration(Duration(milliseconds: duration)));
      final fps = _videoFrameRate();
      if (fps != null) _add(EngineFrameRate(fps));
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
    player
      ..setProperty('avio.headers', media.headers.isEmpty ? '' : fvpHeaderLines(media.headers))
      ..setProperty('avio.http_proxy', media.proxyUrl)
      ..setProperty('avformat.http_proxy', media.proxyUrl)
      ..videoDecoders = fvpVideoDecoders(
        config.platform,
        hardwareDecoding: media.decoder == DecoderMode.hardware && config.hardwareDecoding,
      );
  }

  /// Creates the texture for this open's picture (libmdk sizes it to the
  /// video's own frame, so the view keeps the aspect ratio).
  Future<void> _createTexture(int open) async {
    final id = await player.updateTexture();
    if (id < 0) return;
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
    if ((player.textureId.value ?? -1) < 0) return;
    try {
      await player.updateTexture(width: -1);
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
    }
    player.setActiveTracks(mdk.MediaType.video, enabled ? const [0] : const []);
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
        _add(EnginePosition(Duration(milliseconds: player.position)));
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
    player.state = mdk.PlaybackState.playing;
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    player.state = mdk.PlaybackState.paused;
  }

  @override
  Future<void> stop() async {
    _opens++;
    _hasSource = false;
    _buffering = false;
    _lastSize = null;
    _stopTicker();
    if (_disposed) return;
    player.state = mdk.PlaybackState.stopped;
    await _releaseTexture();
    _frameSize.value = null;
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed || !_hasSource) return;
    await player.seek(position: math.max(0, position.inMilliseconds));
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
    player.volume = (_volume * gain).clamp(0, 8).toDouble();
  }

  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    player.playbackRate = rate.clamp(0.25, 4).toDouble();
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
      final info = player.mediaInfo;
      final video = info.video?.isEmpty ?? true ? null : info.video!.first;
      final audio = info.audio?.isEmpty ?? true ? null : info.audio!.first;
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
    try {
      await player.disposeAsync();
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
