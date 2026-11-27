import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_net/live_net.dart';
import 'package:live_store/live_store.dart';
import 'package:live_ui/live_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/app/app.dart';
import 'package:pure_live/app/image_cache.dart';
import 'package:pure_live/app/image_downloads.dart';
import 'package:pure_live/app/platforms.dart';
import 'package:pure_live/app/services.dart';

import 'support.dart';

/// Real sockets inside the test binding, which otherwise answers every
/// `HttpClient` request with 400.
final class _RealHttp extends HttpOverrides;

/// A loopback server that answers every request with three bytes and keeps the
/// request lines it saw: an absolute URI when it was used as a proxy.
final class _Server {
  new _(this._server) {
    _server.listen((request) async {
      seen.add('${request.method} ${request.uri}');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'png')
        ..add(const [1, 2, 3]);
      await request.response.close();
    });
  }

  static Future<_Server> start() async => _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<String> seen = [];

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('images follow the app proxy, read at each new connection (Q02.1)', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final store = await LiveStore.memory(cipher: FakeCipher());
      addTearDown(store.close);
      final proxy = await _Server.start();
      final direct = await _Server.start();
      addTearDown(proxy.close);
      addTearDown(direct.close);
      final service = imageFileService(SettingsProxyPolicy(store.settings));

      await store.settings.setAll({
        Settings.enableAppProxy: true,
        Settings.appProxyHost: '127.0.0.1',
        Settings.appProxyPort: proxy.port,
      });
      final proxied = await service.get('http://covers.example/a.jpg');
      expect(proxied.statusCode, 200);
      expect(await proxied.content.expand((bytes) => bytes).toList(), [1, 2, 3]);
      expect(proxy.seen, ['GET http://covers.example/a.jpg'], reason: 'asked of the proxy, by absolute URI');

      await store.settings.set(Settings.enableAppProxy, false);
      await (await service.get('http://127.0.0.1:${direct.port}/b.jpg')).content.drain<void>();
      expect(direct.seen, ['GET /b.jpg'], reason: 'off: straight to the image host');

      // A half-typed address stays direct (proxyRouteFrom).
      await store.settings.setAll({Settings.enableAppProxy: true, Settings.appProxyHost: ''});
      await (await service.get('http://localhost:${direct.port}/c.jpg')).content.drain<void>();
      expect(direct.seen.last, 'GET /c.jpg');
      expect(proxy.seen, hasLength(1));
    }, _RealHttp());
  });

  test('R01.3: images download on a worker isolate, through the proxy directive of each request', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    final proxy = await _Server.start();
    final direct = await _Server.start();
    addTearDown(proxy.close);
    addTearDown(direct.close);
    var directive = 'DIRECT';
    final service = IsolateImageFileService(directiveFor: (_) => directive);

    final plain = await service.get('http://127.0.0.1:${direct.port}/a.png');
    expect(plain.statusCode, 200);
    expect(plain.fileExtension, '.png');
    expect(plain.contentLength, 3);
    expect(await plain.content.expand((bytes) => bytes).toList(), [1, 2, 3]);
    expect(direct.seen, ['GET /a.png']);

    directive = 'PROXY 127.0.0.1:${proxy.port}';
    final proxied = await service.get('http://covers.example/b.jpg');
    expect(await proxied.content.expand((bytes) => bytes).toList(), [1, 2, 3]);
    expect(proxy.seen, ['GET http://covers.example/b.jpg']);

    directive = 'DIRECT';
    await expectLater(service.get('http://127.0.0.1:1/c.jpg'), throwsA(isA<HttpException>()));
  });

  test('each pool has its own cache: covers expire in 30 minutes, avatars and emoticons in 2 days', () {
    final temporary = Directory('/tmp/x');
    Config memory(LiveImagePool pool) => imagePoolCacheConfig(
      pool,
      const _NoProxy(),
      repo: NonStoringObjectProvider(),
      fileSystem: MemoryCacheSystem(),
    );
    for (final pool in LiveImagePool.values) {
      final config = memory(pool);
      expect(config.cacheKey, imagePoolCacheKey(pool));
      expect(config.fileService, isA<IsolateImageFileService>(), reason: 'downloads off the UI isolate (R01.3)');
      // flutter_cache_manager keeps the files in <temp>/<key> (IOFileSystem).
      expect(imagePoolCacheFolder(pool, temporary).path, p.join('/tmp/x', imagePoolCacheKey(pool)));
    }
    expect(appImageCacheKey, 'pureLiveImages', reason: 'the cover pool keeps the address 3.x used');
    expect(memory(LiveImagePool.cover).stalePeriod, const Duration(minutes: 30));
    expect(memory(LiveImagePool.avatar).stalePeriod, const Duration(days: 2));
    expect(memory(LiveImagePool.emote).stalePeriod, const Duration(days: 2));
    expect(memory(LiveImagePool.cover).maxNrOfCacheObjects, 320);
    expect(memory(LiveImagePool.avatar).maxNrOfCacheObjects, 200);
    expect(memory(LiveImagePool.emote).maxNrOfCacheObjects, 800);
    expect(imagePoolSlides(LiveImagePool.cover), isFalse, reason: 'covers must change');
    expect(imagePoolSlides(LiveImagePool.avatar), isTrue);
    expect(imagePoolSlides(LiveImagePool.emote), isTrue);
    expect(imagePoolCacheKey(LiveImagePool.cover), isNot('libCachedImageData'), reason: "not flutter_cache_manager's default");
  });

  test('a hit on a sliding pool pushes the expiry back, so a picture in use is not downloaded again', () async {
    final directory = await Directory.systemTemp.createTemp('image-pool');
    addTearDown(() => directory.delete(recursive: true));
    final repo = JsonCacheInfoRepository.withFile(File(p.join(directory.path, 'emote.json')));
    var downloads = 0;
    var now = DateTime(2026);
    const url = 'http://emotes.example/a.png';
    const window = Duration(days: 2);
    final manager = SlidingImageCacheManager(
      Config(
        imagePoolCacheKey(LiveImagePool.emote),
        stalePeriod: window,
        repo: repo,
        fileSystem: MemoryCacheSystem(),
        fileService: _FixedFileService(() => downloads++, () => now, validFor: window),
      ),
      window: window,
      clock: () => now,
    );

    // Nothing cached yet: one download.
    await manager.getFileStream(url).last;
    expect(downloads, 1);
    expect((await repo.get(url))!.validTill, now.add(window));

    // A day later the picture is served from disk and its expiry moves to
    // now + window, so it is not downloaded again while it is in use.
    now = DateTime(2026, 1, 2);
    final served = await manager.getFileStream(url).toList();
    expect(downloads, 1, reason: 'in use: served from disk');
    expect(served, hasLength(1));
    expect((await repo.get(url))!.validTill, DateTime(2026, 1, 4));

    // Two days without a hit: expired again, so it is downloaded afresh.
    now = DateTime(2026, 1, 10);
    await manager.getFileStream(url).toList();
    expect(downloads, 2, reason: 'unused for longer than the window');
  });

  test("one manager per pool; flutter_cache_manager's old default cache is emptied once", () async {
    final store = await LiveStore.memory(cipher: FakeCipher());
    addTearDown(store.close);
    final previous = AppImageCache.managerFor(LiveImagePool.cover);
    addTearDown(() => AppImageCache.manager = previous);
    var legacy = 0;
    Config memory(LiveImagePool pool) =>
        imagePoolCacheConfig(pool, const _NoProxy(), repo: NonStoringObjectProvider(), fileSystem: MemoryCacheSystem());

    AppImageCache.manager = null;
    final cover = AppImageCache.install(LiveImagePool.cover, () => memory(LiveImagePool.cover));
    expect(AppImageCache.managerFor(LiveImagePool.cover), same(cover));
    expect(AppImageCache.install(LiveImagePool.cover, () => memory(LiveImagePool.cover)), same(cover), reason: 'one manager');

    final emote = AppImageCache.install(LiveImagePool.emote, () => memory(LiveImagePool.emote));
    expect(emote, isA<SlidingImageCacheManager>(), reason: 'hits push its expiry back');
    expect(AppImageCache.managerFor(LiveImagePool.emote), same(emote));
    expect(AppImageCache.managerFor(LiveImagePool.avatar), isNull, reason: 'installed separately');

    await AppImageCache.clearLegacyOnce(store.meta, () async => legacy++);
    expect(legacy, 1);
    await AppImageCache.clearLegacyOnce(store.meta, () async => legacy++);
    expect(legacy, 1, reason: 'remembered in the meta table');

    final failing = await LiveStore.memory(cipher: FakeCipher());
    addTearDown(failing.close);
    await AppImageCache.clearLegacyOnce(failing.meta, () async => throw StateError('busy'));
    expect(await failing.meta.get(AppImageCache.legacyClearedKey), isNull, reason: 'tried again next start');
  });

  testWidgets('the app gives live_ui one image cache per pool', (tester) async {
    AppImageCache.clear();
    addTearDown(AppImageCache.clear);
    final managers = <LiveImagePool, BaseCacheManager>{
      for (final pool in LiveImagePool.values)
        pool: AppImageCache.install(
          pool,
          () => imagePoolCacheConfig(
            pool,
            const _NoProxy(),
            repo: NonStoringObjectProvider(),
            fileSystem: MemoryCacheSystem(),
          ),
        ),
    };
    // `install` keeps what is there; the widget reads the pools it is given.
    final services = (await tester.runAsync(() async {
      final services = await testServices();
      await services.store.settings.set(Settings.showSplashPage, false);
      return services;
    }))!;
    final strings = (await tester.runAsync(loadStrings))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appServicesProvider.overrideWithValue(services)],
        child: PureLiveApp(strings: strings, bundle: FileAssetBundle()),
      ),
    );
    await tester.pumpAndSettle();
    final config = LiveUiScope.of(tester.element(find.byType(Scaffold).first));
    for (final pool in LiveImagePool.values) {
      expect(config.imageCacheManagerFor(pool), same(managers[pool]), reason: '$pool');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(services.close);
  });

  test('clearing covers renews the cover keys only', () {
    const config = LiveUiConfig(imageCacheEpoch: 3, imageCacheEpochs: {LiveImagePool.avatar: 2});
    expect(config.imageCacheKey('a.png'), 'a.png#3', reason: 'covers (the default pool) load again under a new key');
    expect(config.imageCacheKey('a.png', LiveImagePool.avatar), 'a.png#2', reason: 'its own epoch');
    expect(config.imageCacheKey('a.png', LiveImagePool.emote), 'a.png', reason: 'clearing covers keeps emoticons');
  });
}

/// Answers every download with three bytes, counting them; [validFor] is how
/// long the answer is valid.
final class _FixedFileService extends FileService {
  new(this._onGet, this._clock, {required this.validFor});

  final void Function() _onGet;
  final DateTime Function() _clock;
  final Duration validFor;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    _onGet();
    return _FixedResponse(_clock().add(validFor));
  }
}

/// A fixed [FileServiceResponse] valid until [validTill].
final class _FixedResponse implements FileServiceResponse {
  new(this.validTill);

  @override
  final DateTime validTill;

  @override
  int get statusCode => 200;

  @override
  Stream<List<int>> get content => Stream.value(const [1, 2, 3]);

  @override
  int get contentLength => 3;

  @override
  String get fileExtension => '.png';

  @override
  String? get eTag => null;
}

final class _NoProxy implements ProxyPolicy {
  const new();

  @override
  ProxyRoute routeFor(String site, Uri url) => const DirectRoute();
}
