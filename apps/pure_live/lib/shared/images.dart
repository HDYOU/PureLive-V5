import 'package:flutter/foundation.dart';
import 'package:live_store/live_store.dart';

/// The request headers of a cover or avatar at [url] (3.x
/// `networkImageHeaders`): Bilibili's image hosts (`hdslb.com`) get a
/// desktop browser's User-Agent; the CDN front strips the Referer, so
/// only the direct download sends it.
Map<String, String>? networkImageHeaders(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host == 'hdslb.com' || host.endsWith('.hdslb.com')) return _bilibiliHeaders;
  return _browserHeaders;
}

const String _browserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/151.0.0.0 Safari/537.36';

const String _accept =
    'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,'
    '*/*;q=0.8,application/signed-exchange;v=b3;q=0.7';

const Map<String, String> _bilibiliHeaders = {'User-Agent': _browserAgent, 'Accept': _accept};

const Map<String, String> _browserHeaders = {'User-Agent': _browserAgent, 'Accept': _accept};

/// Bumped when the image cache is cleared (3.x `CacheController.imageCacheEpoch`):
/// the app passes it to `LiveUiConfig.imageCacheEpoch`, so covers and
/// avatars on screen are fetched again under a new cache key.
final ValueNotifier<int> imageCacheEpoch = ValueNotifier(0);

/// The available image CDN providers.
enum ImageCdnProvider {
  /// Load the image direct, no CDN rewrite.
  none,

  /// Baidu gimg front (3.x default).
  baidu,

  /// Sogou image CDN.
  sougou,

  /// wsrv.nl image CDN.
  wsrv,

  /// i2.wp.com image CDN.
  wp,
}

/// The provider id as stored in `Settings.imageCdnProxySites`.
extension ImageCdnProviderId on ImageCdnProvider {
  /// The id string.
  String get id => switch (this) {
    ImageCdnProvider.none => 'none',
    ImageCdnProvider.baidu => 'baidu',
    ImageCdnProvider.sougou => 'sougou',
    ImageCdnProvider.wsrv => 'wsrv',
    ImageCdnProvider.wp => 'wp',
  };

  /// Parses [id]; unknown ids fall back to baidu.
  static ImageCdnProvider fromId(String id) => switch (id) {
    'none' => ImageCdnProvider.none,
    'baidu' => ImageCdnProvider.baidu,
    'sougou' => ImageCdnProvider.sougou,
    'wsrv' => ImageCdnProvider.wsrv,
    'wp' => ImageCdnProvider.wp,
    _ => ImageCdnProvider.baidu,
  };
}

/// The display name of each CDN provider (Chinese, for the settings UI).
extension ImageCdnProviderName on ImageCdnProvider {
  /// The Chinese display name.
  String get name => switch (this) {
    ImageCdnProvider.none => '直连',
    ImageCdnProvider.baidu => '百度',
    ImageCdnProvider.sougou => '搜狗',
    ImageCdnProvider.wsrv => 'wsrv.nl',
    ImageCdnProvider.wp => 'i2.wp.com',
  };
}

/// Rewrites [url] through [provider].
/// [provider] is `none` to keep the original URL.
String applyImageCdnProvider(ImageCdnProvider provider, String url) {
  final encoded = Uri.encodeComponent(url);
  return switch (provider) {
    ImageCdnProvider.none => url,
    ImageCdnProvider.baidu =>
      'https://gimg0.baidu.com/gimg/src=$encoded&app=2001&n=0&g=0n&q=80&fmt=webp',
    ImageCdnProvider.sougou =>
      'https://img02.sogoucdn.com/v2/thumb/retype/ext/webp/q/80/crop/xy/ai/t/0/?appid=122&url=$encoded',
    ImageCdnProvider.wsrv =>
      'https://wsrv.nl/?url=$encoded&output=webp&q=80',
    ImageCdnProvider.wp =>
      'https://i2.wp.com/$url',
  };
}

/// The CDN front the image cache loads through when the app proxy is off
/// (3.x `networkImageProxy`): it fetches the image from [url] and answers
/// with a small webp. Read for each picture, so the switch and the
/// [Settings.imageCdnProxySites] apply to the next one; [site] is the
/// room's platform.
///
/// Per-site provider lookup:
/// 1. [Settings.imageCdnProxySites] (site → provider id);
/// 2. [Settings.imageCdnProxyExcludeList] (legacy: listed sites stay direct);
/// 3. default: baidu.
String imageCdnProxyUrl(SettingsStore settings, String url, {String? site}) {
  if (!settings.get(Settings.enableImageCdnProxy)) return url;
  final perSite = settings.get(Settings.imageCdnProxySites);
  if (site != null && site.isNotEmpty) {
    final providerId = perSite[site];
    if (providerId is String) {
      return applyImageCdnProvider(ImageCdnProviderId.fromId(providerId), url);
    }
  }
  // Legacy: the exclude list keeps a site direct even when the proxy is on.
  final excludes = settings.get(Settings.imageCdnProxyExcludeList);
  if (site != null && site.isNotEmpty && excludes.contains(site)) return url;
  return applyImageCdnProvider(ImageCdnProvider.baidu, url);
}
