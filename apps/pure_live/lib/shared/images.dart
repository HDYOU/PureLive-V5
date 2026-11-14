import 'package:flutter/foundation.dart';
import 'package:live_store/live_store.dart';

/// The request headers of a cover or avatar at [url] (3.x
/// `networkImageHeaders`): Bilibili's image hosts (`hdslb.com`) check the
/// Referer, so it is sent there only; every image is asked for with a
/// desktop browser's User-Agent.
Map<String, String>? networkImageHeaders(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host == 'hdslb.com' || host.endsWith('.hdslb.com')) return _bilibiliHeaders;
  return _browserHeaders;
}

const String _browserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/151.0.0.0 Safari/537.36';

const Map<String, String> _bilibiliHeaders = {'Referer': 'https://live.bilibili.com/', 'User-Agent': _browserAgent};

const Map<String, String> _browserHeaders = {'User-Agent': _browserAgent};

/// Bumped when the image cache is cleared (3.x `CacheController.imageCacheEpoch`):
/// the app passes it to `LiveUiConfig.imageCacheEpoch`, so covers and
/// avatars on screen are fetched again under a new cache key.
final ValueNotifier<int> imageCacheEpoch = ValueNotifier(0);

/// The CDN front the image cache loads through when the app proxy is off
/// (3.x `networkImageProxy`): it fetches the image from [url] and answers
/// with a small webp. Read for each picture, so the switch and the
/// [Settings.imageCdnProxyExcludeList] apply to the next one; [site] is the
/// room's platform, and excluded platforms keep their own host's address.
String imageCdnProxyUrl(SettingsStore settings, String url, {String? site}) {
  if (!settings.get(Settings.enableImageCdnProxy)) return url;
  final excludes = settings.get(Settings.imageCdnProxyExcludeList);
  if (site != null && site.isNotEmpty && excludes.contains(site)) return url;
  return 'https://gimg0.baidu.com/gimg/src=${Uri.encodeComponent(url)}&app=2001&n=0&g=0n&q=80&fmt=webp';
}
