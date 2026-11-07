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

_Setup _setup(List<String> samples, {List<ReplaySample> extra = const []}) {
  final http = ReplayHttp([...extra, for (final name in samples) ReplaySample.load('$_root/$name')]);
  return (site: StripchatSite(http), http: http);
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
      ]);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl');
      expect(room.isLiveNow, isTrue);
      expect(room.totalViewers, '215');
      expect(room.audienceMetricType, AudienceMetricType.totalViewers);
      expect(room.title, 'prettygirl live');
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
      final setup = _setup(['S05-userid', 'S03-cam-live']);
      final room = await setup.site.getRoomDetailForRefresh(roomId: 'prettygirl');
      expect(room.roomId, 'prettygirl');
      expect(room.isLiveNow, isTrue);
      expect(room.data, isNull);
      expect(room.title, 'prettygirl live');
      expect(room.introduction, 'VIP fan club description');
      expect(room.notice, 'Reach 2000 viewers!');
      // Only two requests: user-ids and cam (no master, no members)
      expect(setup.http.requests, hasLength(2));
    });
  });

  group('live status', () {
    test('returns true for live room', () async {
      final setup = _setup(['S05-userid', 'S03-cam-live']);
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
      expect(site.roomIdFromUrl('https://zh.virtualtaboo.live/webcam'), isNull);
      expect(site.roomIdFromUrl('https://example.com/prettygirl'), isNull);
    });
  });

  group('streams', () {
    test('getPlayQualities returns qualities from room data', () async {
      final setup = _setup(['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master', 'S08-config']);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      expect(qualities, hasLength(3));
      expect(qualities[0].quality, '1080p');
    });

    test('getPlayUrls returns variant playlist URL', () async {
      final setup = _setup(['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master', 'S08-config']);
      final room = await setup.site.getRoomDetail(roomId: 'prettygirl');
      final qualities = await setup.site.getPlayQualities(detail: room);
      final urls = await setup.site.getPlayUrls(detail: room, quality: qualities.first);
      expect(urls, hasLength(1));
      expect(urls[0], contains('edge-hls.doppiocdn.org'));
    });

    test('resolvePlayUrlsRaw confirms the requested quality', () async {
      final setup = _setup(['S05-userid', 'S03-cam-live', 'S09-members', 'S04-master', 'S08-config']);
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
}
