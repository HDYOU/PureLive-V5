import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_core/live_core.dart';
import 'package:live_media/live_media.dart';
import 'package:live_player/live_player.dart';

import 'support/fake_engine.dart';

void main() {
  group('G01: the fvp engine', () {
    test('the decoder order: the platform hardware ones first, software behind them', () {
      // 3.x's hardware-decoder order: the platform's hardware decoders first,
      // then FFmpeg's software decoders and the stand-alone dav1d.
      expect(
        fvpVideoDecoders(FvpPlatform.android, hardwareDecoding: true),
        ['AMediaCodec', 'MediaCodec', 'FFmpeg', 'dav1d'],
      );
      expect(fvpVideoDecoders(FvpPlatform.ios, hardwareDecoding: true), ['VT', 'FFmpeg', 'dav1d']);
      expect(fvpVideoDecoders(FvpPlatform.macos, hardwareDecoding: true), ['VT', 'hap', 'FFmpeg', 'dav1d']);
      expect(
        fvpVideoDecoders(FvpPlatform.windows, hardwareDecoding: true),
        ['MFT:d3d=11', 'D3D11', 'DXVA', 'CUDA', 'hap', 'FFmpeg', 'dav1d'],
      );
      expect(
        fvpVideoDecoders(FvpPlatform.linux, hardwareDecoding: true),
        ['VAAPI', 'CUDA', 'VDPAU', 'hap', 'FFmpeg', 'dav1d'],
      );
      // 3.x's "硬件解码" off decodes with FFmpeg alone.
      expect(fvpVideoDecoders(FvpPlatform.android, hardwareDecoding: false), ['FFmpeg']);
    });

    test('the headers as libmdk reads them', () {
      expect(fvpHeaderLines(const {}), '');
      expect(
        fvpHeaderLines(const {'User-Agent': 'PureLive/5.0', 'Referer': 'https://live.bilibili.com'}),
        'User-Agent: PureLive/5.0\r\nReferer: https://live.bilibili.com\r\n',
      );
    });

    test('the picture size: the sample aspect ratio, then a quarter turn', () {
      expect(fvpDisplaySizeOf(width: 1920, height: 1080), (width: 1920, height: 1080));
      // Anamorphic SD: 720x480 stored, 16:9 shown.
      expect(fvpDisplaySizeOf(width: 720, height: 480, par: 1.5), (width: 720, height: 320));
      // A phone holding the camera upright: a 90 turn swaps the sides.
      expect(fvpDisplaySizeOf(width: 1920, height: 1080, rotation: 90), (width: 1080, height: 1920));
      expect(fvpDisplaySizeOf(width: 1920, height: 1080, rotation: 180), (width: 1920, height: 1080));
      // Not probed yet.
      expect(fvpDisplaySizeOf(width: 0, height: 1080), isNull);
      expect(fvpDisplaySizeOf(width: 1920, height: 0), isNull);
    });

    test('the stored engine name, and mpv for anything else', () {
      expect(PlaybackEngineKind.of('fvp'), PlaybackEngineKind.fvp);
      expect(PlaybackEngineKind.of('mpv'), PlaybackEngineKind.mpv);
      expect(PlaybackEngineKind.of('ijk'), PlaybackEngineKind.mpv);
      expect(PlaybackEngineKind.of(null), PlaybackEngineKind.mpv);
      expect(PlaybackEngineKind.fvp.name, 'fvp');
    });

    testWidgets('the view draws the engine texture at the picture size with the fit', (tester) async {
      final engine = TextureFakeEngine();
      final session = PlaybackSession(engine: () async => engine, opener: MediaOpener());
      await session.open(
        PlaybackRequest(
          site: 'douyu',
          plan: PlaybackPlan.of(LivePlayUrlResolution.lines(const [LivePlayLine('https://a.example/1.flv')])),
        ),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: LiveVideoView(session: session, fit: BoxFit.cover, alignment: Alignment.topCenter),
        ),
      );
      // The engine has no picture yet: the fill only, as before the open.
      expect(find.byType(Texture), findsNothing);

      engine.frameSize.value = const Size(1080, 1920);
      engine.textureId.value = 7;
      await tester.pump();

      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 7);
      final box = tester.widget<SizedBox>(
        find.ancestor(of: find.byType(Texture), matching: find.byType(SizedBox)).first,
      );
      expect(box.width, 1080);
      expect(box.height, 1920);
      final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fitted.fit, BoxFit.cover);
      expect(fitted.alignment, Alignment.topCenter);

      // A stopped or disposed engine's picture goes back to the fill.
      engine.textureId.value = null;
      await tester.pump();
      expect(find.byType(Texture), findsNothing);

      await session.stop();
      await tester.pump();
      await session.dispose();
    });
  });
}
