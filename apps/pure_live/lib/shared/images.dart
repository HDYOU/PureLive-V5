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

  /// Baidu gimg front.
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

  /// Parses [id]; unknown ids fall back to [ImageCdnProvider.none].
  static ImageCdnProvider fromId(String id) => switch (id) {
    'none' => ImageCdnProvider.none,
    'baidu' => ImageCdnProvider.baidu,
    'sougou' => ImageCdnProvider.sougou,
    'wsrv' => ImageCdnProvider.wsrv,
    'wp' => ImageCdnProvider.wp,
    _ => ImageCdnProvider.none,
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

/// Maps an image URL host to the platform id it belongs to, so the
/// per-site CDN config can be applied without an explicit site parameter.
/// Returns null for hosts not recognised.
String? siteFromImageUrlHost(String host) {
  final h = host.toLowerCase();
  if (h.contains('hdslb.com') || h.contains('bilibili.com')) return 'bilibili';
  if (h.contains('douyu.tv') || h.contains('douyucdn.cn')) return 'douyu';
  if (h.contains('huya.com') || h.contains('huajiao.com')) return 'huya';
  if (h.contains('snssdk.com') || h.contains('douyin.com')) return 'douyin';
  if (h.contains('kwai') || h.contains('kuaishou')) return 'kuaishou';
  if (h.contains('twitch.tv') || h.contains('ttvnw.net')) return 'twitch';
  if (h.contains('soop') || h.contains('afreeca')) return 'soop';
  if (h.contains('yy.com') || h.contains('duopa.com')) return 'yy';
  if (h.contains('acfun.cn')) return 'acfun';
  if (h.contains('picarto.tv')) return 'picarto';
  if (h.contains('twitcasting.tv')) return 'twitcasting';
  if (h.contains('missevan')) return 'missevan';
  if (h.contains('inke')) return 'inke';
  if (h.contains('kila')) return 'kilakila';
  if (h.contains('xiaohongshu') || h.contains('xhscdn')) return 'xiaohongshu';
  if (h.contains('niconico') || h.contains('nicosee')) return 'niconico';
  if (h.contains('weibo') || h.contains('sinaimg')) return 'weibo';
  if (h.contains('showroom-live.com')) return 'showroom';
  if (h.contains('chzzk')) return 'chzzk';
  if (h.contains('kick.com')) return 'kick';
  if (h.contains('liveme') || h.contains('bigolive')) return 'liveMe';
  if (h.contains('tiktok') || h.contains('muscdn')) return 'tiktok';
  if (h.contains('youtube') || h.contains('ytimg')) return 'youtube';
  if (h.contains('bigo') || h.contains('livecdn')) return 'bigo';
  if (h.contains('pandalive') || h.contains('panda')) return 'pandaLive';
  if (h.contains('fc2') || h.contains('fc2live')) return 'fc2Live';
  if (h.contains('steam')) return 'steamBroadcast';
  if (h.contains('jd') || h.contains('jdlive')) return 'jdLive';
  if (h.contains('kugou')) return 'kugouLive';
  if (h.contains('baidu') || h.contains('bytedance')) return 'baiduLive';
  if (h.contains('sixroom')) return 'sixRoom';
  if (h.contains('looklive')) return 'lookLive';
  if (h.contains('seventeen')) return 'seventeenLive';
  return null;
}

/// Rewrites [url] through [provider].
/// [provider] is `none` to keep the original URL.
String applyImageCdnProvider(ImageCdnProvider provider, String url) {
  final encoded = Uri.encodeComponent(url);
  final hostPath = url.startsWith('https://') ? url.substring(8) : url.startsWith('http://') ? url.substring(7) : url;
  return switch (provider) {
    ImageCdnProvider.none => url,
    ImageCdnProvider.baidu =>
      'https://gimg0.baidu.com/gimg/src=$encoded&app=2001&n=0&g=0n&q=80&fmt=webp',
    ImageCdnProvider.sougou =>
      'https://img02.sogoucdn.com/v2/thumb/retype/ext/webp/q/80/crop/xy/ai/t/0/?appid=122&url=$encoded',
    ImageCdnProvider.wsrv =>
      'https://wsrv.nl/?url=$encoded&output=webp&q=80',
    ImageCdnProvider.wp =>
      'https://i2.wp.com/$hostPath',
  };
}

/// The CDN interceptor for image downloads. Reads [Settings.imageCdnProxySites]
/// and applies the configured provider per image URL. When the proxy switch
/// is off or no provider is configured for the detected site, the URL is
/// returned unchanged.
String imageCdnProxyUrl(SettingsStore settings, String url, {String? site}) {
  if (!settings.get(Settings.enableImageCdnProxy)) return url;
  final perSite = settings.get(Settings.imageCdnProxySites);
  // Determine the site: explicit [site] parameter, or inferred from the URL host.
  final effectiveSite = site ?? siteFromImageUrlHost(Uri.tryParse(url)?.host ?? '');
  if (effectiveSite != null && effectiveSite.isNotEmpty) {
    final providerId = perSite[effectiveSite];
    if (providerId is String) {
      return applyImageCdnProvider(ImageCdnProviderId.fromId(providerId), url);
    }
  }
  // Default: direct (no rewrite).
  return url;
}
