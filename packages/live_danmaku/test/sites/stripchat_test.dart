// Stripchat's WebSocket danmaku (M5.xx): protocol frames, chat / tip / lovense
// parsing, and the connect+subscribe handshake over a fake socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:live_core/live_core.dart' as lc;
import 'package:live_danmaku/live_danmaku.dart';
import 'package:live_net/live_net.dart';
import 'package:test/test.dart';

const _websocketUrl = 'wss://websocket-v6.sc-apps.com/connection/websocket';
const _modelId = 278721362;
const _token = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.test';

final lc.StripchatDanmakuArgs _args =
    lc.StripchatDanmakuArgs(websocketUrl: _websocketUrl, token: _token, modelId: _modelId);

/// A fake WebSocket channel that records sent frames and queues incoming ones.
final class _Channel implements SocketChannel {
  final StreamController<Object?> incoming = StreamController<Object?>();
  final List<Object> sent = [];
  bool closed = false;

  @override
  Stream<Object?> get stream => incoming.stream;

  @override
  void add(Object data) {
    if (closed) throw StateError('socket is closed');
    sent.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async => closed = true;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  /// Delivers [frame] asynchronously so the handler processes it after the
  /// current microtask.
  Future<void> receive(Object frame) async {
    incoming.add(frame);
    await Future<void>.delayed(Duration.zero);
  }
}

/// Hands out fake channels and records every handshake attempt.
final class _Connector {
  new({this.failures = 0});

  final int failures;
  final List<Uri> endpoints = [];
  final List<Map<String, String>> headers = [];
  final List<ProxyRoute> routes = [];
  final List<_Channel> channels = [];

  Future<SocketChannel> call(
    Uri endpoint, {
    required Map<String, String> headers,
    required Iterable<String>? protocols,
    required ProxyRoute route,
    required Duration connectTimeout,
  }) async {
    endpoints.add(endpoint);
    this.headers.add(headers);
    routes.add(route);
    if (endpoints.length <= failures) throw SocketException('refused');
    final channel = _Channel();
    channels.add(channel);
    return channel;
  }
}

List<DanmakuEvent> _record(DanmakuConnection connection) {
  final events = <DanmakuEvent>[];
  connection.events.listen(events.add);
  return events;
}

List<lc.LiveMessage> _messages(List<DanmakuEvent> events) => [
      for (final event in events)
        if (event is DanmakuReceived) event.message,
    ];

Future<void> _wait(Duration duration) => Future<void>.delayed(duration);

/// Waits until [condition] holds, at most five seconds.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await _wait(const Duration(milliseconds: 2));
  }
}

/// A text chat push from the server.
String _chatPush({
  String username = 'viewer01',
  String userId = 'u001',
  String body = 'hello',
  String color = '#FF0000',
  String messageId = 'msg-001',
  int createdAt = 1790536489000,
  int? userLevel,
}) =>
    jsonEncode({
      'push': {
        'channel': 'newChatMessage@$_modelId',
        'pub': {
          'data': {
            'id': messageId,
            'type': 'text',
            'userData': {
              'id': userId,
              'username': username,
              'name': username,
              'color': color,
              if (userLevel != null) 'userRanking': {'level': userLevel},
            },
            'details': {'body': body},
            'createdAt': createdAt,
          },
        },
      },
    });

/// A tip (gift) push.
String _tipPush({
  String username = 'patron',
  String userId = 'u002',
  int amount = 50,
  String messageId = 'msg-002',
  int createdAt = 1790536500000,
  String color = '#00FF00',
  int? userLevel,
}) =>
    jsonEncode({
      'push': {
        'channel': 'newChatMessage@$_modelId',
        'pub': {
          'data': {
            'id': messageId,
            'type': 'tip',
            'userData': {
              'id': userId,
              'username': username,
              'name': username,
              'color': color,
              if (userLevel != null) 'userRanking': {'level': userLevel},
            },
            'details': {'amount': amount},
            'amount': amount,
            'createdAt': createdAt,
          },
        },
      },
    });

/// A lovense (toy) push.
String _lovensePush({
  String username = 'toy_user',
  String userId = 'u003',
  String power = 'high',
  int time = 15,
  String messageId = 'msg-003',
  int createdAt = 1790536510000,
  String color = '#0000FF',
  int? userLevel,
}) =>
    jsonEncode({
      'push': {
        'channel': 'newChatMessage@$_modelId',
        'pub': {
          'data': {
            'id': messageId,
            'type': 'lovense',
            'userData': {
              'id': userId,
              'username': username,
              'name': username,
              'color': color,
              if (userLevel != null) 'userRanking': {'level': userLevel},
            },
            'details': {
              'lovenseDetails': {
                'detail': {'power': power, 'time': time},
                'clientUserInfo': {
                  'id': userId,
                  'username': username,
                  'name': username,
                  'color': color,
                },
              },
            },
            'createdAt': createdAt,
          },
        },
      },
    });

void main() {
  group('protocol', () {
    test('headers, heartbeat interval, and frame shapes', () {
      expect(
        StripchatDanmakuProtocol.headers,
        {
          'origin': 'https://zh.virtualtaboo.live',
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        },
      );
      expect(StripchatDanmakuProtocol.heartbeatInterval, const Duration(seconds: 30));
      expect(
        StripchatDanmakuProtocol.connectFrame(_token),
        '{"connect":{"token":"$_token"},"id":1}',
      );
      expect(
        StripchatDanmakuProtocol.subscribeFrame(_modelId),
        '{"subscribe":{"channel":"newChatMessage@$_modelId"},"id":2}',
      );
      expect(StripchatDanmakuProtocol.pongFrame('abc'), '{"pong":"abc"}');
      expect(StripchatDanmakuProtocol.pongFrame(42), '{"pong":42}');
    });

    test('a text chat: type, sender, body, id, time, colour', () {
      final result = StripchatDanmakuProtocol.read(_chatPush());
      expect(result.messages, hasLength(1));
      final msg = result.messages.single;
      expect(msg.type, lc.LiveMessageType.chat);
      expect(msg.userName, 'viewer01');
      expect(msg.userId, 'u001');
      expect(msg.message, 'hello');
      expect(msg.messageId, 'msg-001');
      expect(msg.sentAt, DateTime.fromMillisecondsSinceEpoch(1790536489000, isUtc: true));
      expect(msg.color, const lc.LiveMessageColor(0xFF, 0x00, 0x00));
      expect(result.respondEmpty, isFalse);
    });

    test('a tip: gift type, amount, sender', () {
      final result = StripchatDanmakuProtocol.read(_tipPush());
      expect(result.messages, hasLength(1));
      final msg = result.messages.single;
      expect(msg.type, lc.LiveMessageType.gift);
      expect(msg.userName, 'patron');
      expect(msg.userId, 'u002');
      expect(msg.message, 'patron 已支付 50 代币');
      expect(msg.messageId, 'msg-002');
      expect(msg.sentAt, DateTime.fromMillisecondsSinceEpoch(1790536500000, isUtc: true));
      expect(msg.color, const lc.LiveMessageColor(0x00, 0xFF, 0x00));
      final data = msg.data! as lc.LiveGift;
      expect(data.name, '代币');
      expect(data.count, 50);
      expect(data.kind, lc.LiveGiftKind.tip);
      expect(data.unitPrice, 1);
      expect(data.totalValue, 50);
    });

    test('a lovense: notice type, power, duration', () {
      final result = StripchatDanmakuProtocol.read(_lovensePush());
      expect(result.messages, hasLength(1));
      final msg = result.messages.single;
      expect(msg.type, lc.LiveMessageType.notice);
      expect(msg.userName, 'toy_user');
      expect(msg.userId, 'u003');
      expect(msg.message, 'toy_user: 高强度 · 15秒');
      expect(msg.messageId, 'msg-003');
      expect(msg.sentAt, DateTime.fromMillisecondsSinceEpoch(1790536510000, isUtc: true));
      expect(msg.color, const lc.LiveMessageColor(0x00, 0x00, 0xFF));
    });

    test('lovense with medium / low power', () {
      final m = StripchatDanmakuProtocol.read(_lovensePush(power: 'medium')).messages.single;
      expect(m.message, 'toy_user: 中强度 · 15秒');
      final l = StripchatDanmakuProtocol.read(_lovensePush(power: 'low')).messages.single;
      expect(l.message, 'toy_user: 低强度 · 15秒');
    });

    test('userRanking.level fills the sender level when present', () {
      final chat = StripchatDanmakuProtocol.read(_chatPush(userLevel: 3)).messages.single;
      expect(chat.userLevelValue, 3);
      expect(chat.userLevel, '3');
      final tip = StripchatDanmakuProtocol.read(_tipPush(userLevel: 7)).messages.single;
      expect(tip.userLevelValue, 7);
      expect(tip.userLevel, '7');
      final lovense = StripchatDanmakuProtocol.read(_lovensePush(userLevel: 1)).messages.single;
      expect(lovense.userLevelValue, 1);
      expect(lovense.userLevel, '1');
    });

    test('missing userRanking leaves the level unset', () {
      final chat = StripchatDanmakuProtocol.read(_chatPush()).messages.single;
      expect(chat.userLevelValue, isNull);
      expect(chat.userLevel, '');
      final tip = StripchatDanmakuProtocol.read(_tipPush()).messages.single;
      expect(tip.userLevelValue, isNull);
      expect(tip.userLevel, '');
    });

    test('unknown push types are ignored', () {
      final text = _chatPush().replaceAll('"text"', '"customEvent"');
      expect(StripchatDanmakuProtocol.read(text).messages, isEmpty);
    });

    test('push with no data or wrong channel is ignored', () {
      expect(StripchatDanmakuProtocol.read('{}').messages, isEmpty);
      expect(
        StripchatDanmakuProtocol
            .read(jsonEncode({'push': {'channel': 'other', 'pub': {'data': {}}}}))
            .messages,
        isEmpty,
      );
      expect(
        StripchatDanmakuProtocol
            .read(jsonEncode({'push': {'channel': 'newChatMessage@$_modelId', 'pub': {}}}))
            .messages,
        isEmpty,
      );
    });

    test('empty body or name drops a text message', () {
      var frame = _chatPush(body: '');
      expect(StripchatDanmakuProtocol.read(frame).messages, isEmpty);
      frame = _chatPush(username: '');
      expect(StripchatDanmakuProtocol.read(frame).messages, isEmpty);
    });

    test('keepalive {} triggers respondEmpty; ping triggers no response', () {
      expect(StripchatDanmakuProtocol.read('{}').respondEmpty, isTrue);
      expect(StripchatDanmakuProtocol.read(jsonEncode({'ping': 'abc'})).respondEmpty, isFalse);
      expect(StripchatDanmakuProtocol.read(jsonEncode({'ping': 42})).respondEmpty, isFalse);
    });

    test('bad input: null, too long, non-string non-bytes', () {
      expect(StripchatDanmakuProtocol.read(null).messages, isEmpty);
      expect(StripchatDanmakuProtocol.read(42).messages, isEmpty);
      expect(StripchatDanmakuProtocol.read('not json').messages, isEmpty);
      expect(StripchatDanmakuProtocol.read(['x']).messages, isEmpty);
    });

    test('binary frames are decoded as UTF-8', () {
      final bytes = utf8.encode(_chatPush(body: 'binary test'));
      final result = StripchatDanmakuProtocol.read(bytes);
      expect(result.messages, hasLength(1));
      expect(result.messages.single.message, 'binary test');
    });

    test('default colour is white when absent', () {
      final frame = _chatPush(color: '');
      final msg = StripchatDanmakuProtocol.read(frame).messages.single;
      expect(msg.color, lc.LiveMessageColor.white);
    });

    test('invalid colour falls back to white', () {
      final frame = _chatPush(color: 'zzzzzz');
      final msg = StripchatDanmakuProtocol.read(frame).messages.single;
      expect(msg.color, lc.LiveMessageColor.white);
    });
  });

  group('connection', () {
    test(
        'timing and registration: heartbeat 30 s, site stripchat,'
        ' no heartbeat frame, no join timeout', () {
      final connection = StripchatDanmakuConnection();
      expect(connection.heartbeatInterval, const Duration(seconds: 30));
      expect(connection.site, 'stripchat');
      final policy = connection.policy;
      expect(policy.heartbeatInterval, const Duration(seconds: 30));
      expect(policy.inactivityTimeout, isNull);
      expect(policy.joinTimeout, isNull);
      expect(policy.maxReconnects, 8);
      expect(policy.reconnectBaseDelay, const Duration(seconds: 1));
      expect(policy.connectTimeout, const Duration(seconds: 10));
    });

    test(
        'opens the WebSocket, sends connect then subscribe, is ready on'
        ' the subscribed reply, reads chat, answers pings', () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(_args);
      expect(connector.endpoints, [Uri.parse(_websocketUrl)]);
      expect(connector.headers.single, StripchatDanmakuProtocol.headers);
      expect(connector.routes.single, const DirectRoute());
      expect(events, [const DanmakuReady()]);
      expect(connection.isConnected, isTrue);
      final channel = connector.channels.single;
      expect(
        channel.sent,
        [
          StripchatDanmakuProtocol.connectFrame(_token),
          StripchatDanmakuProtocol.subscribeFrame(_modelId),
        ],
      );
      // subscribed reply -> ready fires only once
      await channel.receive(jsonEncode({'subscribed': true}));
      expect(events.whereType<DanmakuReady>(), hasLength(1));
      // chat arrives after ready
      await channel.receive(_chatPush(body: 'hi there'));
      expect(_messages(events), hasLength(1));
      expect(_messages(events).single.message, 'hi there');
      // keepalive {} is echoed back
      await channel.receive('{}');
      expect(channel.sent.last, '{}');
      // server ping -> client pong
      await channel.receive(jsonEncode({'ping': 'abc123'}));
      expect(channel.sent.last, '{"pong":"abc123"}');
      // another ping with numeric value
      await channel.receive(jsonEncode({'ping': 42}));
      expect(channel.sent.last, '{"pong":42}');
      // mixed: chat + keepalive in sequence
      await channel.receive('{}');
      await channel.receive(_chatPush(body: 'second'));
      await channel.receive(_tipPush(amount: 100));
      await channel.receive(_lovensePush(power: 'high', time: 30));
      final msgs = _messages(events);
      expect(msgs, hasLength(4));
      expect(msgs[1].message, 'second');
      expect(msgs[2].type, lc.LiveMessageType.gift);
      expect(msgs[3].type, lc.LiveMessageType.notice);
      await connection.close();
    });

    test('multiple messages in one frame are emitted in order', () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(_args);
      final channel = connector.channels.single;
      await channel.receive(jsonEncode({'subscribed': true}));
      final batch = [
        _chatPush(body: 'first', messageId: 'm1'),
        _chatPush(body: 'second', messageId: 'm2'),
        _tipPush(amount: 10, messageId: 'm3'),
      ].join('\n');
      await channel.receive(batch);
      final msgs = _messages(events);
      expect(msgs, hasLength(3));
      expect(msgs[0].message, 'first');
      expect(msgs[1].message, 'second');
      expect(msgs[2].type, lc.LiveMessageType.gift);
      await connection.close();
    });

    test('empty endpoint ends with connectionFailed', () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(
        lc.StripchatDanmakuArgs(websocketUrl: '', token: _token, modelId: _modelId),
      );
      expect(
          events,
          [isA<DanmakuClosed>()
              .having((e) => e.reason, 'reason', DanmakuCloseReason.connectionFailed)]);
      expect(connection.status, DanmakuStatus.closed);
      expect(connector.endpoints, isEmpty);
    });

    test('wrong-arg type throws ArgumentError', () async {
      final connection = StripchatDanmakuConnection();
      await expectLater(connection.connect('not-args'), throwsArgumentError);
    });

    test(
        'a dropped socket reconnects and resends connect+subscribe', () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(_args);
      final first = connector.channels.single;
      await first.receive(jsonEncode({'subscribed': true}));
      expect(events.whereType<DanmakuReady>(), hasLength(1));
      // drop the socket
      await first.incoming.close();
      await _until(() => connector.channels.length == 2);
      final second = connector.channels.last;
      expect(second.sent, [
        StripchatDanmakuProtocol.connectFrame(_token),
        StripchatDanmakuProtocol.subscribeFrame(_modelId),
      ]);
      expect(events, [
        const DanmakuReady(),
        const DanmakuReconnecting(DanmakuInterruption.disconnected),
        const DanmakuReady(),
      ]);
      await second.receive(jsonEncode({'subscribed': true}));
      expect(events.whereType<DanmakuReady>(), hasLength(2));
      await connection.close();
    });

    test(
        'reconnects back off and gives up after the policy\'s count', () async {
      final delays = <Duration>[];
      final connector = _Connector(failures: 10);
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await runZoned(
        () async {
          await connection.connect(_args);
          await _until(() => events.whereType<DanmakuClosed>().isNotEmpty);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration >= const Duration(seconds: 1)) {
              delays.add(duration);
              return parent.createTimer(zone, Duration.zero, callback);
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      expect(
        delays,
        [
          const Duration(seconds: 2),
          const Duration(seconds: 3),
          const Duration(seconds: 4),
          const Duration(seconds: 5),
          const Duration(seconds: 6),
          const Duration(seconds: 6),
          const Duration(seconds: 6),
          const Duration(seconds: 6),
        ],
      );
      expect(
        events.last,
        isA<DanmakuClosed>()
            .having((e) => e.reason, 'reason', DanmakuCloseReason.reconnectsExhausted),
      );
      expect(connection.status, DanmakuStatus.closed);
    });

    test('close: no send or event after close; closing twice is harmless',
        () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(_args);
      final channel = connector.channels.single;
      await channel.receive(jsonEncode({'subscribed': true}));
      await connection.close();
      await connection.close();
      channel.incoming.add(_chatPush(body: 'after close'));
      await _wait(const Duration(milliseconds: 100));
      expect(channel.sent, [
        StripchatDanmakuProtocol.connectFrame(_token),
        StripchatDanmakuProtocol.subscribeFrame(_modelId),
      ]);
      expect(events.whereType<DanmakuReceived>(), isEmpty);
      expect(connection.status, DanmakuStatus.idle);
    });

    test(
        'switching to another room closes the first socket and joins anew',
        () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(_args);
      final other = lc.StripchatDanmakuArgs(
        websocketUrl: _websocketUrl,
        token: 'other-token',
        modelId: 999999,
      );
      await connection.connect(other);
      expect(connector.endpoints, hasLength(2));
      expect(connector.channels.first.closed, isTrue);
      final firstSent = connector.channels.first.sent;
      final secondSent = connector.channels.last.sent;
      expect(firstSent, [
        StripchatDanmakuProtocol.connectFrame(_token),
        StripchatDanmakuProtocol.subscribeFrame(_modelId),
      ]);
      expect(secondSent, [
        StripchatDanmakuProtocol.connectFrame('other-token'),
        StripchatDanmakuProtocol.subscribeFrame(999999),
      ]);
      await connector.channels.last.receive(jsonEncode({'subscribed': true}));
      expect(_messages(events), isEmpty, reason: 'first room messages discarded');
      await connection.close();
    });

    test('registers under stripchat in DanmakuRegistry', () {
      final registry = DanmakuRegistry({
        'stripchat': StripchatDanmakuConnection.new,
      });
      expect(registry.platforms, ['stripchat']);
      expect(registry.connectionFor(' STRIPCHAT '), isA<StripchatDanmakuConnection>());
      expect(registry.connectionFor('pandalive'), isA<EmptyDanmakuConnection>());
    });

    test('a local case-sensitive handshake end to end', () async {
      final connector = _Connector();
      final connection = StripchatDanmakuConnection(connector: connector.call);
      final events = _record(connection);
      await connection.connect(_args);
      final channel = connector.channels.single;
      expect(channel.sent, [
        StripchatDanmakuProtocol.connectFrame(_token),
        StripchatDanmakuProtocol.subscribeFrame(_modelId),
      ]);
      expect(connector.headers.single['origin'], 'https://zh.virtualtaboo.live');
      await channel.receive(jsonEncode({'subscribed': true}));
      expect(events.first, const DanmakuReady());
      await channel.receive(_chatPush(body: 'local test'));
      expect(_messages(events).single.message, 'local test');
      await connection.close();
    });
  });
}
