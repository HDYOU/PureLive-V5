import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_danmaku/src/connection_base.dart';
import 'package:live_danmaku/src/socket_connection.dart';
import 'package:meta/meta.dart';

/// What a danmaku connection needs to join one model's public chat.
@immutable
final class StripchatDanmakuArgs {
  const new({required this.websocketUrl, required this.token, required this.modelId});

  /// The WebSocket endpoint URL (e.g. `wss://websocket-v6.sc-apps.com/connection/websocket`).
  final String websocketUrl;

  /// Authentication token from `/api/front/v3/config/initial`.
  final String token;

  /// The model's numeric id.
  final int modelId;

  @override
  bool operator ==(Object other) =>
      other is StripchatDanmakuArgs && other.websocketUrl == websocketUrl && other.token == token && other.modelId == modelId;

  @override
  int get hashCode => Object.hash(websocketUrl, token, modelId);

  @override
  String toString() => 'StripchatDanmakuArgs($websocketUrl, model $modelId)';
}

/// Result of parsing one WebSocket frame.
@immutable
final class StripchatFrameResult {
  const StripchatFrameResult({required this.messages, required this.respondEmpty});
  final List<LiveMessage> messages;
  final bool respondEmpty;
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
  /// WebSocket handshake headers.
  static const Map<String, String> headers = {
    'origin': 'https://zh.virtualtaboo.live',
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
  static StripchatFrameResult read(Object? data) {
    final text = switch (data) {
      final String text => text,
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (text == null || text.length > 256 * 1024) return const StripchatFrameResult(messages: [], respondEmpty: false);
    if (text.trim() == '{}') return const StripchatFrameResult(messages: [], respondEmpty: true);
    final obj = _object(text);
    if (obj == null) return const StripchatFrameResult(messages: [], respondEmpty: false);
    if (obj.containsKey('ping')) return const StripchatFrameResult(messages: [], respondEmpty: false);
    return StripchatFrameResult(messages: _parsePush(obj), respondEmpty: false);
  }

  static List<LiveMessage> _parsePush(Map<String, Object?> obj) {
    final messages = <LiveMessage>[];
    final push = _object(obj['push']) ?? _object(obj['event']) ?? const <String, Object?>{};
    final pub = _object(push['pub']) ?? const <String, Object?>{};
    final data = _object(pub['data']) ?? pub;
    if (data.isEmpty) return const [];
    final type = _text(data['type']) ?? '';
    final userData = _object(data['userData']) ?? _object(data['user']) ?? const <String, Object?>{};
    final details = _object(data['details']) ?? const <String, Object?>{};
    final name = _text(userData['username']) ?? _text(userData['name']) ?? '';
    switch (type) {
      case 'text':
        final body = _text(details['body']) ?? '';
        if (name.isNotEmpty && body.isNotEmpty) {
          messages.add(LiveMessage(
            type: LiveMessageType.chat,
            userName: name,
            userId: _text(userData['id']) ?? '',
            message: body,
            messageId: _text(data['id']) ?? '',
            sentAt: _time(data['createdAt']),
            color: _color(userData),
          ));
        }
      case 'tip':
        final amount = _text(details['amount']) ?? _text(data['amount']) ?? '0';
        messages.add(LiveMessage(
          type: LiveMessageType.gift,
          userName: name,
          userId: _text(userData['id']) ?? '',
          message: '$name 已支付 $amount 代币',
          data: LiveGift(
            name: '代币',
            count: int.tryParse(amount) ?? 1,
            kind: LiveGiftKind.tip,
            unitPrice: 1,
            totalValue: int.tryParse(amount) ?? 1,
            unit: LiveGiftUnit.other,
          ),
          messageId: _text(data['id']) ?? '',
          sentAt: _time(data['createdAt']),
          color: _color(userData),
        ));
      case 'lovense':
        final lovense = _object(details['lovenseDetails']) ?? const <String, Object?>{};
        final detail = _object(lovense['detail']) ?? const <String, Object?>{};
        final clientInfo = _object(lovense['clientUserInfo']) ?? const <String, Object?>{};
        final clientName = _text(clientInfo['username']) ?? _text(clientInfo['name']) ?? name;
        final power = _text(detail['power']) ?? 'low';
        final time = _text(detail['time']) ?? '0';
        final powerText = power == 'high' ? '高' : power == 'medium' ? '中' : '低';
        messages.add(LiveMessage(
          type: LiveMessageType.notice,
          userName: clientName,
          userId: _text(clientInfo['id']) ?? '',
          message: '$clientName: $powerText强度 · $time秒',
          messageId: _text(data['id']) ?? '',
          sentAt: _time(data['createdAt']),
          color: _color(clientInfo),
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

  static Map<String, Object?> _object(Object? value) => value is Map<String, Object?> ? value : const {};
}

/// Stripchat's danmaku connection: WebSocket with connect+subscribe handshake.
final class StripchatDanmakuConnection extends DanmakuSocketConnection<StripchatDanmakuArgs> {
  String _token = '';
  int _modelId = 0;

  new({super.proxy, super.connector})
      : super(policy: const DanmakuSocketPolicy(heartbeatInterval: StripchatDanmakuProtocol.heartbeatInterval), site: 'stripchat');

  @override
  @protected
  Future<DanmakuSocketTarget> target(StripchatDanmakuArgs args, DanmakuRun run) async {
    _token = args.token;
    _modelId = args.modelId;
    return DanmakuSocketTarget(
      endpoints: [Uri.parse(args.websocketUrl)],
      headers: StripchatDanmakuProtocol.headers,
    );
  }

  @override
  @protected
  void onOpen(DanmakuSocketSession session) {
    session
      ..send(StripchatDanmakuProtocol.connectFrame(_token))
      ..send(StripchatDanmakuProtocol.subscribeFrame(_modelId));
  }

  @override
  @protected
  void onData(DanmakuSocketSession session, Object? data) {
    final result = StripchatDanmakuProtocol.read(data);
    if (result.respondEmpty) session.send('{}');
    final text = switch (data) {
      final String t => t,
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (text != null) {
      final obj = StripchatDanmakuProtocol._object(text);
      if (obj.containsKey('ping')) {
        final pingValue = obj['ping'];
        session.send(StripchatDanmakuProtocol.pongFrame(pingValue is String ? pingValue : ''));
      }
    }
    result.messages.forEach(session.message);
  }

  @override
  @protected
  Object? heartbeatFrame(DanmakuSocketSession session) => null;
}
