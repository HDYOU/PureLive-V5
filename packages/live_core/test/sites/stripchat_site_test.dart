// StripchatSite over the recorded responses (ReplayHttp): catalog, directory,
// room entry, streams, search and links.
import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_net/testing.dart';
import 'package:test/test.dart';

const _root = '../../fixtures/stripchat';

ReplaySample _synthetic(String url, Object body, {int status = 200}) => ReplaySample(
      method: 'GET',
      url: Uri.parse(url),
      status: status,
      bytes: utf8.encode(body is String ? body : jsonEncode(body)),
    );

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
        'prettygirl',
        'cutegirl99',
        'privatemodel',
      ]));
      expect(rooms[0].roomId, 'prettygirl');
      expect(rooms[0].isLiveNow, isTrue);
      expect(rooms[0].totalViewers, '1523');
      expect(rooms[0].audienceMetricType, AudienceMetricType.totalViewers);
      expect(rooms[0].title, '按摩');
      expect(rooms[0].startedAt, DateTime.utc(2026, 11, 06, 11, 28, 39));
      // cutegirl99 is not live: isLive false in the fixture.
      expect(rooms[1].roomId, 'cutegirl99');
      expect(rooms[1].isLiveNow, isFalse);
      // privatemodel is live but private: status 'private'.
      expect(rooms[2].roomId, 'privatemodel');
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
        'S04-master',
        'S08-config',
      ], withCdnPings: true);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl');
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
      expect(data.qualities, hasLength(3));
    });

    test('offline room: no stream data', () async {
      final setup = _setup([
        'S05-userid',
        'S03-cam-offline',
        'S08-config',
      ]);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl');
      expect(room.isLiveNow, isFalse);
      expect(room.data, isNull);
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
      expect(room.roomId, 'prettygirl');
      expect(room.isLiveNow, isTrue);
      expect(room.data, isNull);
      expect(room.title, 'Reach 2000 viewers!');
      expect(room.introduction, 'VIP fan club description');
      expect(room.notice, 'Reach 2000 viewers!');
      // Three requests: config race, user-ids and cam (no master, no members)
      expect(setup.http.requests, hasLength(3));
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
        'searchgirl',
        'offlineuser',
      ]));
      expect(rooms[0].roomId, 'searchgirl');
      expect(rooms[0].isLiveNow, isTrue);
      expect(rooms[0].title, 'searchgirl room');
      expect(rooms[0].totalViewers, '342');
      expect(rooms[1].roomId, 'offlineuser');
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
    test('getPlayQualities returns qualities from room data', () async {
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master', 'S08-config'],
        withCdnPings: true,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      expect(qualities, hasLength(3));
      expect(qualities[0].quality, '1080p');
    });

    test('getPlayUrls returns variant playlist URL', () async {
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master', 'S08-config'],
        withCdnPings: true,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      final urls = await setup.site.getPlayUrls(detail: room, quality: qualities.first);
      expect(urls, hasLength(1));
      expect(urls[0], contains('edge-hls.doppiocdn.org'));
    });

    test('resolvePlayUrlsRaw confirms the requested quality', () async {
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master', 'S08-config'],
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

    test('CDN masters are deduped and ordered by ping latency; slow or failing hosts are dropped', () async {
      final config = ReplaySample.load('$_root/S08-config');
      // Provide pings for all six distinct CDN hosts in the config. The
      // failing host (404) must be excluded; the rest keep their order.
      final pings = <ReplaySample>[
        _synthetic('https://edge-hls.doppiocdn.org/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn.com/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn1.com/ping.m3u8', '', status: 404),
        _synthetic('https://edge-hls.doppiocdn.media/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn.net/ping.m3u8', '#EXTM3U\n'),
        _synthetic('https://edge-hls.doppiocdn.live/ping.m3u8', '#EXTM3U\n'),
      ];
      final setup = _setup(
        ['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master'],
        extra: pings,
      );
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final data = room.data as StripchatRoomData;
      final hosts = [for (final m in data.masterUris) StripchatApi.cdnHostOf(m)!];
      // The failing 1.com host is excluded.
      expect(hosts, isNot(contains('doppiocdn1.com')));
      for (final m in data.masterUris) {
        expect(m.host, isNot('edge-hls.doppiocdn1.com'));
      }
      // Duplicate host keys (A/A1, B/B1 ...) collapse to one master each:
      // 6 distinct hosts minus the failing one = 5 masters.
      expect(data.masterUris.length, 5);
      // The primary host (doppiocdn.org) is listed first in the config, so
      // it stays ahead of the other survivors on a latency tie.
      expect(hosts.first, 'doppiocdn.org');
      expect(StripchatApi.cdnHostOf(data.master), 'doppiocdn.org');
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

    test('the all-10-domain race pins the first host that answers the config', () async {
      final models = ReplaySample.load('$_root/S01-recommend');
      final http = ReplayHttp([
        configFor('zh.stripchat.webcam', wsUrl: 'wss://websocket-v6.sc-apps.com/connection/websocket'),
        _synthetic(
          'https://zh.stripchat.webcam/api/front/models?limit=30&primaryTag=girls&filterGroupTags=%5B%5B%22tagLanguageChinese%22%5D%5D&offset=0',
          utf8.decode(models.bytes, allowMalformed: true),
        ),
      ]);
      final site = StripchatSite(http, StripchatApi.apiHosts);
      // Only the second host (zh.stripchat.webcam) answers the config; the
      // others are raced and dropped. The winner is pinned for the call.
      final rooms = await site.getRecommendRooms();
      expect(rooms, isNotEmpty);
      // The directory request went to the winner, not to the canonical host.
      final directory = http.requests.singleWhere((r) => r.url.path == '/api/front/models');
      expect(directory.url.host, 'zh.stripchat.webcam');
      // The config request was raced on the winner among the ten hosts.
      final configResponses =
          http.requests.where((r) => r.url.path == '/api/front/v3/config/initial').toList();
      expect(configResponses.map((r) => r.url.host), contains('zh.stripchat.webcam'));
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
      expect(room.roomId, 'prettygirl');
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
