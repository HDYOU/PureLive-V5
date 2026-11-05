import 'dart:async';
import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_danmaku/src/connection.dart';
import 'package:live_danmaku/src/connection_base.dart';
import 'package:live_danmaku/src/socket_connection.dart';
import 'package:meta/meta.dart';

/// What a danmaku connection needs to join one model's public chat.
@immutable
final class StripchatDanmakuArgs {
  /// Creates the arguments.
  const new({required this.websocketUrl, required this.token, required this.modelId});

  /// The WebSocket endpoint URL.
  final String websocketUrl;

  /// Authentication token.
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

/// Stripchat's public chat over WebSocket (anonymous, no auth beyond token).
///
/// The socket connects to [args.websocketUrl] with the [token] as a query
/// parameter. Frames are JSON text; chat messages carry `type: "chat"` with
/// the sender's name in `user.name` and the text in `message`.
abstract final class StripchatDanmakuProtocol {
  /// WebSocket handshake headers.
  static const Map<String, String> headers = {
    'origin': 'https://zh.virtualtaboo.live',
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
  };

  /// Heartbeat period (30 s).
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// The client ping frame.
  static const String ping = '{"type":"ping"}';

  /// The WebSocket endpoint URL for [args].
  static Uri endpoint(StripchatDanmakuArgs args) => Uri.parse(args.websocketUrl).replace(query: 'token=${Uri.encodeQueryComponent(args.token)}');

  /// Reads one text frame; returns parsed messages.
  static List<LiveMessage> read(Object? data, StripchatDanmakuArgs args) {
    final text = switch (data) {
      final String text => text,
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (text == null || text.length > 256 * 1024) return const [];
    final obj = _object(text);
    if (obj == null) return const [];
    return _parseMessage(obj, args);
  }

  static List<LiveMessage> _parseMessage(Map<String, Object?> obj, StripchatDanmakuArgs args) {
    final messages = <LiveMessage>[];
    // Handle array of messages
    if (obj['messages'] case final List<Object?> list) {
      for (final item in list) {
        if (item is Map<String, Object?>) messages.addAll(_parseMessage(item, args));
      }
      return messages;
    }
    // Single message
    final type = _text(obj['type']) ?? _text(obj['event']) ?? '';
    switch (type) {
      case 'chat' || 'message' || 'chat_message':
        final msg = _chatMessage(obj, args);
        if (msg != null) messages.add(msg);
        break;
      case 'ping' || 'pong':
        break; // Heartbeat, ignore
      case 'subscribe' || 'subscribed':
        break; // Join confirmation, ignore
      default:
        break;
    }
    return messages;
  }

  static LiveMessage? _chatMessage(Map<String, Object?> obj, StripchatDanmakuArgs args) {
    final user = _object(obj['user']) ?? _object(obj['sender']) ?? {};
    final name = _text(user['name']) ?? _text(obj['username']) ?? '';
    final content = _content(obj['message']) ?? _content(obj['text']) ?? '';
    if (name.isEmpty || content.isEmpty) return null;
    return LiveMessage(
      type: LiveMessageType.chat,
      userName: name,
      userId: _text(user['id']) ?? '',
      message: content,
      messageId: _text(obj['id']) ?? _text(obj['msgId']) ?? '',
      sentAt: _time(obj['timestamp']) ?? _time(obj['createdAt']),
      color: _color(obj),
    );
  }

  static LiveMessageColor _color(Map<String, Object?> obj) {
    final raw = _text(obj['color']) ?? _text(obj['user']?['color']) ?? '';
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

  static String? _content(Object? value) {
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    if (value is Map) {
      final text = _text(value['text']) ?? _text(value['content']) ?? '';
      return text.trim().isEmpty ? null : text.trim();
    }
    return null;
  }

  static Map<String, dynamic>? _object(Object? value) => value is Map<String, dynamic> ? value : null;
}

/// Stripchat's danmaku connection: a raw WebSocket of JSON text frames.
final class StripchatDanmakuConnection extends DanmakuSocketConnection<StripchatDanmakuArgs> {
  /// Creates the connection; [proxy] routes the socket.
  new({required super.proxy, super.connector})
      : super(policy: const DanmakuSocketPolicy(heartbeatInterval: StripchatDanmakuProtocol.heartbeatInterval));

  @override
  Uri endpoint(StripchatDanmakuArgs args) => StripchatDanmakuProtocol.endpoint(args);

  @override
  Map<String, String> headers(StripchatDanmakuArgs args) => StripchatDanmakuProtocol.headers;

  @override
  String? heartbeat(StripchatDanmakuArgs args) => StripchatDanmakuProtocol.ping;

  @override
  List<LiveMessage> readFrame(Object? data, StripchatDanmakuArgs args) =>
      StripchatDanmakuProtocol.read(data, args);
}
