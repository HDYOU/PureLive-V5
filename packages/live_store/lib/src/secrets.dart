import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:live_store/src/database.dart';

/// Encrypts secrets for this device: Android Keystore or Windows DPAPI,
/// provided by the app (M12). The key never leaves the platform, so the
/// interface seals and opens instead of handing out a key.
abstract interface class SecretCipher {
  /// [plain] encrypted; [ref] is bound to the result so a sealed value
  /// cannot be moved to another name.
  Future<Uint8List> seal(String ref, String plain);

  /// The plain text of [sealed]; throws when it cannot be opened (another
  /// device, a reinstall, a lost key).
  Future<String> open(String ref, Uint8List sealed);
}

/// Names of the stored secrets.
abstract final class SecretRefs {
  /// The cookie of platform [site] (3.x `<site>Cookie`).
  static String cookie(String site) => 'cookie/${site.trim().toLowerCase()}';

  /// Douyu's long-term passport key (3.x `douyuLtp0`).
  static const douyuLtp0 = 'cookie/douyu.ltp0';

  /// Douyu's passport device id (3.x `douyuDid`).
  static const douyuDid = 'cookie/douyu.did';

  /// The remembered sign-in [uid] of platform [site] (V01.2,
  /// `AccountRoster`).
  static String account(String site, int uid) => '${accountsOf(site)}$uid';

  /// The prefix of the remembered sign-ins of [site].
  static String accountsOf(String site) => '$accountPrefix${site.trim().toLowerCase()}/';

  /// The prefix of every remembered sign-in.
  static const accountPrefix = 'account/';

  /// The password of WebDAV server [name].
  static String webdav(String name) => 'webdav/$name';

  static const _cookiePrefix = 'cookie/';
}

final RegExp _controlCharacters = RegExp(r'[\u0000-\u001F\u007F]');

/// A cookie header as pasted or stored, with control characters removed and
/// trimmed (3.x `normalizeAccountCookie`).
String normalizeCookie(String value) => value.replaceAll(_controlCharacters, '').trim();

/// Cookies and passwords, sealed by a [SecretCipher] in the database (3.x
/// kept them in plain text in the settings box).
///
/// Everything is opened when the store loads, so [cookieFor] is synchronous
/// and the app can implement live_net's `CookieVault` with
/// `cookieFor: secrets.cookieFor, changes: secrets.cookieChanges`. A value
/// that cannot be opened is treated as signed out and listed in
/// [unreadable]; its sealed bytes stay until the name is written again.
final class SecretStore {
  new _(this._db, this._cipher, this._values, this.unreadable, this._sealed);

  /// How long [load] waits before opening a value again that the key store
  /// did not open: the platform's key store can answer late right after
  /// start, and one such failure used to be told as another device's value.
  static const retryDelays = [Duration(milliseconds: 150), Duration(milliseconds: 500)];

  /// Opens every stored secret with [cipher].
  static Future<SecretStore> load(StoreDatabase db, SecretCipher cipher) async {
    final values = <String, String>{};
    final unreadable = <String>{};
    final sealed = <String, String>{};
    final lost = <String, Uint8List>{};
    for (final row in await db.rows('SELECT ref, sealed FROM secrets')) {
      final ref = row.read<String>('ref');
      final bytes = row.read<Uint8List>('sealed');
      sealed[ref] = base64.encode(bytes);
      lost[ref] = bytes;
    }
    var attempt = 0;
    while (lost.isNotEmpty) {
      for (final ref in [...lost.keys]) {
        try {
          values[ref] = await cipher.open(ref, lost[ref]!);
          lost.remove(ref);
        } on Object {
          // Tried again below, then taken for another device's.
        }
      }
      if (lost.isEmpty) break;
      if (attempt == retryDelays.length) {
        unreadable.addAll(lost.keys);
        break;
      }
      await Future<void>.delayed(retryDelays[attempt++]);
    }
    return SecretStore._(db, cipher, values, unreadable, sealed);
  }

  final StoreDatabase _db;
  final SecretCipher _cipher;
  final Map<String, String> _values;
  final StreamController<String> _changes = StreamController.broadcast();

  // The sealed bytes last seen per name (base64), so [reload] opens only
  // what another process changed.
  final Map<String, String> _sealed;
  int _generation = 0;
  int _writing = 0;
  Future<void> _lastWrite = Future.value();

  /// Reads the secrets again (another process sharing the database wrote
  /// some: a second desktop window, docs/A-界面设计/A16-桌面界面/A16.1-桌面窗口 c14), opens the
  /// changed ones and reports them through [changes].
  Future<void> reload() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final generation = _generation;
      final rows = await _db.rows('SELECT ref, sealed FROM secrets');
      final stored = <String, Uint8List>{
        for (final row in rows) row.read<String>('ref'): row.read<Uint8List>('sealed'),
      };
      final opened = <String, String?>{};
      for (final MapEntry(key: ref, value: bytes) in stored.entries) {
        if (_sealed[ref] == base64.encode(bytes)) continue;
        opened[ref] = await _openWithRetry(ref, bytes);
      }
      if (_writing > 0 || generation != _generation) {
        // A write of ours overlapped the read: read again after it.
        await _lastWrite;
        continue;
      }
      final changed = <String>{};
      for (final ref in [..._sealed.keys]) {
        if (stored.containsKey(ref)) continue;
        _sealed.remove(ref);
        // An unreadable one that went away changed too (its notice goes).
        final wasUnreadable = unreadable.remove(ref);
        if (_values.remove(ref) != null || wasUnreadable) changed.add(ref);
      }
      for (final MapEntry(key: ref, :value) in opened.entries) {
        _sealed[ref] = base64.encode(stored[ref]!);
        final before = _values[ref];
        final bool flagChanged;
        if (value == null) {
          _values.remove(ref);
          flagChanged = unreadable.add(ref);
        } else {
          _values[ref] = value;
          flagChanged = unreadable.remove(ref);
        }
        if (before != _values[ref] || flagChanged) changed.add(ref);
      }
      changed.forEach(_changes.add);
      return;
    }
  }

  /// Names whose sealed value could not be opened.
  final Set<String> unreadable;

  /// Opens [bytes] as [ref], waiting [retryDelays] between tries; null when
  /// the key store keeps failing (then the value is another device's, or
  /// this device's key is gone).
  Future<String?> _openWithRetry(String ref, Uint8List bytes) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _cipher.open(ref, bytes);
      } on Object {
        if (attempt == retryDelays.length) return null;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  /// Tries again to open the values this device was said not to read, after
  /// the key store has had time (it can fail for a moment right after
  /// start, and one such failure used to be told as another device's value,
  /// the notice staying for the whole run). Values that open now come back
  /// and are reported through [changes], so their notice goes; true when
  /// any did.
  Future<bool> retryUnreadable() async {
    var opened = false;
    for (final ref in [...unreadable]) {
      final encoded = _sealed[ref];
      if (encoded == null) continue;
      try {
        _values[ref] = await _cipher.open(ref, base64.decode(encoded));
      } on Object {
        // Still not this device's to read.
        continue;
      }
      unreadable.remove(ref);
      _changes.add(ref);
      opened = true;
    }
    return opened;
  }

  /// The names of the secrets this device could open.
  Set<String> get refs => {..._values.keys};

  /// The secret [ref], or null.
  String? read(String ref) => _values[ref];

  /// The cookie header of [site], or null when signed out.
  String? cookieFor(String site) => _values[SecretRefs.cookie(site)];

  /// Platforms with a stored cookie.
  Set<String> get cookieSites => {
    for (final ref in _values.keys)
      if (ref.startsWith(SecretRefs._cookiePrefix) && !ref.contains('.'))
        ref.substring(SecretRefs._cookiePrefix.length),
  };

  /// Stores [value] under [ref]; null or empty removes it.
  Future<void> write(String ref, String? value) => writeAll({ref: value});

  /// Stores several secrets in one transaction.
  Future<void> writeAll(Map<String, String?> values) async {
    _generation++;
    _writing++;
    final future = _writeAll(values);
    _lastWrite = future.then((_) {}, onError: (Object _) {});
    try {
      await future;
    } finally {
      _writing--;
    }
  }

  Future<void> _writeAll(Map<String, String?> values) async {
    final sealed = <String, Uint8List?>{
      for (final entry in values.entries)
        entry.key: entry.value == null || entry.value!.isEmpty ? null : await _cipher.seal(entry.key, entry.value!),
    };
    await _db.write({StoreTables.secrets}, () async {
      for (final entry in sealed.entries) {
        if (entry.value case final bytes?) {
          await _db.run('INSERT OR REPLACE INTO secrets (ref, sealed) VALUES (?, ?)', [entry.key, bytes]);
        } else {
          await _db.run('DELETE FROM secrets WHERE ref = ?', [entry.key]);
        }
      }
    });
    for (final entry in sealed.entries) {
      if (entry.value case final bytes?) {
        _sealed[entry.key] = base64.encode(bytes);
      } else {
        _sealed.remove(entry.key);
      }
    }
    for (final entry in values.entries) {
      final value = entry.value;
      final before = _values[entry.key];
      if (value == null || value.isEmpty) {
        _values.remove(entry.key);
      } else {
        _values[entry.key] = value;
      }
      // Signing out of a cookie this device cannot read leaves the value
      // empty as it was; the change is the notice going away.
      final wasUnreadable = unreadable.remove(entry.key);
      if (before != _values[entry.key] || wasUnreadable) _changes.add(entry.key);
    }
  }

  /// Stores the cookie of [site], normalised; empty signs out.
  Future<void> setCookie(String site, String cookie) => write(SecretRefs.cookie(site), normalizeCookie(cookie));

  /// Removes every cookie (3.x `clearAllCookies`).
  Future<void> clearCookies() => writeAll({
    for (final ref in {..._values.keys, ...unreadable})
      if (ref.startsWith(SecretRefs._cookiePrefix)) ref: null,
  });

  /// Names of changed secrets.
  Stream<String> get changes => _changes.stream;

  /// Platforms whose cookie changed (for live_net's `CookieVault.changes`).
  Stream<String> get cookieChanges => changes
      .where((ref) => ref.startsWith(SecretRefs._cookiePrefix))
      .map((ref) => ref.substring(SecretRefs._cookiePrefix.length).split('.').first);

  /// Closes [changes].
  Future<void> close() => _changes.close();
}
