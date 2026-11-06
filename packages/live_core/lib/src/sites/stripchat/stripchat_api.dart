import 'dart:convert';

import 'package:live_core/src/json.dart';
import 'package:live_core/src/live_area.dart';
import 'package:live_core/src/live_room.dart';
import 'package:live_core/src/site_error.dart';
import 'package:meta/meta.dart';

const _site = 'stripchat';
const _web = 'https://zh.virtualtaboo.live';

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

/// A model's live stream data from the cam endpoint.
@immutable
final class StripchatRoomData {
  /// Creates the data.
  new({
    required this.modelId,
    required this.username,
    required this.streamName,
    required this.master,
    required this.isLive,
    required List<LivePlayQuality> qualities,
  }) : qualities = List.unmodifiable(qualities);

  /// The model's numeric id.
  final int modelId;

  /// The model's username (as the platform spells it).
  final String username;

  /// The stream name used in the HLS path.
  final String streamName;

  /// The HLS master playlist URI.
  final Uri master;

  /// Whether the model is currently live.
  final bool isLive;

  /// Qualities of [master], best first.
  final List<LivePlayQuality> qualities;
}

/// A model card from the models list endpoint.
@immutable
final class StripchatModel {
  /// Creates the card.
  const new({
    required this.username,
    required this.modelId,
    required this.isLive,
    required this.status,
    required this.viewersCount,
    required this.avatarUrl,
    required this.popularSnapshotTimestamp,
    required this.startedAt,
    required this.title,
    required this.description,
  });

  /// The model's username, the room id.
  final String username;

  /// The model's numeric id.
  final int modelId;

  /// Whether the model is currently live.
  final bool isLive;

  /// The model's status: 'public', 'private' or 'groupShow'.
  final String status;

  /// Total viewers of the current session.
  final int viewersCount;

  /// Avatar URL.
  final String avatarUrl;

  /// Timestamp for the popular snapshot thumbnail.
  final int popularSnapshotTimestamp;

  /// Broadcast start time, null when unknown or offline.
  final DateTime? startedAt;

  /// Room title from `groupShowTopic` (recommend/directory) or `topic`.
  final String title;

  /// User description.
  final String description;
}

/// A model cam detail from the cam endpoint.
@immutable
final class StripchatCam {
  /// Creates the cam data.
  const new({
    required this.modelId,
    required this.username,
    required this.streamName,
    required this.hlsLines,
    required this.pixelatedResolutions,
    required this.isLive,
    required this.status,
    required this.viewersCount,
    required this.avatarUrl,
    required this.popularSnapshotTimestamp,
    required this.startedAt,
    required this.title,
    required this.description,
    required this.introduction,
    required this.notice,
  });

  /// The model's numeric id.
  final int modelId;

  /// The model's username.
  final String username;

  /// The stream name for HLS playback.
  final String streamName;

  /// HLS line URLs, best first.
  final List<String> hlsLines;

  /// Pixelated (low-quality) resolution tags.
  final List<String> pixelatedResolutions;

  /// Whether the model is currently live.
  final bool isLive;

  /// The model's status: 'public', 'private' or 'groupShow'.
  final String status;

  /// Total viewers reported by the user block.
  final int viewersCount;

  /// Avatar URL.
  final String avatarUrl;

  /// Timestamp for the popular snapshot thumbnail.
  final int popularSnapshotTimestamp;

  /// Broadcast start time from `statusChangedAt`, null when unknown.
  final DateTime? startedAt;

  /// Room title from `topic`.
  final String title;

  /// User description.
  final String description;

  /// Room introduction from `cam.userFanClub.description`.
  final String introduction;

  /// Room notice/announcement from `cam.goal.description`.
  final String notice;

  /// The card fields, taken from the same `user` block.
  StripchatModel toModel() => StripchatModel(
        username: username,
        modelId: modelId,
        isLive: isLive,
        status: status,
        viewersCount: viewersCount,
        avatarUrl: avatarUrl,
        popularSnapshotTimestamp: popularSnapshotTimestamp,
        startedAt: startedAt,
        title: title,
        description: description,
      );
}

/// Config from `/api/front/v3/config/initial`: CDN hosts and WebSocket info.
@immutable
final class StripchatConfig {
  /// Creates the config.
  const new({
    required this.hlsStreamHosts,
    required this.websocketUrl,
    required this.websocketToken,
  });

  /// CDN hosts keyed by letter (A, B, C, …).
  final Map<String, String> hlsStreamHosts;

  /// WebSocket URL for danmaku.
  final String websocketUrl;

  /// WebSocket authentication token.
  final String websocketToken;
}

/// Pure parsing of Stripchat responses.
abstract final class StripchatApi {
  /// Desktop Chrome UA.
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/138.0.0.0 Safari/537.36';

  /// Web origin.
  static const String origin = _web;

  /// Host of the API.
  static const String apiHost = 'zh.virtualtaboo.live';

  /// Headers of every API request.
  static const Map<String, String> headers = {
    'user-agent': userAgent,
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'origin': _web,
    'referer': '$_web/',
  };

  /// Page size for model listings.
  static const int pageSize = 60;

  /// Longest search keyword.
  static const int maxKeywordLength = 50;

  /// Largest answer accepted (2 MiB).
  static const int responseLimit = 2 * 1024 * 1024;

  /// Model username pattern: letters, digits, underscore, 1-30 chars.
  static final RegExp _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{1,30}$');

  /// Site paths that are never models.
  static const Set<String> reservedNames = {
    'webcam',
    'girls',
    'couples',
    'trans',
    'search',
    'login',
    'signup',
    'premium',
    'token',
    'tips',
    'shop',
  };

  /// Whether [name] is a valid model username.
  static bool isUsername(String name) => _usernamePattern.hasMatch(name) && !reservedNames.contains(name.toLowerCase());

  /// Whether [status] represents a room that is currently on air.
  static bool isLiveStatus(String status) =>
      status == 'public' || status == 'groupShow';

  /// Map [status] to the corresponding restriction.
  static LiveRestriction restrictionFor(String status) => switch (status) {
        'private' => LiveRestriction.private,
        'groupShow' => LiveRestriction.paid,
        _ => LiveRestriction.none,
      };

  /// Parse [value] as a broadcast start time. Accepts an epoch-seconds int or
  /// an ISO-8601 string such as '2026-11-06T11:28:39Z'.
  static DateTime? _parseStartedAt(Object? value) {
    if (value == null) return null;
    if (value is int && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    }
    if (value is String && value.isNotEmpty) {
      final dt = DateTime.tryParse(value)?.toUtc();
      return dt;
    }
    return null;
  }

  /// The model page URL.
  static String roomPageUrl(String username) => '$_web/$username';

  // Helpers -------------------------------------------------------------------

  static Map<String, dynamic> _root(String body, {required String what, int status = 200}) {
    if (status < 200 || status >= 300) throw const ApiChanged(_site, '');
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, dynamic>) throw ApiChanged(_site, '$what: not a JSON object');
    return decoded;
  }

  static Map<String, dynamic>? _object(Object? value) => value is Map<String, dynamic> ? value : null;

  static List<Object?> _list(Object? value) => value is List ? value.cast<Object?>() : const [];

  static String _snippet(String body) {
    final text = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  // Config --------------------------------------------------------------------

  /// `/api/front/v3/config/initial`: CDN hosts and WebSocket configuration.
  static StripchatConfig config(String body, {int status = 200}) {
    final root = _root(body, what: 'config', status: status);
    final initial = _object(root['initial']) ?? {};
    final common = _object(initial['common']) ?? {};
    final client = _object(initial['client']) ?? {};
    final hostsRaw = _object(common['hlsStreamHosts']) ?? {};
    final hlsStreamHosts = <String, String>{};
    for (final MapEntry(:key, :value) in hostsRaw.entries) {
      if (value is String && value.isNotEmpty) hlsStreamHosts[key] = value;
    }
    final wsClient = _object(client['websocket']) ?? {};
    final websocketUrl = jsonString(wsClient['url']) ?? '';
    final websocketToken = jsonString(wsClient['token']) ?? '';
    return StripchatConfig(
      hlsStreamHosts: hlsStreamHosts,
      websocketUrl: websocketUrl,
      websocketToken: websocketToken,
    );
  }

  // Catalog -------------------------------------------------------------------

  /// The single category "Stripchat" with its areas (sort orders).
  static LiveCategory catalog() => LiveCategory(
        id: _site,
        name: 'Stripchat',
        children: [
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'all', areaName: '全部直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'recommended', areaName: '直播推荐'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'mobile', areaName: '竖屏直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'chinese', areaName: '中文直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'japanese', areaName: '日本直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'korean', areaName: '韩国直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'russian', areaName: '俄罗斯直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'asmr', areaName: 'ASMR直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'cosplay', areaName: 'COS直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'couples', areaName: '情侣直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'trans', areaName: '变性直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'teen', areaName: '青少年直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'outdoor', areaName: '户外直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'new', areaName: '新人直播'),
          LiveArea(platform: _site, areaType: 'sort', typeName: '全部直播', areaId: 'interactive', areaName: '互动玩具'),
        ],
      );

  // Directory -----------------------------------------------------------------

  /// `/api/front/models`: live model cards by viewers, one per page.
  static List<StripchatModel> modelsList(String body, {int status = 200}) {
    final root = _root(body, what: 'models', status: status);
    final rows = _list(root['models']);
    if (rows.isEmpty) return const [];
    final models = <String, StripchatModel>{};
    for (final raw in rows) {
      final m = _object(raw);
      if (m == null) continue;
      final username = jsonString(m['username'])?.trim();
      if (username == null || username.isEmpty || !isUsername(username)) continue;
      final id = jsonInt(m['id']);
      if (id == null || id <= 0) continue;
      final isLive = m['isLive'] == true;
      final statusStr = jsonString(m['status']) ?? 'public';
      final viewers = jsonInt(m['viewersCount']) ?? 0;
      final avatar = normalizeImageUrl(m['avatarUrl'] ?? '');
      final snapshotTs = jsonInt(m['popularSnapshotTimestamp']) ?? 0;
      final startedAt = _parseStartedAt(m['statusChangedAt'] ?? m['startTime']);
      final title = (jsonString(m['groupShowTopic']) ?? '').isNotEmpty
          ? jsonString(m['groupShowTopic'])!
          : (jsonString(m['topic']) ?? '');
      final description = decodeHtmlEntities(jsonString(m['description']) ?? '');
      models[username.toLowerCase()] = StripchatModel(
        username: username,
        modelId: id,
        isLive: isLive,
        status: statusStr,
        viewersCount: viewers,
        avatarUrl: avatar,
        popularSnapshotTimestamp: snapshotTs,
        startedAt: startedAt,
        title: title,
        description: description,
      );
    }
    return List.unmodifiable(models.values);
  }

  /// A single model card from the models endpoint.
  static StripchatModel modelCard(String body, {int status = 200}) {
    final root = _root(body, what: 'model-card', status: status);
    final row = _object(root['model']);
    if (row == null) throw ApiChanged(_site, 'model-card: no model (${_snippet(body)})');
    final username = jsonString(row['username'])?.trim();
    if (username == null || username.isEmpty || !isUsername(username)) {
      throw ApiChanged(_site, 'model-card: invalid username (${_snippet(body)})');
    }
    final id = jsonInt(row['id']);
    if (id == null || id <= 0) throw ApiChanged(_site, 'model-card: no id (${_snippet(body)})');
    final isLive = row['isLive'] == true;
    final statusStr = jsonString(row['status']) ?? 'public';
    final viewers = jsonInt(row['viewersCount']) ?? 0;
    final avatar = normalizeImageUrl(row['avatarUrl'] ?? '');
    final snapshotTs = jsonInt(row['popularSnapshotTimestamp']) ?? 0;
    final startedAt = _parseStartedAt(row['statusChangedAt'] ?? row['startTime']);
    final title = (jsonString(row['groupShowTopic']) ?? '').isNotEmpty
        ? jsonString(row['groupShowTopic'])!
        : (jsonString(row['topic']) ?? '');
    final description = decodeHtmlEntities(jsonString(row['description']) ?? '');
    return StripchatModel(
      username: username,
      modelId: id,
      isLive: isLive,
      status: statusStr,
      viewersCount: viewers,
      avatarUrl: avatar,
      popularSnapshotTimestamp: snapshotTs,
      startedAt: startedAt,
      title: title,
      description: description,
    );
  }

  // Cam detail ----------------------------------------------------------------

  /// `/api/front/v2/models/{uid}/cam`: the model's stream data.
  static StripchatCam camDetail(String body, {required int modelId, int status = 200}) {
    final root = _root(body, what: 'cam', status: status);
    final user = _object(root['user']) ?? {};
    final cam = _object(root['cam']) ?? {};
    final uid = jsonInt(user['id']);
    if (uid != modelId) throw ApiChanged(_site, 'cam: model id mismatch (${_snippet(body)})');
    final username = jsonString(user['username'])?.trim() ?? '';
    if (username.isEmpty) throw ApiChanged(_site, 'cam: no username (${_snippet(body)})');
    final isLive = user['status'] == 'public' || user['status'] == 'groupShow' || (root['user']?['isLive'] == true);
    final statusStr = jsonString(user['status']) ?? 'offline';
    final viewers = jsonInt(user['viewersCount']) ?? 0;
    final avatar = normalizeImageUrl(user['avatarUrl'] ?? '');
    final snapshotTs = jsonInt(user['snapshotTimestamp']) ?? jsonInt(user['popularSnapshotTimestamp']) ?? 0;
    final startedAt = _parseStartedAt(user['statusChangedAt']);
    final title = (jsonString(cam['topic']) ?? '').isNotEmpty
        ? jsonString(cam['topic'])!
        : (jsonString(user['topic']) ?? '');
    final description = decodeHtmlEntities(jsonString(user['description']) ?? '');
    final userFanClub = _object(cam['userFanClub']) ?? _object(user['userFanClub']) ?? {};
    final introduction = decodeHtmlEntities(jsonString(userFanClub['description']) ?? '');
    final goal = _object(cam['goal']) ?? {};
    final notice = decodeHtmlEntities(jsonString(goal['description']) ?? '');
    final streamName = jsonString(cam['streamName']) ?? '';
    final hlsLines = [
      for (final raw in _list(cam['hlsLines']))
        if (_object(raw)?['url'] case final url?)
          if (jsonString(url) case final u? when u.isNotEmpty) u,
    ];
    final pixelated = [
      for (final raw in _list(cam['pixelatedResolutions']))
        if (raw is String && raw.isNotEmpty) raw,
    ];
    return StripchatCam(
      modelId: uid!,
      username: username,
      streamName: streamName,
      hlsLines: hlsLines,
      pixelatedResolutions: pixelated,
      isLive: isLive,
      status: statusStr,
      viewersCount: viewers,
      avatarUrl: avatar,
      popularSnapshotTimestamp: snapshotTs,
      startedAt: startedAt,
      title: title,
      description: description,
      introduction: introduction,
      notice: notice,
    );
  }

  // Search --------------------------------------------------------------------

  /// `/api/front/v4/models/search/suggestion`: matching models.
  /// The response is a JSON array of models (not wrapped in an object).
  static List<StripchatModel> searchModels(String body, {int status = 200}) {
    if (status < 200 || status >= 300) throw ApiChanged(_site, 'search: HTTP $status');
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    final rows = decoded is List ? decoded : (decoded is Map ? _list(decoded) : const <dynamic>[]);
    if (rows.isEmpty) return const [];
    final models = <String, StripchatModel>{};
    for (final raw in rows) {
      final m = _object(raw);
      if (m == null) continue;
      final username = jsonString(m['username'])?.trim();
      if (username == null || username.isEmpty || !isUsername(username)) continue;
      final id = jsonInt(m['id']);
      if (id == null || id <= 0) continue;
      final isLive = m['isLive'] == true;
      final statusStr = jsonString(m['status']) ?? 'public';
      final viewers = jsonInt(m['viewersCount']) ?? 0;
      final avatar = normalizeImageUrl(m['avatarUrl'] ?? '');
      final snapshotTs = jsonInt(m['popularSnapshotTimestamp']) ?? 0;
      final startedAt = _parseStartedAt(m['statusChangedAt'] ?? m['startTime']);
      final title = (jsonString(m['topic']) ?? '').isNotEmpty
          ? jsonString(m['topic'])!
          : (jsonString(m['groupShowTopic']) ?? '');
      final description = decodeHtmlEntities(jsonString(m['description']) ?? '');
      models[username.toLowerCase()] = StripchatModel(
        username: username,
        modelId: id,
        isLive: isLive,
        status: statusStr,
        viewersCount: viewers,
        avatarUrl: avatar,
        popularSnapshotTimestamp: snapshotTs,
        startedAt: startedAt,
        title: title,
        description: description,
      );
    }
    return List.unmodifiable(models.values);
  }

  // Members -------------------------------------------------------------------

  /// `/api/front/v2/models/{uid}/members`: summed member counts.
  /// Returns 0 when the response cannot be parsed.
  static int membersCount(String body, {int status = 200}) {
    if (status < 200 || status >= 300) return 0;
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return 0;
    }
    if (decoded is! Map<String, dynamic>) return 0;
    int sum = 0;
    for (final key in ['guests', 'spies', 'invisibles', 'greens', 'golds', 'regulars']) {
      sum += jsonInt(decoded[key]) ?? 0;
    }
    return sum;
  }

  // Streams -------------------------------------------------------------------

  /// Parse an HLS master playlist into qualities.
  static List<LivePlayQuality> qualities(String body, {required Uri master, int status = 200}) {
    if (status == 404) throw const StreamUnavailable(_site, 'master playlist: HTTP 404');
    if (status < 200 || status >= 300) throw ApiChanged(_site, 'master: HTTP $status');
    if (body.trimLeft().split('\n').first.trim() != '#EXTM3U') {
      throw ApiChanged(_site, 'master: not a playlist (${_snippet(body)})');
    }
    final grouped = <String, ({String label, int height, int bandwidth, Set<String> urls})>{};
    Map<String, String>? pending;
    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        if (pending != null) throw const ApiChanged(_site, 'master: variant without attributes');
        pending = {
          for (final match in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(line.substring(18)))
            match.group(1)!: match.group(2)!.replaceAll('"', ''),
        };
        continue;
      }
      if (line.isEmpty || line.startsWith('#')) continue;
      if (pending == null) continue;
      final attrs = pending;
      pending = null;
      final bandwidth = jsonInt(attrs['BANDWIDTH']) ?? 0;
      final resolution = attrs['RESOLUTION'] ?? '';
      final heightMatch = RegExp(r'x(\d+)').firstMatch(resolution);
      final height = heightMatch == null ? 0 : int.parse(heightMatch.group(1)!);
      if (bandwidth <= 0 || height <= 0) continue;
      final label = '${height}p${bandwidth >= 5000000 ? ' 5Mbps' : bandwidth >= 2000000 ? ' 2Mbps' : ''}';
      grouped['$height-$bandwidth'] = (
        label: label,
        height: height,
        bandwidth: bandwidth,
        urls: {master.resolve(line).toString()},
      );
    }
    if (grouped.isEmpty) throw const ApiChanged(_site, 'master: no valid variant');
    return [
      for (final entry in grouped.entries.toList()..sort((a, b) => b.value.height.compareTo(a.value.height)))
        LivePlayQuality(
          quality: entry.value.label.trim(),
          id: '${entry.value.height}p${entry.value.bandwidth ~/ 1000}',
          data: entry.key,
          sort: entry.value.height * 10000 + entry.value.bandwidth,
        ),
    ];
  }

  /// Build the primary HLS master URI from a stream name and CDN host.
  static Uri masterUri(String streamName, String cdnHost) =>
      Uri.parse('https://edge-hls.$cdnHost/hls/$streamName/master/${streamName}_auto.m3u8?playlistType=lowLatency&preferredVideoCodec=av1&psch=v2&pkey=bXorqTB5ZhP5FcpX');

  /// Build all CDN HLS master URIs from stream name and config hosts,
  /// ordered by host key (A, B, C, …).
  static List<Uri> masterUris(String streamName, Map<String, String> hlsStreamHosts) {
    final ordered = <String>[];
    for (final key in hlsStreamHosts.keys.toList()..sort()) {
      ordered.add(key);
    }
    return [
      for (final key in ordered)
        if (hlsStreamHosts[key] case final host? when host.isNotEmpty)
          masterUri(streamName, host),
    ];
  }

  /// Thumbnail URL for a model.
  static String thumbnailUrl(int snapshotTimestamp, String modelId) =>
      'https://img.doppiocdn.live/thumbs/$snapshotTimestamp/${modelId}_webp';

  /// Avatar URL for a model.
  static String avatarUrl(String raw) => normalizeImageUrl(raw);
}
