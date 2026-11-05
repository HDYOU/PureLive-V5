import 'dart:async';
import 'dart:convert';

import 'package:live_core/live_core.dart';
import 'package:live_core/src/json.dart';
import 'package:live_core/src/links.dart';
import 'package:live_core/src/live_area.dart';
import 'package:live_core/src/live_room.dart';
import 'package:live_core/src/live_site.dart';

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
/// cam detail, then downloads the HLS master playlist.
final class StripchatSite extends LiveSite
    with LiveSiteLinks
    implements
        LiveSiteRoomRefresher,
        LiveSiteRecordRoomResolver,
        LivePlayUrlResolver,
        LivePlayRecoveryResolver,
        LiveSiteDirectoryPager,
        LiveCancellableSearch {
  /// Creates the adapter.
  new(this.http);

  /// Transport.
  final LiveHttp http;

  @override
  String get id => _site;

  @override
  String get name => 'Stripchat';

  // Requests ------------------------------------------------------------------

  Future<LiveResponse> _get(Uri url, {CancelToken? cancel}) async {
    try {
      return await http.send(LiveRequest(site: _site, url: url, headers: StripchatApi.headers, cancel: cancel));
    } on TransportFailure catch (failure) {
      if (failure.reason == TransportReason.cancelled) rethrow;
      throw NetworkFailure(_site, failure.toString());
    }
  }

  // Catalog -------------------------------------------------------------------

  @override
  Future<List<LiveCategory>> getCategories(int page, int pageSize) async {
    if (page != 1) return const [];
    return [StripchatApi.catalog()];
  }

  // Directory -----------------------------------------------------------------

  /// Sort areas: 'all', 'recommended', 'mobile', 'chinese', etc.
  static const Map<String, String> _sortQuery = {
    'all': '',
    'recommended': 'filterGroupTags=%5B%5B%22recommended%22%5D%5D',
    'mobile': 'filterGroupTags=%5B%5B%22mobile%22%5D%5D',
    'chinese': 'filterGroupTags=%5B%5B%22tagLanguageChinese%22%5D%5D',
    'japanese': 'filterGroupTags=%5B%5B%22tagLanguageJapanese%22%5D%5D',
    'korean': 'filterGroupTags=%5B%5B%22tagLanguageKorean%22%5D%5D',
    'russian': 'filterGroupTags=%5B%5B%22tagLanguageRussianSpeaking%22%5D%5D',
    'asmr': 'filterGroupTags=%5B%5B%22asmr%22%5D%5D',
    'cosplay': 'filterGroupTags=%5B%5B%22doCosplay%22%5D%5D',
    'couples': 'primaryTag=couples',
    'trans': 'primaryTag=trans',
    'teen': 'filterGroupTags=%5B%5B%22ageTeen%22%5D%5D',
    'outdoor': 'filterGroupTags=%5B%5B%22doPublicPlace%22%5D%5D',
    'new': 'filterGroupTags=%5B%5B%22autoTagNew%22%5D%5D',
    'interactive': 'filterGroupTags=%5B%5B%22autoTagInteractiveToy%22%5D%5D',
  };

  /// Page [page] of models sorted by [area].
  @override
  Future<LiveDirectoryPage> getDirectoryPage({int page = 1, LiveArea? category, CancelToken? cancel}) async {
    final number = page < 1 ? 1 : page;
    final sort = _areaSort(category);
    final query = _sortQuery[sort] ?? '';
    final response = await _get(
      Uri.https(StripchatApi.apiHost, '/api/front/v2/models', {
        'limit': '${StripchatApi.pageSize}',
        if (query.isNotEmpty) 'query': query,
      }),
      cancel: cancel,
    );
    final models = StripchatApi.modelsList(response.text, status: response.status);
    final rooms = <String, LiveRoom>{};
    for (final m in models) {
      if (!m.isLive || m.status != 'public') continue;
      rooms[m.username.toLowerCase()] = _card(m, isLive: true);
    }
    return LiveDirectoryPage(rooms: rooms.values, page: number, hasMore: models.length == StripchatApi.pageSize);
  }

  static String _areaSort(LiveArea? area) {
    if (area == null) return 'all';
    if (area.platform == _site && area.areaType == 'sort') return area.areaId;
    return 'all';
  }

  /// Live models by viewers (recommendations).
  @override
  Future<List<LiveRoom>> getRecommendRooms({int page = 1, int pageSize = 30}) async {

    final response = await _get(
      Uri.https(StripchatApi.apiHost, '/api/front/v2/models', {
        'limit': '${(pageSize.clamp(1, StripchatApi.pageSize))}',
      }),
    );
    final models = StripchatApi.modelsList(response.text, status: response.status);
    return [
      for (final m in models)
        if (m.isLive && m.status == 'public') _card(m, isLive: true),
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
    final response = await _get(
      Uri.https(StripchatApi.apiHost, '/api/front/v4/models/search/suggestion', {
        'query': text.length > StripchatApi.maxKeywordLength
            ? text.substring(0, StripchatApi.maxKeywordLength)
            : text,
        'primaryTag': 'girls',
      }),
      cancel: cancel,
    );
    final models = StripchatApi.searchModels(response.text, status: response.status);
    return [
      for (final m in models)
        if (m.isLive && m.status == 'public') _card(m, isLive: true),
    ];
  }

  // Rooms ---------------------------------------------------------------------

  /// Resolve [username] to its numeric id via `/api/front/users/user-ids/<username>`.
  Future<int> _resolveModelId(String username) async {
    final response = await _get(Uri.https(StripchatApi.apiHost, '/api/front/users/user-ids/$username'));
    if (response.status == 404) throw NotFound(_site, 'user-ids: no id for "$username"');
    final root = _checked(response.text, status: response.status, what: 'user-ids');
    final id = jsonInt(root['id']);
    if (id == null || id <= 0) throw NotFound(_site, 'user-ids: no id for "$username"');
    return id;
  }

  /// Get the model card (basic info).
  Future<StripchatModel> _getModelCard(int modelId) async {
    final response = await _get(Uri.https(StripchatApi.apiHost, '/api/front/v2/models/$modelId'));
    return StripchatApi.modelCard(response.text, status: response.status);
  }

  /// Get the cam detail (stream info).
  Future<StripchatCam> _getCam(int modelId) async {
    final response = await _get(
      Uri.https(StripchatApi.apiHost, '/api/front/v2/models/$modelId/cam', {
        'timezoneOffset': '-480',
        'triggerRequest': 'loadCam',
        'withRecentShow': '1',
      }),
    );
    return StripchatApi.camDetail(response.text, modelId: modelId, status: response.status);
  }

  /// The room with its stream (when live).
  @override
  Future<LiveRoom> getRoomDetail({required String roomId}) async {
    final username = roomId.trim();
    if (!StripchatApi.isUsername(username)) throw NotFound(_site, 'room id "$username" is not a valid username');
    final modelId = await _resolveModelId(username);
    final card = await _getModelCard(modelId);
    final cam = await _getCam(modelId);
    final isLive = cam.isLive && cam.status == 'public';
    LiveRoom room = _card(card, isLive: isLive);
    if (!isLive) return room;
    final master = cam.hlsLines.isNotEmpty ? StripchatApi.masterUri(cam.streamName) : null;
    if (master == null) return room.copyWith(restriction: LiveRestriction.unplayable);
    final response = await _get(master);
    final qualities = StripchatApi.qualities(response.text, master: master, status: response.status);
    return room.copyWith(
      data: StripchatRoomData(
        modelId: cam.modelId,
        username: cam.username,
        streamName: cam.streamName,
        master: master,
        isLive: true,
        qualities: qualities,
      ),
    );
  }

  /// Follow-card refresh: the card only, no stream check.
  @override
  Future<LiveRoom> getRoomDetailForRefresh({required String roomId}) async {
    final username = roomId.trim();
    if (!StripchatApi.isUsername(username)) throw NotFound(_site, 'room id "$username" is not a valid username');
    final modelId = await _resolveModelId(username);
    final card = await _getModelCard(modelId);
    return _card(card, isLive: card.isLive && card.status == 'public');
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
    return LivePlayUrlResolution.lines(
      [
        LivePlayLine(
          data.master.toString(),
          headers: {
            'user-agent': StripchatApi.headers['user-agent']!,
            'origin': StripchatApi.origin,
            'referer': '${StripchatApi.roomPageUrl(data.username)}/',
          },
          format: StreamFormat.hls,
          codec: 'avc',
          lineId: data.streamName,
        ),
      ],
      appliedQualityData: quality.data,
    );
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecoveryRaw({
    required LiveRoom detail,
    required LivePlayQuality quality,
  }) async =>
      resolvePlayUrlsRaw(detail: detail, quality: quality);

  // Helpers -------------------------------------------------------------------

  static LiveRoom _card(StripchatModel m, {required bool isLive}) => LiveRoom(
        roomId: m.username,
        platform: _site,
        title: m.username,
        nick: m.username,
        avatar: m.avatarUrl,
        cover: m.popularSnapshotTimestamp > 0
            ? StripchatApi.thumbnailUrl(m.popularSnapshotTimestamp, m.username)
            : '',
        area: '',
        watching: m.viewersCount > 0 ? '${m.viewersCount}' : '',
        popularity: '${m.viewersCount}',
        totalViewers: '',
        audienceMetricType: AudienceMetricType.popularity,
        liveStatus: isLive ? LiveStatus.live : LiveStatus.offline,
        startedAt: isLive && m.startTime > 0
            ? DateTime.fromMillisecondsSinceEpoch(m.startTime * 1000, isUtc: true)
            : null,
         introduction: m.description.isEmpty ? null : m.description,
         restriction: m.status == 'private' ? LiveRestriction.private : LiveRestriction.none,
         link: StripchatApi.roomPageUrl(m.username),
       );

  /// Resolves a URL to a room id.
  @override
  String? roomIdFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host != 'stripchat.com' && !host.endsWith('.stripchat.com')) return null;
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
