import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:live_net/live_net.dart';
import 'package:live_store/live_store.dart';
import 'package:live_ui/live_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pure_live/app/image_downloads.dart';

/// The platform name image requests are routed under
/// ([ProxyPolicy.routeFor]); the app proxy does not tell platforms apart.
const String imageProxySite = 'image';

/// The cover pool's cache key (3.x `CustomImageCacheManager.key`,
/// `pureLiveImagesV2`): its database name and its folder under the temporary
/// directory. Not flutter_cache_manager's default (`libCachedImageData`),
/// whose client ignores the app proxy.
const String appImageCacheKey = 'pureLiveImages';

/// The cache key of [pool]: a key of its own means a database, a folder
/// (`<temporary>/<key>`, flutter_cache_manager's `IOFileSystem` layout), a
/// capacity and a set of rules of its own. The cover pool keeps the address
/// 3.x used, so the files earlier versions left there stay usable.
String imagePoolCacheKey(LiveImagePool pool) => switch (pool) {
  LiveImagePool.cover => appImageCacheKey,
  LiveImagePool.avatar => 'pureLiveAvatars',
  LiveImagePool.emote => 'pureLiveEmotes',
};

/// How long a file of [pool] stays valid. Covers change (a room's artwork,
/// a new stream's frame), so they are asked for again after 30 minutes;
/// avatars and emoticons hardly change, so they expire 2 days after their
/// **last use** (see [SlidingImageCacheManager]).
Duration imagePoolStalePeriod(LiveImagePool pool) =>
    pool == LiveImagePool.cover ? const Duration(minutes: 30) : const Duration(days: 2);

/// Whether hits on [pool] push the expiry back; covers are left to expire.
bool imagePoolSlides(LiveImagePool pool) => pool != LiveImagePool.cover;

/// How many files [pool] keeps (flutter_cache_manager has no byte cap, so
/// this is the only bound: covers ~100 KiB each, avatars ~15 KiB, emoticons
/// ~30 KiB).
int imagePoolCapacity(LiveImagePool pool) => switch (pool) {
  LiveImagePool.cover => 320,
  LiveImagePool.avatar => 200,
  LiveImagePool.emote => 800,
};

/// The folder of [pool]'s cache under [temporary].
Directory imagePoolCacheFolder(LiveImagePool pool, Directory temporary) =>
    Directory(p.join(temporary.path, imagePoolCacheKey(pool)));

/// flutter_cache_manager's download service (3.x
/// `CustomImageCacheManager._createManager`): on an isolate of its own
/// (R01.3), through the app proxy of [proxy], read for each image so a
/// changed setting applies to the next one; idle connections close after
/// 30 s. The directive is [ProxyRoute.directive] as is: Android resolves
/// anything else in it as a host name.
FileService imageFileService(ProxyPolicy proxy) =>
    IsolateImageFileService(directiveFor: (url) => proxy.routeFor(imageProxySite, url).directive);

/// The rules of [pool]'s cache: its key, its expiry ([imagePoolStalePeriod]),
/// its capacity ([imagePoolCapacity]), downloads through [proxy]. [repo] and
/// [fileSystem] replace the on-disk ones in tests.
Config imagePoolCacheConfig(
  LiveImagePool pool,
  ProxyPolicy proxy, {
  CacheInfoRepository? repo,
  FileSystem? fileSystem,
}) {
  final fileService = imageFileService(proxy);
  if (repo == null || fileSystem == null) {
    return Config(
      imagePoolCacheKey(pool),
      stalePeriod: imagePoolStalePeriod(pool),
      maxNrOfCacheObjects: imagePoolCapacity(pool),
      fileService: fileService,
    );
  }
  return Config(
    imagePoolCacheKey(pool),
    stalePeriod: imagePoolStalePeriod(pool),
    maxNrOfCacheObjects: imagePoolCapacity(pool),
    repo: repo,
    fileSystem: fileSystem,
    fileService: fileService,
  );
}

/// The manager of [pool]: a [SlidingImageCacheManager] where hits push the
/// expiry back (avatars, emoticons), a plain [CacheManager] for covers.
/// [clock] is the test's time source.
BaseCacheManager imagePoolCacheManager(LiveImagePool pool, ProxyPolicy proxy, {DateTime Function()? clock}) {
  final config = imagePoolCacheConfig(pool, proxy);
  if (!imagePoolSlides(pool)) return CacheManager(config);
  return SlidingImageCacheManager(config, window: config.stalePeriod, clock: clock);
}

/// A manager whose files stay valid while they are used: each hit inside
/// [window] moves the file's expiry to `now + window`, so a picture seen
/// regularly is never downloaded again; one left unused for [window] is
/// fetched again when it next appears. (flutter_cache_manager itself only
/// expires at insert time: `validTill` is `insert + stalePeriod` and a hit
/// changes nothing, so a cover in use was re-downloaded every 30 minutes.)
///
/// The renewal also touches the cache object, which is what
/// `maxNrOfCacheObjects` evicts by — without it the room would be freed in
/// insertion order instead of least-recently-used order.
final class SlidingImageCacheManager extends CacheManager {
  /// Wraps [config]; [window] is how long a file stays valid after its last
  /// use, [clock] the time source (tests).
  new(super.config, {required this.window, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// How long a file stays valid after its last use.
  final Duration window;

  final DateTime Function() _clock;

  /// The last renewal written per key: a screen full of hits then costs at
  /// most one database write per picture per hour.
  final Map<String, DateTime> _renewedAt = {};

  /// The shortest interval between two renewals of the same key.
  static const Duration _writeInterval = Duration(hours: 1);

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    key ??= url;
    final now = _clock();
    final cached = await getFileFromCache(key);
    if (cached != null && cached.validTill.isAfter(now)) {
      yield cached;
      await _renew(key, now);
      return;
    }
    yield* super.getFileStream(url, key: key, headers: headers, withProgress: withProgress);
  }

  /// Moves [key]'s expiry to `now + window`, at most every [_writeInterval].
  Future<void> _renew(String key, DateTime now) async {
    final last = _renewedAt[key];
    if (last != null && now.difference(last) < _writeInterval) return;
    _renewedAt[key] = now;
    try {
      final object = await config.repo.get(key);
      if (object == null) return;
      await config.repo.update(object.copyWith(validTill: now.add(window)));
    } on Object {
      // A renewal that did not land only costs a download later.
    }
  }
}

/// The app's image caches (Q02.1): one manager per [LiveImagePool], which
/// live_ui's covers, avatars and emoticons (`LiveUiConfig.imageCacheManagerFor`)
/// and the data page's clearing all use.
abstract final class AppImageCache {
  static final Map<LiveImagePool, BaseCacheManager> _managers = {};

  /// The installed managers, by pool; empty outside the app (tests and
  /// widgets fall back to their defaults).
  static Map<LiveImagePool, BaseCacheManager> get managers => Map.unmodifiable(_managers);

  /// The manager of [pool]; null until [install].
  static BaseCacheManager? managerFor(LiveImagePool pool) => _managers[pool];

  /// The cover pool's manager — the single cache 3.x had.
  static BaseCacheManager? get manager => _managers[LiveImagePool.cover];

  /// Replaces the cover pool's manager (tests; the app uses [install]).
  static set manager(BaseCacheManager? value) {
    if (value == null) {
      _managers.remove(LiveImagePool.cover);
    } else {
      _managers[LiveImagePool.cover] = value;
    }
  }

  /// The manager of [pool], created from [config] the first time; later calls
  /// return the one installed.
  static BaseCacheManager install(LiveImagePool pool, Config Function() config) =>
      _managers.putIfAbsent(pool, () {
        final built = config();
        if (!imagePoolSlides(pool)) return CacheManager(built);
        return SlidingImageCacheManager(built, window: built.stalePeriod);
      });

  /// Empties every pool's disk cache (the settings page's "clear").
  static Future<void> emptyCache() async {
    for (final manager in _managers.values) {
      await manager.emptyCache();
    }
  }

  /// Drops every installed manager (tests; the app installs once at start).
  static void clear() => _managers.clear();

  /// The meta key set once flutter_cache_manager's default cache, which
  /// earlier versions filled, was emptied.
  static const String legacyClearedKey = 'images.legacyCacheCleared';

  /// Empties the old default cache with [clearLegacy] unless [meta] says it
  /// was done; a failure is tried again at the next start.
  static Future<void> clearLegacyOnce(MetaStore meta, Future<void> Function() clearLegacy) async {
    if (await meta.get(legacyClearedKey) != null) return;
    try {
      await clearLegacy();
      await meta.set(legacyClearedKey, '1');
    } on Object {
      // Left for the next start.
    }
  }
}
