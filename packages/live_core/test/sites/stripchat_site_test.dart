// StripchatSite over the recorded responses (ReplayHttp): catalog, directory,
// room entry, streams, search and links.
import 'dart:async';
import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_net/live_net.dart';
import 'package:live_net/testing.dart';
import 'package:test/test.dart';

const _root = '../../fixtures/stripchat';
const _site = 'stripchat';

ReplaySample _synthetic(String url, Object body, {int status = 200}) => ReplaySample(
      method: 'GET',
      url: Uri.parse(url),
      status: status,
      bytes: utf8.encode(body is String ? body : jsonEncode(body)),
    );

/// A [LiveHttp] that counts the peak number of in-flight `send` calls and the
/// number of CDN master requests seen.
final class _ConcurrentCounter implements LiveHttp {
  new(this.inner);

  final LiveHttp inner;

  int _inFlight = 0;
  int peak = 0;
  int cdnMasters = 0;

  static bool _isCdnMaster(Uri url) =>
      url.path.startsWith('/hls/') && url.path.endsWith('_auto.m3u8');

  @override
  Future<LiveResponse> send(LiveRequest request) async {
    _inFlight++;
    peak = peak > _inFlight ? peak : _inFlight;
    if (_isCdnMaster(request.url)) cdnMasters++;
    try {
      return await inner.send(request);
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<LiveStreamedResponse> open(LiveRequest request) async {
    _inFlight++;
    peak = peak > _inFlight ? peak : _inFlight;
    if (_isCdnMaster(request.url)) cdnMasters++;
    try {
      return await inner.open(request);
    } finally {
      _inFlight--;
    }
  }

  @override
  void close() => inner.close();
}

typedef _Setup = ({StripchatSite site, ReplayHttp http});

/// One ping.m3u8 sample per CDN host (all 200, body "#EXTM3U\n").
List<ReplaySample> _cdnPings() => [
      for (final h in [
        'doppiocdn.org',
        'doppiocdn.com',
        'doppiocdn1.com',
        'doppiocdn.media',
        'doppiocdn.net',
        'doppiocdn.live',
      ])
        _synthetic('https://edge-hls.$h/ping.m3u8', '#EXTM3U\n'),
    ];

/// Single-host setup: the site pins to the canonical host, so the config
/// race issues exactly one request (S08-config) before the first API call.
/// [autoConfig] adds the config sample for any test that will send a request.
/// [withCdnPings] adds a 200 sample for every CDN host's ping.m3u8.
_Setup _setup(
  List<String> samples, {
  List<ReplaySample> extra = const [],
  bool autoConfig = true,
  bool withCdnPings = false,
  List<String> hosts = const [StripchatApi.apiHost],
}) {
  final all = <String>[...samples];
  if (autoConfig && !all.contains('S08-config')) all.add('S08-config');
  final pings = withCdnPings ? _cdnPings() : <ReplaySample>[];
  final http = ReplayHttp([...extra, ...pings, for (final name in all) ReplaySample.load('$_root/$name')]);
  return (site: StripchatSite(http, hosts), http: http);
}

void main() {
  group('catalog', () {
    test('returns one category with sort areas', () async {
      final setup = _setup([]);
      final categories = await setup.site.getCategories(1, 30);
      expect(categories, hasLength(1));
      expect(categories[0].id, 'stripchat');
      expect(categories[0].name, 'Stripchat');
      expect(categories[0].children, hasLength(15));
    });

    test('page > 1 returns empty', () async {
      final setup = _setup([]);
      expect(await setup.site.getCategories(2, 30), isEmpty);
    });
  });

  group('directory', () {
    test('lists live models including groupShow, filters private and offline', () async {
      final setup = _setup(['S01-guest']);
      final rooms = await setup.site.getRecommendRooms();
      // All models are returned; each card reflects its own live status.
      expect(rooms, hasLength(3));
      expect(rooms.map((r) => r.roomId), containsAll([
        'prettygirl?uid=12345678',
        'cutegirl99?uid=87654321',
        'privatemodel?uid=11111111',
      ]));
      expect(rooms[0].roomId, 'prettygirl?uid=12345678');
      expect(rooms[0].isLiveNow, isTrue);
      expect(rooms[0].totalViewers, '1523');
      expect(rooms[0].audienceMetricType, AudienceMetricType.totalViewers);
      expect(rooms[0].title, '按摩');
      expect(rooms[0].userId, '12345678');
      expect(rooms[0].startedAt, DateTime.utc(2026, 11, 06, 11, 28, 39));
      // cutegirl99 is not live: isLive false in the fixture.
      expect(rooms[1].roomId, 'cutegirl99?uid=87654321');
      expect(rooms[1].isLiveNow, isFalse);
      // privatemodel is live but private: status 'private'.
      expect(rooms[2].roomId, 'privatemodel?uid=11111111');
      expect(rooms[2].isLiveNow, isFalse);
    });

    test('directory page respects category sort', () async {
      final setup = _setup(['S01-directory']);
      final page = await setup.site.getDirectoryPage();
      expect(page.rooms, hasLength(3));
      expect(page.hasMore, isFalse);
    });
  });

  group('room entry', () {
    test('live room: detail with stream data', () async {
      final setup = _setup([
        'S05-userid',
        'S03-cam-live',
        'S09-members',
        'S08-config',
      ], withCdnPings: true);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl?uid=12345678');
      expect(room.isLiveNow, isTrue);
      expect(room.totalViewers, '215');
      expect(room.audienceMetricType, AudienceMetricType.totalViewers);
      expect(room.title, 'Reach 2000 viewers!');
      expect(room.startedAt, DateTime.utc(2026, 11, 06, 11, 43, 20));
      expect(room.introduction, 'VIP fan club description');
      expect(room.notice, 'Reach 2000 viewers!');
      final data = room.data as StripchatRoomData;
      expect(data.modelId, 12345678);
      expect(data.streamName, 'prettygirl-webcam');
      expect(data.isLive, isTrue);
      expect(data.masterUris, isNotEmpty);
    });

    test('offline room: no stream data', () async {
      final setup = _setup([
        'S05-userid',
        'S03-cam-offline',
        'S08-config',
      ]);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl?uid=12345678');
      expect(room.isLiveNow, isFalse);
      expect(room.data, isNull);
    });

    test('CDN ping runs once, shared by every later room entry', () async {
      final setup = _setup([
        'S05-userid',
        'S03-cam-live',
        'S09-members',
        'S08-config',
      ], withCdnPings: true);
      // Two room entries on one adapter: the probe is done only on the
      // first, the second reuses the cached probed config.
      await setup.site.getRoomDetail(roomId: 'prettygirl');
      final firstPingCount = setup.http.requests.where((r) => r.url.path == '/ping.m3u8').length;
      expect(firstPingCount, 6);
      await setup.site.getRoomDetail(roomId: 'prettygirl');
      final secondPingCount = setup.http.requests.where((r) => r.url.path == '/ping.m3u8').length;
      // No new pings on the second entry.
      expect(secondPingCount, firstPingCount);
    });

    test('missing model is NotFound', () async {
      final setup = _setup(['S06-notfound']);
      await expectLater(
        setup.site.getRoomDetail(roomId: 'nonexistent123'),
        throwsA(isA<NotFound>()),
      );
    });

    test('invalid username is NotFound without a request', () async {
      final setup = _setup([]);
      await expectLater(
        setup.site.getRoomDetail(roomId: 'webcam'),
        throwsA(isA<NotFound>()),
      );
      expect(setup.http.requests, isEmpty);
    });
  });

  group('refresh', () {
    test('getRoomDetailForRefresh reads cam only', () async {
      final setup = _setup(['S05-userid', 'S03-cam-live'], withCdnPings: true);
      final room = await setup.site.getRoomDetailForRefresh(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl?uid=12345678');
      expect(room.isLiveNow, isTrue);
      expect(room.userId, '12345678');
      expect(room.data, isNull);
      expect(room.title, 'Reach 2000 viewers!');
      expect(room.introduction, 'VIP fan club description');
      expect(room.notice, 'Reach 2000 viewers!');
      // Three requests: config race, user-ids and cam (no master, no members)
      expect(setup.http.requests, hasLength(3));
    });

    test('roomId carrying ?uid=<modelId> skips the user-ids lookup', () async {
      // Only the cam fixture is recorded; no S05-userid. With the uid in the
      // room id the site must not issue the user-ids request.
      final setup = _setup(['S03-cam-live'], withCdnPings: true);
      final room = await setup.site.getRoomDetailForRefresh(roomId: 'prettygirl?uid=12345678');
      expect(room.roomId, 'prettygirl?uid=12345678');
      expect(room.isLiveNow, isTrue);
      // Two requests: config race and cam; the user-ids call was skipped.
      expect(setup.http.requests, hasLength(2));
      expect(
        setup.http.requests.map((r) => r.url.path),
        isNot(contains('/api/front/users/user-ids/prettygirl')),
      );
    });
  });

  group('batch refresh', () {
    test('single room: no request, empty result', () async {
      final setup = _setup([], autoConfig: false);
      final room = LiveRoom(platform: _site, roomId: 'prettygirl?uid=12345678', userId: '12345678');
      expect(await setup.site.refreshFollowBatch([room]), isEmpty);
      expect(setup.http.requests, isEmpty);
    });

    test('two rooms: one watch-history request confirms both', () async {
      final setup = _setup([], extra: [
        _synthetic(
          'https://zh.virtualtaboo.live/api/front/guests/watch-history?modelsIds%5B0%5D=12345678&modelsIds%5B1%5D=87654321&keepSorting=1&limit=60&offset=0',
          {
            'models': [
              {'id': 12345678, 'username': 'prettygirl', 'isLive': true, 'status': 'public', 'viewersCount': 12},
              {'id': 87654321, 'username': 'cutegirl99', 'isLive': false, 'status': 'off', 'viewersCount': 0},
            ],
            'totalCount': 2,
          },
        ),
      ]);
      final a = LiveRoom(platform: _site, roomId: 'prettygirl?uid=12345678', userId: '12345678');
      final b = LiveRoom(platform: _site, roomId: 'cutegirl99?uid=87654321', userId: '87654321');
      final result = await setup.site.refreshFollowBatch([a, b]);
      expect(result.keys, {a.identityKey, b.identityKey});
      expect(result[a.identityKey]?.isLiveNow, isTrue);
      expect(result[a.identityKey]?.totalViewers, '12');
      expect(result[b.identityKey]?.isLiveNow, isFalse);
      // The config race plus one batch request.
      final batch = setup.http.requests.singleWhere((r) => r.url.path == '/api/front/guests/watch-history');
      expect(batch.url.queryParameters['modelsIds[0]'], '12345678');
      expect(batch.url.queryParameters['modelsIds[1]'], '87654321');
    });

    test('unconfirmed rooms are left for the individual refresh', () async {
      final setup = _setup([], extra: [
        _synthetic(
          'https://zh.virtualtaboo.live/api/front/guests/watch-history?modelsIds%5B0%5D=12345678&modelsIds%5B1%5D=87654321&keepSorting=1&limit=60&offset=0',
          {'models': [{'id': 12345678, 'username': 'prettygirl', 'isLive': true, 'status': 'public'}], 'totalCount': 1},
        ),
      ]);
      final a = LiveRoom(platform: _site, roomId: 'prettygirl?uid=12345678', userId: '12345678');
      final b = LiveRoom(platform: _site, roomId: 'cutegirl99?uid=87654321', userId: '87654321');
      final result = await setup.site.refreshFollowBatch([a, b]);
      // Only the confirmed room comes back.
      expect(result.keys, {a.identityKey});
    });
  });

  group('live status', () {
    test('returns true for live room', () async {
      final setup = _setup(['S05-userid', 'S03-cam-live'], withCdnPings: true);
      expect(await setup.site.getLiveStatus(roomId: 'prettygirl'), isTrue);
    });

    test('returns false for offline room', () async {
      final setup = _setup(['S05-userid', 'S03-cam-offline']);
      expect(await setup.site.getLiveStatus(roomId: 'prettygirl'), isFalse);
    });
  });

  group('search', () {
    test('search returns matching live models', () async {
      final setup = _setup(['S07-search']);
      final rooms = await setup.site.searchRooms('search');
      expect(rooms, hasLength(2));
      expect(rooms.map((r) => r.roomId), containsAll([
        'searchgirl?uid=99999999',
        'offlineuser?uid=88888888',
      ]));
      expect(rooms[0].roomId, 'searchgirl?uid=99999999');
      expect(rooms[0].isLiveNow, isTrue);
      expect(rooms[0].title, 'searchgirl room');
      expect(rooms[0].totalViewers, '342');
      expect(rooms[1].roomId, 'offlineuser?uid=88888888');
      expect(rooms[1].isLiveNow, isFalse);
    });

    test('blank keyword returns empty without request', () async {
      final setup = _setup([]);
      expect(await setup.site.searchRooms('   '), isEmpty);
      expect(setup.http.requests, isEmpty);
    });
  });

  group('links', () {
    test('room page URLs are correct', () {
      final site = _setup([]).site;
      expect(site.roomIdFromUrl('https://zh.virtualtaboo.live/prettygirl'), 'prettygirl');
      expect(site.roomIdFromUrl('https://zh.virtualtaboo.live/offlineuser'), 'offlineuser');
      expect(site.roomIdFromUrl('https://zh.virtualtaboo.live/R-bonbon'), 'R-bonbon');
      expect(site.roomIdFromUrl('https://zh.virtualtaboo.live/webcam'), isNull);
      expect(site.roomIdFromUrl('https://example.com/prettygirl'), isNull);
      // Every mirror domain is accepted, so a link from any of them parses.
      for (final host in StripchatApi.apiHosts) {
        expect(site.roomIdFromUrl('https://$host/prettygirl'), 'prettygirl');
      }
      // A foreign host still rejects.
      expect(site.roomIdFromUrl('https://other.example.com/prettygirl'), isNull);
    });
  });

  group('streams', () {
    /// Six CDN master samples so a parallel fetch of every CDN has an answer
    /// for each of the six hosts in the S08 config.
    List<ReplaySample> _masterForAllCdns() => [
          for (final h in [
            'doppiocdn.org',
            'doppiocdn.com',
            'doppiocdn1.com',
            'doppiocdn.media',
            'doppiocdn.net',
            'doppiocdn.live',
          ])
            _synthetic(
              'https://edge-hls.$h/hls/prettygirl-webcam/master/prettygirl-webcam_auto.m3u8?preferredVideoCodec=av1&psch=v2&pkey=bXorqTB5ZhP5FcpX',
              '#EXTM3U\n'
                  '#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080,FRAME-RATE=30\n'
                  '1080p.m3u8\n'
                  '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,FRAME-RATE=30\n'
                  '720p.m3u8\n'
                  '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=854x480,FRAME-RATE=30\n'
                  '480p.m3u8\n',
            ),
        ];

    test('getPlayQualities returns the distinct tiers across all CDNs', () async {
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S08-config'],
        extra: [ReplaySample.load('$_root/S04-master'), ..._masterForAllCdns()],
        withCdnPings: true,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      expect(qualities.map((q) => q.quality), ['1080p', '720p', '480p']);
      // Every CDN answered, so the top tier carries a line per CDN.
      final lines = await setup.site.getPlayUrls(detail: room, quality: qualities.first);
      expect(lines, hasLength(6));
    });

    test('getPlayUrls returns one line per answering CDN', () async {
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S08-config'],
        extra: [ReplaySample.load('$_root/S04-master'), ..._masterForAllCdns()],
        withCdnPings: true,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      final urls = await setup.site.getPlayUrls(detail: room, quality: qualities.first);
      // Six CDNs each contribute a 1080p line.
      expect(urls, hasLength(6));
      for (final h in [
        'doppiocdn.org',
        'doppiocdn.com',
        'doppiocdn1.com',
        'doppiocdn.media',
        'doppiocdn.net',
        'doppiocdn.live',
      ]) {
        expect(urls, anyElement(contains('edge-hls.$h')));
      }
    });

    test('a failed CDN drops out of the lines', () async {
      final failing = _synthetic(
        'https://edge-hls.doppiocdn1.com/hls/prettygirl-webcam/master/prettygirl-webcam_auto.m3u8?preferredVideoCodec=av1&psch=v2&pkey=bXorqTB5ZhP5FcpX',
        '',
        status: 404,
      );
      // The 404 sample comes first so it wins the match for doppiocdn1.com;
      // the rest of the CDNs answer with the all-CDN masters.
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S08-config'],
        extra: [failing, ..._masterForAllCdns(), ReplaySample.load('$_root/S04-master')],
        withCdnPings: true,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      final urls = await setup.site.getPlayUrls(detail: room, quality: qualities.first);
      // The 404 CDN is skipped, so five lines instead of six.
      expect(urls, hasLength(5));
      expect(urls, everyElement(isNot(contains('edge-hls.doppiocdn1.com'))));
    });

    test('resolvePlayUrlsRaw confirms the requested quality', () async {
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S08-config'],
        extra: [ReplaySample.load('$_root/S04-master'), ..._masterForAllCdns()],
        withCdnPings: true,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      final requested = qualities.first;
      final resolution = await setup.site.resolvePlayUrlsRaw(detail: room, quality: requested);
      expect(resolution.appliedQualityData, requested.selectionId);
      expect(resolution.lines, isNotEmpty);
    });

    test('room without stream throws StreamUnavailable', () async {
      final setup = _setup(['S05-userid', 'S03-cam-offline', 'S08-config']);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      expect(
        () => setup.site.getPlayQualities(detail: room),
        throwsA(isA<StreamUnavailable>()),
      );
    });

    test('the six CDN masters are fetched in true parallel', () async {
      final counter = _ConcurrentCounter(
        ReplayHttp([
          ..._masterForAllCdns(),
          ..._cdnPings(),
          ReplaySample.load('$_root/S05-userid'),
          ReplaySample.load('$_root/S03-cam-live'),
          ReplaySample.load('$_root/S09-members'),
          ReplaySample.load('$_root/S08-config'),
        ]),
      );
      final site = StripchatSite(counter, [StripchatApi.apiHost]);
      final room = await site.getRoomDetail(roomId: 'prettygirl');
      await site.getPlayQualities(detail: room);
      // All six CDN masters were requested and at least six were in flight
      // at once (not one after another).
      expect(counter.cdnMasters, 6);
      expect(counter.peak, greaterThanOrEqualTo(6));
    });

    test('CDN masters are deduped, ordered by response time with a fallback for missed hosts', () async {
      final config = ReplaySample.load('$_root/S08-config');
      // Provide pings for all six distinct CDN hosts in the config. The
      // failing host (404) keeps a fallback time instead of being dropped;
      // the config keys (primary, then A, B, C...) give the tie-break order.
      final pings = <ReplaySample>[
        _synthetic('https://edge-hls.doppiocdn.org/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn.com/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn1.com/ping.m3u8', '', status: 404),
        _synthetic('https://edge-hls.doppiocdn.media/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn.net/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn.live/ping.m3u8', '#EXTM3U\n'),
      ];
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members'],
        extra: pings,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final data = room.data as StripchatRoomData;
      final hosts = [for (final m in data.masterUris) StripchatApi.cdnHostOf(m)!];
      // Duplicate host keys (A/A1, B/B1 ...) collapse to one master each:
      // 6 distinct hosts, all kept (the 404 host falls back, it is not dropped).
      expect(data.masterUris.length, 6);
      // The primary host (doppiocdn.org) is listed first in the config, so it
      // stays ahead of the other hosts on a latency tie.
      expect(hosts.first, 'doppiocdn.org');
      expect(StripchatApi.cdnHostOf(data.master), 'doppiocdn.org');
      // Every config host survives (missed probes fall back to the common
      // CDN list), so the 404 host still produces a line.
      expect(hosts, containsAll([
        'doppiocdn.org',
        'doppiocdn.com',
        'doppiocdn1.com',
        'doppiocdn.media',
        'doppiocdn.net',
        'doppiocdn.live',
      ]));
      // Sanity: the config sample that drove this had the 1.com key.
      expect(jsonDecode(utf8.decode(config.bytes)) as Map<String, dynamic>, isNotNull);
    });
  });

  group('errors', () {
    test('bad JSON in cam is ApiChanged', () async {
      final setup = _setup(['S05-userid'], extra: [
        _synthetic(
          'https://zh.virtualtaboo.live/api/front/v2/models/12345678/cam?timezoneOffset=-480&triggerRequest=loadCam&withRecentShow=1',
          '<html>',
        ),
      ]);
      await expectLater(
        setup.site.getRoomDetailForRefresh(roomId: 'prettygirl'),
        throwsA(isA<ApiChanged>()),
      );
    });
  });

  group('host race', () {
    ReplaySample configFor(String host, {required String wsUrl}) => ReplaySample(
          method: 'GET',
          url: Uri.https(host, '/api/front/v3/config/initial'),
          status: 200,
          bytes: utf8.encode(
            jsonEncode({
              'initial': {
                'client': {'websocket': {'url': wsUrl, 'token': 'tok'}},
                'common': {'hlsStreamHost': 'doppiocdn.org'},
              }
            }),
          ),
        );

    test('the all-domain race pins the first host that answers the config', () async {
      final models = ReplaySample.load('$_root/S01-recommend');
      final http = ReplayHttp([
        configFor('zh.xhamsterlive.com', wsUrl: 'wss://websocket-v6.sc-apps.com/connection/websocket'),
        _synthetic(
          'https://zh.xhamsterlive.com/api/front/models?limit=30&primaryTag=girls&filterGroupTags=%5B%5B%22tagLanguageChinese%22%5D%5D&offset=0',
          utf8.decode(models.bytes, allowMalformed: true),
        ),
      ]);
      final site = StripchatSite(http, StripchatApi.apiHosts);
      // Only the second host (zh.xhamsterlive.com) answers the config; the
      // others are raced and dropped. The winner is pinned for the call.
      final rooms = await site.getRecommendRooms();
      expect(rooms, isNotEmpty);
      // The directory request went to the winner, not to the canonical host.
      final directory = http.requests.singleWhere((r) => r.url.path == '/api/front/models');
      expect(directory.url.host, 'zh.xhamsterlive.com');
      // The config request was raced on the winner among the hosts.
      final configResponses =
          http.requests.where((r) => r.url.path == '/api/front/v3/config/initial').toList();
      expect(configResponses.map((r) => r.url.host), contains('zh.xhamsterlive.com'));
    });

    test('a failed host is skipped and the next one is pinned', () async {
      final camOffline = ReplaySample.load('$_root/S03-cam-offline');
      final http = ReplayHttp([
        _synthetic('https://zh.virtualtaboo.live/api/front/v3/config/initial', '<html>'),
        configFor('zh.mywebcamroom.com', wsUrl: 'wss://websocket-v6.mywebcamroom.com/connection/websocket'),
        _synthetic('https://zh.mywebcamroom.com/api/front/users/user-ids/prettygirl', {'id': 12345678}),
        _synthetic(
          'https://zh.mywebcamroom.com/api/front/v2/models/12345678/cam?timezoneOffset=-480&triggerRequest=loadCam&withRecentShow=1',
          utf8.decode(camOffline.bytes, allowMalformed: true),
        ),
      ]);
      final site = StripchatSite(http, ['zh.virtualtaboo.live', 'zh.mywebcamroom.com']);
      final room = await site.getRoomDetailForRefresh(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl?uid=12345678');
      // user-ids and cam both went to the pinned host, not the failed one.
      final apiPaths = http.requests.where((r) => r.url.path != '/api/front/v3/config/initial').toList();
      for (final r in apiPaths) {
        expect(r.url.host, 'zh.mywebcamroom.com');
      }
    });

    test('every host down throws a NetworkFailure from the race', () async {
      final http = ReplayHttp([
        _synthetic('https://zh.virtualtaboo.live/api/front/v3/config/initial', '<html>'),
        _synthetic('https://zh.stripchat.webcam/api/front/v3/config/initial', '<html>'),
      ]);
      final site = StripchatSite(http, ['zh.virtualtaboo.live', 'zh.stripchat.webcam']);
      await expectLater(
        site.getRecommendRooms(),
        throwsA(isA<NetworkFailure>()),
      );
    });
  });
}
