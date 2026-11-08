// Stripchat parsing against the recorded samples.
import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_net/testing.dart';
import 'package:test/test.dart';

import 'fixture.dart';

Fixture _sample(String name) => Fixture.load('stripchat', name);

StripchatConfig _config() {
  final fixture = _sample('S08-config');
  return StripchatApi.config(fixture.body, status: fixture.status);
}

void main() {
  group('S08 config', () {
    test('parses CDN hosts and websocket config', () {
      final config = _config();
      expect(config.hlsStreamHosts['primary'], 'doppiocdn.org');
      expect(config.hlsStreamHosts['A'], 'doppiocdn.com');
      expect(config.websocketUrl, 'wss://websocket-v6.sc-apps.com/connection/websocket');
      expect(config.websocketToken, isNotEmpty);
    });
  });

  group('hls stream ordering', () {
    test('masterUris orders by response time, ties keep the config key order', () {
      const config = StripchatConfig(
        hlsStreamHosts: {
          'primary': 'doppiocdn.org',
          'A': 'doppiocdn.com',
          'B': 'doppiocdn1.com',
        },
        hlsStreamHostTimes: {
          'doppiocdn.org': 120,
          'doppiocdn.com': 120,
          'doppiocdn1.com': 30,
        },
        websocketUrl: 'wss://x.example/ws',
        websocketToken: 'tok',
      );
      final hosts = [for (final master in StripchatApi.masterUris('s', config)) StripchatApi.cdnHostOf(master)!];
      // Fastest first; the two 120 ms hosts tie, so the config key decides:
      // primary comes before A.
      expect(hosts, ['doppiocdn1.com', 'doppiocdn.org', 'doppiocdn.com']);
    });

    test('hosts without a measured time rank last, config key order among them', () {
      const config = StripchatConfig(
        hlsStreamHosts: {
          'primary': 'doppiocdn.org',
          'A': 'doppiocdn.com',
          'B': 'unknown.example',
        },
        hlsStreamHostTimes: {
          'doppiocdn.org': 40,
          'doppiocdn.com': 90,
        },
        websocketUrl: 'wss://x.example/ws',
        websocketToken: 'tok',
      );
      final hosts = [for (final master in StripchatApi.masterUris('s', config)) StripchatApi.cdnHostOf(master)!];
      expect(hosts, ['doppiocdn.org', 'doppiocdn.com', 'unknown.example']);
    });

    test('duplicate host keys collapse to one master', () {
      const config = StripchatConfig(
        hlsStreamHosts: {
          'primary': 'doppiocdn.org',
          'E': 'doppiocdn.org',
          'A': 'doppiocdn.com',
          'A1': 'doppiocdn.com',
        },
        hlsStreamHostTimes: {'doppiocdn.org': 10, 'doppiocdn.com': 10},
        websocketUrl: 'wss://x.example/ws',
        websocketToken: 'tok',
      );
      final hosts = [for (final master in StripchatApi.masterUris('s', config)) StripchatApi.cdnHostOf(master)!];
      expect(hosts, hasLength(2));
      expect(hosts, containsAll(['doppiocdn.org', 'doppiocdn.com']));
    });

    test('withFallbackCdnHosts fills missed hosts from the common CDN list', () {
      const config = StripchatConfig(
        hlsStreamHosts: {
          'primary': 'cdn-new.example',
        },
        websocketUrl: 'wss://x.example/ws',
        websocketToken: 'tok',
      );
      final merged = StripchatApi.withFallbackCdnHosts(config);
      // The config host is not in the common list and its probe missed, so
      // every common host (0 ms) ranks ahead of it and it stays last.
      final hosts = [for (final m in StripchatApi.masterUris('s', merged)) StripchatApi.cdnHostOf(m)!];
      expect(hosts.first, 'doppiocdn.org');
      expect(hosts.last, 'cdn-new.example');
    });

    test('probed measures every distinct config host and marks the misses last', () async {
      final config = _config();
      // Five hosts answer the ping; B / doppiocdn1.com answers 404, so it
      // keeps the missed marker and sorts after the five.
      final pings = [
        for (final host in [
          'doppiocdn.org',
          'doppiocdn.com',
          'doppiocdn.media',
          'doppiocdn.net',
          'doppiocdn.live',
        ])
          ReplaySample(
            method: 'GET',
            url: Uri.https('edge-hls.$host', '/ping.m3u8'),
            status: 200,
            bytes: utf8.encode('#EXTM3U\n'),
          ),
        ReplaySample(
          method: 'GET',
          url: Uri.https('edge-hls.doppiocdn1.com', '/ping.m3u8'),
          status: 404,
          bytes: const [],
        ),
      ];
      final http = ReplayHttp(pings);
      final probed = await StripchatApi.probed(http, config);
      // Every config host carries a time (the probed answers plus the
      // fallback fill); the 404 one is marked missed.
      expect(probed.hlsStreamHostTimes, hasLength(6));
      expect(probed.hlsStreamHostTimes['doppiocdn1.com'], StripchatApi.probedHostMissed);
      for (final host in [
        'doppiocdn.org',
        'doppiocdn.com',
        'doppiocdn.media',
        'doppiocdn.net',
        'doppiocdn.live',
      ]) {
        expect(probed.hlsStreamHostTimes[host], greaterThanOrEqualTo(0));
      }
      // The missed host is still a line, ranked last.
      final hosts = [for (final m in StripchatApi.masterUris('s', probed)) StripchatApi.cdnHostOf(m)!];
      expect(hosts, hasLength(6));
      expect(hosts.last, 'doppiocdn1.com');
      // The probes were actually sent.
      expect(http.requests, hasLength(6));
    });
  });
  group('S01 models list', () {
    test('parses live and private models, skips invalid usernames', () {
      final fixture = _sample('S01-guest');
      final models = StripchatApi.modelsList(fixture.body, status: fixture.status);
      expect(models, hasLength(3));
      expect(models.map((m) => m.username).toList(), ['prettygirl', 'cutegirl99', 'privatemodel']);
      expect(models[0].modelId, 12345678);
      expect(models[0].isLive, isTrue);
      expect(models[0].status, 'public');
      expect(models[0].viewersCount, 1523);
      expect(models[0].avatarUrl, 'https://img.stripchat.com/avatar/prettygirl.jpg');
      expect(models[0].startedAt, DateTime.utc(2026, 11, 06, 11, 28, 39));
      expect(models[0].title, '按摩');
      expect(models[2].status, 'private');
      expect(models[2].isLive, isTrue);
    });

    test('empty response returns empty list', () {
      expect(StripchatApi.modelsList('{"models":[]}'), isEmpty);
    });

    test('invalid JSON throws ApiChanged', () {
      expect(() => StripchatApi.modelsList('<html>'), throwsA(isA<ApiChanged>()));
    });
  });

  group('S02 model card', () {
    test('parses a live model card', () {
      final fixture = _sample('S02-detail-live');
      final model = StripchatApi.modelCard(fixture.body, status: fixture.status);
      expect(model.username, 'prettygirl');
      expect(model.modelId, 12345678);
      expect(model.isLive, isTrue);
      expect(model.status, 'public');
      expect(model.viewersCount, 1523);
      expect(model.startedAt, DateTime.utc(2026, 11, 06, 11, 28, 39));
      expect(model.description, 'Welcome to my stream!');
    });

    test('missing model throws ApiChanged', () {
      expect(() => StripchatApi.modelCard('{"model":null}'), throwsA(isA<ApiChanged>()));
    });

    test('invalid username throws ApiChanged', () {
      expect(
        () => StripchatApi.modelCard(jsonEncode({'model': {'username': 'webcam'}})),
        throwsA(isA<ApiChanged>()),
      );
    });
  });

  group('S03 cam detail', () {
    test('parses a live cam with HLS lines', () {
      final fixture = _sample('S03-cam-live');
      final cam = StripchatApi.camDetail(fixture.body, modelId: 12345678, status: fixture.status);
      expect(cam.modelId, 12345678);
      expect(cam.username, 'prettygirl');
      expect(cam.streamName, 'prettygirl-webcam');
      expect(cam.hlsLines, isEmpty);
      expect(cam.pixelatedResolutions, isEmpty);
      expect(cam.isLive, isTrue);
      expect(cam.status, 'public');
      expect(cam.viewersCount, 0);
      expect(cam.startedAt, DateTime.utc(2026, 11, 06, 11, 43, 20));
      expect(cam.title, 'Reach 2000 viewers!');
      expect(cam.description, 'prettygirl live\nWelcome to my stream!');
      expect(cam.introduction, 'VIP fan club description');
      expect(cam.notice, 'Reach 2000 viewers!');
    });

    test('parses an offline cam with no stream', () {
      final fixture = _sample('S03-cam-offline');
      final cam = StripchatApi.camDetail(fixture.body, modelId: 12345678, status: fixture.status);
      expect(cam.isLive, isFalse);
      expect(cam.status, 'offline');
      expect(cam.streamName, '');
      expect(cam.hlsLines, isEmpty);
      expect(cam.viewersCount, 0);
      expect(cam.startedAt, isNull);
      expect(cam.introduction, '');
      expect(cam.notice, '');
    });

    test('model id mismatch throws ApiChanged', () {
      expect(
        () => StripchatApi.camDetail(_sample('S03-cam-live').body, modelId: 99999),
        throwsA(isA<ApiChanged>()),
      );
    });
  });

  group('S04 master playlist', () {
    test('parses HLS master into qualities', () {
      final fixture = _sample('S04-master');
      final master = Uri.parse('https://streaming-prettygirl1.stripchat.com/hls/prettygirl-webcam/index.m3u8');
      final variants = StripchatApi.parseVariants(fixture.body, master: master, status: fixture.status);
      expect(variants, hasLength(3));
      final qualities = StripchatApi.qualitiesFromVariants(variants, username: 'prettygirl');
      expect(qualities, hasLength(3));
      expect(qualities[0].quality, '1080p');
      expect(qualities[1].quality, '720p');
      expect(qualities[2].quality, '480p');
      expect(qualities[0].sort > qualities[1].sort, isTrue);
    });

    test('HTTP 404 is StreamUnavailable', () {
      expect(
        () => StripchatApi.parseVariants('', master: Uri.parse('https://x.m3u8'), status: 404),
        throwsA(isA<StreamUnavailable>()),
      );
    });

    test('not a playlist throws ApiChanged', () {
      expect(
        () => StripchatApi.parseVariants('not a playlist', master: Uri.parse('https://x.m3u8')),
        throwsA(isA<ApiChanged>()),
      );
    });
  });

  group('S07 search', () {
    test('parses search suggestions', () {
      final fixture = _sample('S07-search');
      final models = StripchatApi.searchModels(fixture.body, status: fixture.status);
      expect(models, hasLength(2));
      expect(models[0].username, 'searchgirl');
      expect(models[0].isLive, isTrue);
      expect(models[0].title, 'searchgirl room');
      expect(models[1].username, 'offlineuser');
      expect(models[1].isLive, isFalse);
    });

    test('empty response returns empty list', () {
      expect(StripchatApi.searchModels('[]'), isEmpty);
    });
  });

  group('S09 members', () {
    test('sums guest types', () {
      expect(
        StripchatApi.membersCount('''
          {"guests": 100, "spies": 5, "invisibles": 10, "greens": 50, "golds": 20, "regulars": 30}
        '''),
        215,
      );
    });

    test('returns 0 for non-JSON', () {
      expect(StripchatApi.membersCount('<html>'), 0);
    });

    test('returns 0 when keys missing', () {
      expect(StripchatApi.membersCount('{}'), 0);
    });
  });

  group('helpers', () {
    test('isUsername validates user names', () {
      expect(StripchatApi.isUsername('prettygirl'), isTrue);
      expect(StripchatApi.isUsername('user_123'), isTrue);
      expect(StripchatApi.isUsername('webcam'), isFalse);
      expect(StripchatApi.isUsername(''), isFalse);
      expect(StripchatApi.isUsername('a' * 31), isFalse);
    });

    test('roomPageUrl builds correct URL', () {
      expect(StripchatApi.roomPageUrl('prettygirl'), 'https://zh.virtualtaboo.live/prettygirl');
    });

    test('parseRoomId splits the ?uid= suffix', () {
      expect(StripchatApi.parseRoomId('prettygirl?uid=12345678'), (username: 'prettygirl', userId: 12345678));
      // A bare username gives a null user id.
      final bare = StripchatApi.parseRoomId('prettygirl');
      expect(bare.username, 'prettygirl');
      expect(bare.userId, isNull);
      // Whitespace is trimmed.
      expect(StripchatApi.parseRoomId('  prettygirl?uid=9  '), (username: 'prettygirl', userId: 9));
      // A non-numeric uid falls back to null.
      expect(StripchatApi.parseRoomId('prettygirl?uid=abc').userId, isNull);
    });

    test('masterUri builds correct HLS URL', () {
      expect(
        StripchatApi.masterUri('prettygirl-webcam', 'streaming-prettygirl.stripchat.com').toString(),
        'https://edge-hls.streaming-prettygirl.stripchat.com/hls/prettygirl-webcam/master/prettygirl-webcam_auto.m3u8?preferredVideoCodec=av1&psch=v2&pkey=bXorqTB5ZhP5FcpX',
      );
    });

    test('thumbnailUrl builds correct URL', () {
      expect(
        StripchatApi.thumbnailUrl(1730800000, '12345678'),
        'https://img.doppiocdn.live/thumbs/1730800000/12345678_webp',
      );
    });

    test('catalog returns single category with sort areas', () {
      final catalog = StripchatApi.catalog();
      expect(catalog.id, 'stripchat');
      expect(catalog.name, 'Stripchat');
      expect(catalog.children, hasLength(15));
      expect(catalog.children[0].areaId, 'all');
      expect(catalog.children[0].areaName, '全部直播');
      expect(catalog.children[1].areaId, 'recommended');
      expect(catalog.children[1].areaName, '直播推荐');
    });

    test('restrictionFor maps status correctly', () {
      expect(StripchatApi.restrictionFor('public'), LiveRestriction.none);
      expect(StripchatApi.restrictionFor('private'), LiveRestriction.private);
      expect(StripchatApi.restrictionFor('groupShow'), LiveRestriction.paid);
      expect(StripchatApi.restrictionFor('offline'), LiveRestriction.none);
    });

    test('isLiveStatus recognises groupShow', () {
      expect(StripchatApi.isLiveStatus('public'), isTrue);
      expect(StripchatApi.isLiveStatus('groupShow'), isTrue);
      expect(StripchatApi.isLiveStatus('private'), isFalse);
      expect(StripchatApi.isLiveStatus('offline'), isFalse);
    });
  });
}
