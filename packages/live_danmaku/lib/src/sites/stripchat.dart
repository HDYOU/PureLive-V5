import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_danmaku/src/connection_base.dart';
import 'package:live_danmaku/src/socket_connection.dart';
import 'package:meta/meta.dart';

/// Result of parsing one WebSocket frame.
@immutable
final class StripchatFrameResult {
  const StripchatFrameResult({
    required this.messages,
    this.respondEmpty = false,
    this.pingValue,
  });
  final List<LiveMessage> messages;

  /// Send a `{}` keepalive reply.
  final bool respondEmpty;

  /// The server's ping value to echo back in a pong frame; null when absent.
  final Object? pingValue;
}

/// Stripchat's public chat over WebSocket (anonymous, token in connect frame).
///
/// Protocol (from the web client):
/// - Connect to [args.websocketUrl] without token in the URL.
/// - On open: send connect frame with token, then subscribe to
///   `newChatMessage@{modelId}`.
/// - The server responds with `subscribed`; client calls [DanmakuSocketSession.ready].
/// - Server may send `{}` (keepalive) or `{ping: "..."}` (client replies `{pong: ...}`).
/// - Chat pushes arrive as `{"push":{"channel":"newChatMessage@{id}","pub":{"data":{...}}}}`.
abstract final class StripchatDanmakuProtocol {
  /// WebSocket handshake headers, built from the API host that served the
  /// config so origin/referer match the host the token came from.
  static Map<String, String> headersFor(String apiHost) => {
        'origin': 'https://$apiHost',
        'referer': 'https://$apiHost/',
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/138.0.0.0 Safari/537.36',
      };

  /// Heartbeat period (30 s). Client does not send pings; the server-initiated
  /// ping/pong handles liveness.
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// Connect frame with auth token.
  static String connectFrame(String token) => '{"connect":{"token":"$token"},"id":1}';

  /// Subscribe frame for the model's chat channel.
  static String subscribeFrame(int modelId) => '{"subscribe":{"channel":"newChatMessage@$modelId"},"id":2}';

  /// Pong reply to a server ping.
  static String pongFrame(Object pingValue) => '{"pong":${jsonEncode(pingValue)}}';

  /// Reads one text frame; returns parsed messages and control actions.
  /// A frame may contain several JSON objects separated by newlines; each is
  /// parsed in order.
  static StripchatFrameResult read(Object? data) {
    final text = switch (data) {
      final String text => text,
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (text == null || text.length > 256 * 1024) {
      return const StripchatFrameResult(messages: []);
    }
    if (text.trim() == '{}') {
      return const StripchatFrameResult(messages: [], respondEmpty: true);
    }
    final lines = text.split('\n');
    final messages = <LiveMessage>[];
    var respondEmpty = false;
    Object? pingValue;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line == '{}') {
        respondEmpty = true;
        continue;
      }
      Object? parsed;
      try {
        parsed = jsonDecode(line);
      } on FormatException {
        continue;
      }
      final obj = _object(parsed);
      if (obj.containsKey('ping')) {
        pingValue = obj['ping'];
        continue;
      }
      messages.addAll(_parsePush(obj));
    }
    return StripchatFrameResult(messages: messages, respondEmpty: respondEmpty, pingValue: pingValue);
  }

  static List<LiveMessage> _parsePush(Map<String, Object?> obj) {
    final messages = <LiveMessage>[];
    final push = _object(obj['push']);
    final pub = _object(push['pub']);
    final data = _object(pub['data']);
    // Real structure: push.pub.data.message contains the actual message.
    // Some frames may place fields directly under data (flat layout).
    final msg = _object(data['message']);
    final container = msg.isNotEmpty ? msg : data;
    if (container.isEmpty) return const [];
    final type = _text(container['type']) ?? '';
    final userData = _object(container['userData']);
    final details = _object(container['details']);
    final name = _text(userData['username']) ?? _text(userData['name']) ?? '';
    final userRanking = _object(userData['userRanking']);
    final level = _int(userRanking['level']);
    switch (type) {
      case 'text':
        final body = _text(details['body']) ?? '';
        if (name.isNotEmpty && body.isNotEmpty) {
          messages.add(LiveMessage(
            type: LiveMessageType.chat,
            userName: name,
            userId: _text(userData['id']) ?? '',
            message: body,
            messageId: _id(container['id']),
            sentAt: _time(container['createdAt']),
            color: _color(userData),
            userLevel: level?.toString() ?? '',
            userLevelValue: level,
          ));
        }
      case 'tip':
        final amount = _int(details['amount']) ?? _int(container['amount']) ?? 0;
        messages.add(LiveMessage(
          type: LiveMessageType.gift,
          userName: name,
          userId: _text(userData['id']) ?? '',
          message: '$name 已支付 $amount 代币',
          data: LiveGift(
            name: '代币',
            count: amount,
            kind: LiveGiftKind.tip,
            unitPrice: 1,
            totalValue: amount,
          ),
          messageId: _id(container['id']),
          sentAt: _time(container['createdAt']),
          color: _color(userData),
          userLevel: level?.toString() ?? '',
          userLevelValue: level,
        ));
      case 'lovense':
        final lovense = _object(details['lovenseDetails']);
        final detail = _object(lovense['detail']);
        final clientInfo = _object(lovense['clientUserInfo']);
        final clientName = _text(clientInfo['username']) ?? _text(clientInfo['name']) ?? name;
        final power = _text(detail['power']) ?? 'low';
        final time = _int(detail['time']) ?? 0;
        final powerText = power == 'high' ? '高' : power == 'medium' ? '中' : '低';
        messages.add(LiveMessage(
          type: LiveMessageType.notice,
          userName: clientName,
          userId: _text(clientInfo['id']) ?? '',
          message: '$clientName: $powerText强度 · $time秒',
          messageId: _id(container['id']),
          sentAt: _time(container['createdAt']),
          color: _color(clientInfo),
          userLevel: level?.toString() ?? '',
          userLevelValue: level,
        ));
      default:
        break;
    }
    return messages;
  }

  static LiveMessageColor _color(Map<String, Object?> user) {
    final raw = _text(user['color']) ?? '';
    if (raw.isEmpty) return LiveMessageColor.white;
    final hex = raw.replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null || value < 0 || value > 0xFFFFFF) return LiveMessageColor.white;
    return LiveMessageColor.numberToColor(value);
  }

  static DateTime? _time(Object? value) => switch (value) {
    final int ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    final String s => DateTime.tryParse(s),
    _ => null,
  };

  static String? _text(Object? value) => value is String ? value : null;

  static int? _int(Object? value) => switch (value) {
        final int i => i,
        final String s => int.tryParse(s),
        _ => null,
      };

  static String _id(Object? value) => switch (value) {
        final int i => '$i',
        final String s => s,
        _ => '',
      };

  static Map<String, Object?> _object(Object? value) => value is Map<String, Object?> ? value : const {};
}

/// Stripchat's danmaku connection: WebSocket with connect+subscribe handshake.
final class StripchatDanmakuConnection extends DanmakuSocketConnection<StripchatDanmakuArgs> {
  new({super.proxy, super.connector})
      : super(policy: const DanmakuSocketPolicy(heartbeatInterval: StripchatDanmakuProtocol.heartbeatInterval), site: 'stripchat');

  String _token = '';
  int _modelId = 0;

  @override
  @protected
  Future<DanmakuSocketTarget> target(StripchatDanmakuArgs args, DanmakuRun run) async {
    _token = args.token;
    _modelId = args.modelId;
    return DanmakuSocketTarget(
      endpoints: [Uri.parse(args.websocketUrl)],
      headers: StripchatDanmakuProtocol.headersFor(args.apiHost),
    );
  }

  @override
  @protected
  void onOpen(DanmakuSocketSession session) {
    session
      ..send(StripchatDanmakuProtocol.connectFrame(_token))
      ..send(StripchatDanmakuProtocol.subscribeFrame(_modelId));
    session.ready();
  }

  @override
  @protected
  void onData(DanmakuSocketSession session, Object? data) {
    final result = StripchatDanmakuProtocol.read(data);
    if (result.respondEmpty) session.send('{}');
    final pingValue = result.pingValue;
    if (pingValue != null) session.send(StripchatDanmakuProtocol.pongFrame(pingValue));
    result.messages.forEach(session.message);
  }

  @override
  @protected
  Object? heartbeatFrame(DanmakuSocketSession session) => null;
}
