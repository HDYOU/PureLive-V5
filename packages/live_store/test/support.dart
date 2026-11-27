import 'dart:convert';
import 'dart:typed_data';

import 'package:live_store/live_store.dart';

/// A reversible test cipher bound to the secret's name; values sealed for
/// another device (`FakeCipher.foreign`) cannot be opened.
final class FakeCipher implements SecretCipher {
  /// Creates the cipher; [device] stands for the platform key.
  const new({this.device = 'k90'});

  /// A cipher of another device.
  const new foreign() : device = 'other';

  /// The device the key belongs to.
  final String device;

  @override
  Future<Uint8List> seal(String ref, String plain) async =>
      Uint8List.fromList(utf8.encode('$device|$ref|${base64.encode(utf8.encode(plain))}'));

  @override
  Future<String> open(String ref, Uint8List sealed) async {
    final parts = utf8.decode(sealed).split('|');
    if (parts.length != 3 || parts[0] != device || parts[1] != ref) throw const FormatException('cannot open');
    return utf8.decode(base64.decode(parts[2]));
  }
}

/// A device's cipher that fails [failures] `open`s before answering: the
/// platform's key store answering late right after start.
final class FlakyCipher implements SecretCipher {
  /// Creates the cipher; [failures] counts the `open`s that still throw.
  new({this.failures = 1});

  /// `open`s left to fail.
  int failures;

  /// Every `open` asked for.
  final List<String> opened = [];

  static const FakeCipher _device = FakeCipher();

  @override
  Future<Uint8List> seal(String ref, String plain) => _device.seal(ref, plain);

  @override
  Future<String> open(String ref, Uint8List sealed) async {
    opened.add(ref);
    if (failures > 0) {
      failures--;
      throw StateError('the key store is not answering yet');
    }
    return await _device.open(ref, sealed);
  }
}

/// A store in memory with [FakeCipher].
Future<LiveStore> memoryStore({DateTime Function()? now}) => LiveStore.memory(cipher: const FakeCipher(), now: now);

/// A room as 3.x wrote it in follows and history (LiveRoom.toJson at v3.2.11).
Map<String, Object?> v3Room(
  String platform,
  String roomId, {
  String nick = '',
  String title = '',
  String notice = '',
  int? lastWatchedAt,
}) => {
  'roomId': roomId,
  'userId': '',
  'title': title,
  'nick': nick,
  'avatar': '',
  'cover': '',
  'area': '',
  'watching': '0',
  'audienceMetricType': 'unknown',
  'popularity': '',
  'onlineViewers': '',
  'totalViewers': '',
  'followers': '0',
  'platform': platform,
  'tagIds': <String>[],
  'liveStatus': 1,
  'isRecord': false,
  'status': false,
  'notice': notice,
  'introduction': '',
  'lastWatchedAt': lastWatchedAt,
};
