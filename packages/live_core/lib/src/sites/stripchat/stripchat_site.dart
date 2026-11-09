import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_core/src/sites/stripchat/stripchat_api.dart';
import 'package:live_net/live_net.dart';

const _site = 'stripchat';

/// The Stripchat adapter.
///
/// Anonymous and read-only. Stripchat's API is public, no cookie needed.
/// Room ids are model usernames (case-insensitive, as the platform matches
/// them). The catalog has one category with sort-area children. Lists come
/// from `/api/front/v2/models` (recommendations) or filtered by sort tag.
/// Search reads suggestion matches. Room entry asks the user ID, then the
/// cam detail and config (for CDN hosts and WebSocket), then downloads the
/// HLS master playlist.
///
/// The platform answers from several mirror domains ([StripchatApi.apiHosts]);
/// a first request races them all on the config endpoint and every API call
/// afterwards is pinned to the fastest host that answered.
final class StripchatSite extends LiveSite
    with LiveSiteLinks
    implements
        LiveSiteRoomRefresher,
        LiveSiteFollowBatchRefresher,
        LiveSiteRecordRoomResolver,
        LivePlayUrlResolver,
        LivePlayRecoveryResolver,
        LiveSiteDirectoryPager,
        LiveCancellableSearch {
  /// Creates the adapter; [hosts] are raced for the fastest, defaulting to
  /// [StripchatApi.apiHosts].
  new(this.http, [List<String>? hosts]) : _hosts = List.unmodifiable(hosts ?? StripchatApi.apiHosts);

  /// Transport.
  final LiveHttp http;

  /// API hosts raced on the first request.
  final List<String> _hosts;

  /// The host picked by the config race, shared by concurrent callers.
  Future<String>? _hostFuture;

  /// Cached config response (CDN hosts and WebSocket info).
  StripchatConfig? _cachedConfig;

  @override
  String get id => _site;

  @override
  String get name => 'Strip直播';

  // Requests ------------------------------------------------------------------

  Future<LiveResponse> _get(Uri url, {CancelToken? cancel}) async {
    try {
      return await http.send(LiveRequest(site: _site, url: url, headers: StripchatApi.headers, cancel: cancel));
    } on TransportFailure catch (failure) {
      if (failure.reason == TransportReason.cancelled) rethrow;
      throw NetworkFailure(_site, failure.toString());
    }
  }

  /// Build [path] against [host].
  Uri _api(String host, String path, [Map<String, String>? query]) => Uri.https(host, path, query);

  /// The API host in use, resolved by racing the config endpoint over
  /// [_hosts]; every later call reuses the winner. Concurrent callers share
  /// one race.
  Future<String> _host() => _hostFuture ??= _resolveHost();

  Future<String> _resolveHost() async {
    final winner = await raceFirst<({String host, StripchatConfig config})>(
      [for (final host in _hosts) StripchatApi.configUrl(host)],
      (url, cancel) async {
        final response = await _get(url, cancel: cancel);
        // A bad body fails this host's lane; another host may still answer.
        final config = StripchatApi.config(response.text, status: response.status);
        return (host: url.host, config: config);
      },
      timeout: const Duration(seconds: 20),
    );
    if (winner == null) throw const NetworkFailure(_site, 'no API host answered the config race');
    _cachedConfig = winner.config;
    return winner.host;
  }

  // Catalog -------------------------------------------------------------------

  @override
  Future<List<LiveCategory>> getCategories(int page, int pageSize) async {
    if (page != 1) return const [];
    return [StripchatApi.catalog()];
  }

  // Directory -----------------------------------------------------------------

  /// Sort areas: 'all', 'recommended', 'mobile', 'chinese', etc.
  /// Each entry contributes extra query parameters; `primaryTag` defaults to
  /// 'girls' and is overridden by couples/trans areas.
  static const Map<String, Map<String, String>> _sortQuery = {
    'all': {},
    'recommended': {'filterGroupTags': '[["recommended"]]'},
    'mobile': {'filterGroupTags': '[["mobile"]]'},
    'chinese': {'filterGroupTags': '[["tagLanguageChinese"]]'},
    'japanese': {'filterGroupTags': '[["tagLanguageJapanese"]]'},
    'korean': {'filterGroupTags': '[["tagLanguageKorean"]]'},
    'russian': {'filterGroupTags': '[["tagLanguageRussianSpeaking"]]'},
    'asmr': {'filterGroupTags': '[["asmr"]]'},
    'cosplay': {'filterGroupTags': '[["doCosplay"]]'},
    'couples': {'primaryTag': 'couples'},
    'trans': {'primaryTag': 'trans'},
    'teen': {'filterGroupTags': '[["ageTeen"]]'},
    'outdoor': {'filterGroupTags': '[["doPublicPlace"]]'},
    'new': {'filterGroupTags': '[["autoTagNew"]]'},
    'interactive': {'filterGroupTags': '[["autoTagInteractiveToy"]]'},
  };

  /// Page [page] of models sorted by [area].
  @override
  Future<LiveDirectoryPage> getDirectoryPage({int page = 1, LiveArea? category, CancelToken? cancel}) async {
    final number = page < 1 ? 1 : page;
    final sort = _areaSort(category);
    final extra = _sortQuery[sort] ?? const {};
    const limit = StripchatApi.pageSize;
    final offset = (number - 1) * limit;
    final host = await _host();
    final response = await _get(
      _api(host, '/api/front/models', {
        'limit': '$limit',
        'offset': '$offset',
        'primaryTag': extra['primaryTag'] ?? 'girls',
        'filterGroupTags': ?extra['filterGroupTags'],
      }),
      cancel: cancel,
    );
    final models = StripchatApi.modelsList(response.text, status: response.status);
    final rooms = <String, LiveRoom>{};
    for (final m in models) {
      final isLive = m.isLive && StripchatApi.isLiveStatus(m.status);
      rooms[m.username.toLowerCase()] = _card(m, isLive: isLive);
    }
    final hasMore = StripchatApi.hasRecommendedModels(response.text, status: response.status);
    return LiveDirectoryPage(rooms: rooms.values, page: number, hasMore: hasMore);
  }

  static String _areaSort(LiveArea? area) {
    if (area == null) return 'all';
    if (area.platform == _site && area.areaType == 'sort') return area.areaId;
    return 'all';
  }

  /// Live models by viewers (recommendations).
  @override
  Future<List<LiveRoom>> getRecommendRooms({int page = 1, int pageSize = 30}) async {
    final limit = pageSize.clamp(1, StripchatApi.pageSize);
    final offset = (page - 1) * limit;
    final host = await _host();
    final response = await _get(
      _api(host, '/api/front/models', {
        'limit': '$limit',
        'primaryTag': 'girls',
        'filterGroupTags': '[["tagLanguageChinese"]]',
        'offset': '$offset',
      }),
    );
    final models = StripchatApi.modelsList(response.text, status: response.status);
    return [
      for (final m in models)
        _card(m, isLive: m.isLive && StripchatApi.isLiveStatus(m.status)),
    ];
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(LiveArea category, {int page = 1, int pageSize = 30}) async {
    final result = await getDirectoryPage(page: page, category: category);
    return result.rooms.toList();
  }

  // Search --------------------------------------------------------------------

  @override
  Future<List<LiveRoom>> searchRooms(String keyword, {int page = 1, int pageSize = 30}) async =>
      searchRoomsCancellable(keyword, page: page, pageSize: pageSize);

  /// Search models matching [keyword], live and offline; [pageSize] is
  /// sent, limited to 1-60. A blank keyword gives nothing without a request.
  @override
  Future<List<LiveRoom>> searchRoomsCancellable(
    String keyword, {
    int page = 1,
    int pageSize = 30,
    CancelToken? cancel,
  }) async {
    final text = keyword.trim();
    if (text.isEmpty) return const [];
    final limit = pageSize.clamp(1, StripchatApi.pageSize);
    final offset = (page - 1) * limit;
    final host = await _host();
    final response = await _get(
      _api(host, '/api/front/v4/models/search/suggestion', {
        'query': text.length > StripchatApi.maxKeywordLength
            ? text.substring(0, StripchatApi.maxKeywordLength)
            : text,
        'primaryTag': 'girls',
        'limit': '$limit',
        'offset': '$offset',
      }),
      cancel: cancel,
    );
    final models = StripchatApi.searchModels(response.text, status: response.status);
    return [
      for (final m in models)
        _card(m, isLive: m.isLive && StripchatApi.isLiveStatus(m.status)),
    ];
  }

  // Rooms ---------------------------------------------------------------------

  /// Resolve [username] to its numeric id via `/api/front/users/user-ids/<username>`.
  Future<int> _resolveModelId(String username) async {
    final host = await _host();
    final response = await _get(_api(host, '/api/front/users/user-ids/$username'));
    if (response.status == 404) throw NotFound(_site, 'user-ids: no id for "$username"');
    final root = _checked(response.text, status: response.status, what: 'user-ids');
    final id = jsonInt(root['id']);
    if (id == null || id <= 0) throw NotFound(_site, 'user-ids: no id for "$username"');
    return id;
  }

  /// Get the cam detail (stream info and card fields).
  Future<StripchatCam> _getCam(int modelId) async {
    final host = await _host();
    final response = await _get(
      _api(host, '/api/front/v2/models/$modelId/cam', {
        'timezoneOffset': '-480',
        'triggerRequest': 'loadCam',
        'withRecentShow': '1',
      }),
    );
    return StripchatApi.camDetail(response.text, modelId: modelId, status: response.status);
  }

  /// Get the config (CDN hosts and WebSocket info). Resolved with the active
  /// host on the first call, cached after.
  Future<StripchatConfig> _getConfig() async {
    final cached = _cachedConfig;
    if (cached != null) return cached;
    await _host();
    return _cachedConfig!;
  }

  /// Liveness/latency probe of every CDN host in the config (via
  /// [StripchatApi.probed]): all `https://edge-hls.{host}/ping.m3u8` pings
  /// run in parallel with a 10 s timeout each, the surviving hosts carry
  /// their response times and the missed ones fall back to the common CDN
  /// list, so a stream line always survives even when every probe fails.
  Future<StripchatConfig> _probedConfig() async {
    final config = await _getConfig();
    final probed = await StripchatApi.probed(http, config);
    _cachedConfig = probed;
    return probed;
  }

  /// The room with its stream (when live).
  @override
  Future<LiveRoom> getRoomDetail({required String roomId}) async {
    final parsed = StripchatApi.parseRoomId(roomId);
    final username = parsed.username;
    if (!StripchatApi.isUsername(username)) throw NotFound(_site, 'room id "$username" is not a valid username');
    final modelId = parsed.userId ?? await _resolveModelId(username);
    final cam = await _getCam(modelId);
    final isLive = cam.isLive && StripchatApi.isLiveStatus(cam.status);
    LiveRoom room = _card(cam.toModel(), isLive: isLive);
    if (!isLive) return room;
    // Override introduction/notice from cam fields.
    room = room.copyWith(
      introduction: cam.introduction.isEmpty ? null : cam.introduction,
      notice: cam.notice.isEmpty ? null : cam.notice,
    );
    // Fetch member total when live.
    final host = await _host();
    final membersResponse = await _get(
      _api(host, '/api/front/v2/models/$modelId/members'),
    );
    final membersTotal = StripchatApi.membersCount(membersResponse.text, status: membersResponse.status);
    if (membersTotal > 0) {
      room = room.copyWith(totalViewers: '$membersTotal');
    }
    // Build the HLS master URIs: probe each edge-hls CDN in parallel
    // (`StripchatApi.probed`), keep the response times on the config, fall
    // back to the common CDN list for the misses, and order the quality
    // lines fastest-first (`StripchatApi.masterUris`).
    final probedConfig = await _probedConfig();
    final masters = StripchatApi.masterUris(cam.streamName, probedConfig);
    if (masters.isEmpty || cam.streamName.isEmpty) return room;
    // Fetch the primary master for initial quality listing.
    final master = masters.first;
    final response = await _get(master);
    final variants = StripchatApi.parseVariants(response.text, master: master, status: response.status);
    final qualities = StripchatApi.qualitiesFromVariants(variants, username: cam.username);
    return room.copyWith(
      data: StripchatRoomData(
        modelId: cam.modelId,
        username: cam.username,
        streamName: cam.streamName,
        master: master,
        masterUris: masters,
        isLive: true,
        qualities: qualities,
        variants: variants,
        apiHost: host,
      ),
      danmakuData: StripchatDanmakuArgs(
        websocketUrl: probedConfig.websocketUrl,
        token: probedConfig.websocketToken,
        modelId: cam.modelId,
        apiHost: host,
      ),
    );
  }

  /// Follow-card refresh: the cam card, no stream check.
  @override
  Future<LiveRoom> getRoomDetailForRefresh({required String roomId}) async {
    final parsed = StripchatApi.parseRoomId(roomId);
    final username = parsed.username;
    if (!StripchatApi.isUsername(username)) throw NotFound(_site, 'room id "$username" is not a valid username');
    final modelId = parsed.userId ?? await _resolveModelId(username);
    final cam = await _getCam(modelId);
    final isLive = cam.isLive && StripchatApi.isLiveStatus(cam.status);
    LiveRoom room = _card(cam.toModel(), isLive: isLive);
    if (cam.introduction.isNotEmpty) room = room.copyWith(introduction: cam.introduction);
    if (cam.notice.isNotEmpty) room = room.copyWith(notice: cam.notice);
    return room;
  }

  /// Batch follow-card refresh: every requested room's status in one
  /// `/api/front/guests/watch-history` call per batch of up to 60 ids, the
  /// batches run in parallel. Rooms the answer does not confirm are left for
  /// the caller to refresh individually.
  @override
  Future<Map<String, LiveRoom>> refreshFollowBatch(List<LiveRoom> rooms) async {
    final byId = <int, LiveRoom>{};
    for (final room in rooms) {
      final parsed = StripchatApi.parseRoomId(room.roomId);
      final id = parsed.userId ?? int.tryParse(room.userId ?? '');
      if (id != null && id > 0 && !byId.containsKey(id)) byId[id] = room;
    }
    if (byId.length < 2) return const {};
    final host = await _host();
    final batches = StripchatApi.watchHistoryBatches(byId.keys.toList());
    final confirmed = <String, LiveRoom>{};
    await Future.wait(
      batches.map(
        (ids) async {
          final response = await _get(StripchatApi.watchHistoryUrl(host, ids));
          for (final m in StripchatApi.modelsWatchHistory(response.text, status: response.status)) {
            final room = byId[m.modelId];
            if (room == null) continue;
            confirmed[room.identityKey] = _card(m, isLive: m.isLive && StripchatApi.isLiveStatus(m.status));
          }
        },
      ),
    );
    return confirmed;
  }

  /// Recording: detail with stream, same as room entry.
  @override
  Future<LiveRoom> getRoomDetailForRecording({required String roomId}) => getRoomDetail(roomId: roomId);

  /// Whether the room is live.
  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    final room = await getRoomDetailForRefresh(roomId: roomId);
    return room.isLiveNow;
  }

  // Streams -------------------------------------------------------------------

  @override
  Future<List<LivePlayQuality>> getPlayQualities({required LiveRoom detail}) async {
    final data = detail.data as StripchatRoomData?;
    if (data == null) throw const StreamUnavailable(_site, 'no stream data');
    return data.qualities;
  }

  @override
  Future<List<String>> getPlayUrls({required LiveRoom detail, required LivePlayQuality quality}) async =>
      (await resolvePlayUrlsRaw(detail: detail, quality: quality)).urls;

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsRaw({
    required LiveRoom detail,
    required LivePlayQuality quality,
  }) async {
    final data = detail.data as StripchatRoomData?;
    if (data == null) throw const StreamUnavailable(_site, 'no stream data');
    if (data.masterUris.isEmpty) throw const StreamUnavailable(_site, 'no master uri');
    // Fetch all CDN masters in parallel, collect variants per height.
    final allVariants = <int, List<StripchatVariant>>{};
    await Future.forEach(data.masterUris, (master) async {
      try {
        final r = await _get(master);
        final variants = StripchatApi.parseVariants(r.text, master: master, status: r.status);
        for (final v in variants) {
          allVariants.putIfAbsent(v.height, () => []).add(v);
        }
      } catch (_) {
        // Skip CDN that fails.
      }
    });
    // For the requested quality height, pick best variant per CDN URL.
    final height = int.tryParse('${quality.id}') ?? 0;
    if (height <= 0) throw StreamUnavailable(_site, 'invalid quality id $quality.id');
    final variants = allVariants[height];
    if (variants == null || variants.isEmpty) throw StreamUnavailable(_site, 'no url for quality $quality.id');
    final seen = <String>{};
    final lines = <LivePlayLine>[];
    for (var i = 0; i < variants.length; i++) {
      final url = variants[i].url;
      if (!seen.add(url)) continue;
      lines.add(
        LivePlayLine(
          url,
          headers: {
            'user-agent': StripchatApi.headers['user-agent']!,
            'origin': 'https://${data.apiHost}',
            'referer': 'https://${data.apiHost}/${data.username}/',
          },
          format: StreamFormat.hls,
          codec: variants[i].codec,
          lineId: '${data.streamName}-cdn$i',
        ),
      );
    }
    if (lines.isEmpty) throw StreamUnavailable(_site, 'no url for quality $quality.id');
    return LivePlayUrlResolution.lines(lines, appliedQualityData: quality.selectionId);
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecoveryRaw({
    required LiveRoom detail,
    required LivePlayQuality quality,
  }) =>
      resolvePlayUrlsRaw(detail: detail, quality: quality);

  // Helpers -------------------------------------------------------------------

  static LiveRoom _card(StripchatModel m, {required bool isLive}) => LiveRoom(
        roomId: '${m.username}?uid=${m.modelId}',
        userId: '${m.modelId}',
        platform: _site,
        title: m.title,
        nick: m.username,
        avatar: m.avatarUrl,
        cover: m.popularSnapshotTimestamp > 0
            ? StripchatApi.thumbnailUrl(m.popularSnapshotTimestamp, '${m.modelId}')
            : '',
        area: '',
        watching: '',
        totalViewers: m.viewersCount > 0 ? '${m.viewersCount}' : '',
        audienceMetricType: AudienceMetricType.totalViewers,
        liveStatus: isLive ? LiveStatus.live : LiveStatus.offline,
        startedAt: m.startedAt,
        introduction: m.description.isEmpty ? null : m.description,
        restriction: StripchatApi.restrictionFor(m.status),
        link: StripchatApi.roomPageUrl(m.username),
      );

  /// Resolves a URL to a room id.
  @override
  String? roomIdFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    if (!StripchatApi.isApiHost(uri.host)) return null;
    final segments = uri.path.split('/');
    if (segments.length < 2 || segments[1].isEmpty) return null;
    final id = segments[1];
    return StripchatApi.isUsername(id) ? id : null;
  }
}

Map<String, dynamic> _checked(String body, {required String what, int status = 200}) {
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
