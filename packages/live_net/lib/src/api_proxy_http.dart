import 'dart:async';

import 'package:live_net/src/live_http.dart';
import 'package:live_net/src/request.dart';
import 'package:live_net/src/response.dart';
import 'package:live_net/src/streamed_response.dart';

/// API proxy modes.
enum ApiProxyMode {
  /// 3.x moonchan-style forward proxy: the URL host is replaced and
  /// `proxy_host` / `proxy_referer` are added as query parameters.
  moonchan,

  /// Cloudflare Workers reverse proxy: the entire original URL is appended
  /// as a path segment on the proxy host.
  cloudflare,
}

/// A forward-proxy decorator for [LiveHttp]: when the request's [LiveRequest.site]
/// is in the configured sites and the proxy host is non-empty, rewrites the URL
/// according to the mode. Requests for sites not in the configured set pass
/// through unchanged.
///
/// [ApiProxyMode.moonchan]: `https://[host]:[port]/[originalPath]?proxy_host=...&proxy_referer=...`
///
/// [ApiProxyMode.cloudflare]: `https://[cfHost]:[cfPort]/[full-original-url]`
///
/// When [config] is provided it is called on every request so that changes
/// to the settings take effect without restarting. The static fields are used
/// as a fallback when [config] is null (e.g. in tests).
final class ApiProxyHttp implements LiveHttp {
  /// Creates the decorator over [inner]. Pass [config] to read proxy settings
  /// live on each request; otherwise the static [sites], [host], [port],
  /// [mode], [cfHost] and [cfPort] values are used.
  new(
    this.inner, {
    required this.sites,
    required this.host,
    required this.port,
    this.mode = ApiProxyMode.moonchan,
    this.cfHost = '',
    this.cfPort = 443,
    this.config,
  });

  /// The transport that does the actual work.
  final LiveHttp inner;

  /// Platform ids whose requests go through the forward proxy (static fallback).
  final Set<String> sites;

  /// Forward-proxy host (moonchan mode, e.g. `proxy.moonchan.xyz`).
  final String host;

  /// Forward-proxy port.
  final int port;

  /// The proxy mode (static fallback).
  final ApiProxyMode mode;

  /// Cloudflare Workers proxy host.
  final String cfHost;

  /// Cloudflare Workers proxy port.
  final int cfPort;

  /// Optional live-config getter called before each request. When present,
  /// its return value overrides the static fields for that request.
  final ApiProxyConfig? Function()? config;

  /// Whether [request]'s [LiveRequest.site] should be proxied.
  bool _proxied(LiveRequest request, ApiProxyConfig cfg) {
    if (cfg.sites.isEmpty) return false;
    if (!cfg.sites.contains(request.site)) return false;
    if (cfg.mode == ApiProxyMode.cloudflare) return cfg.cfHost.isNotEmpty;
    return cfg.host.isNotEmpty;
  }

  /// The proxied URL for [request] under [cfg].
  Uri _rewritten(LiveRequest request, ApiProxyConfig cfg) {
    final url = request.url;
    switch (cfg.mode) {
      case ApiProxyMode.moonchan:
        final originalHost = url.host;
        const scheme = 'https';
        final path = url.path.isEmpty ? '/' : url.path;
        var query = url.query;
        query += '${query.isEmpty ? '' : '&'}proxy_host=${Uri.encodeQueryComponent(originalHost)}';
        query += '&proxy_referer=${Uri.encodeQueryComponent('https://$originalHost/')}';
        return Uri(scheme: scheme, host: cfg.host, port: cfg.port, path: path, query: query);
      case ApiProxyMode.cloudflare:
        final originalUrl = url.toString();
        return Uri(scheme: 'https', host: cfg.cfHost, port: cfg.cfPort, path: '/$originalUrl');
    }
  }

  ApiProxyConfig _currentConfig() {
    final live = config?.call();
    if (live != null) return live;
    return ApiProxyConfig(sites: sites, host: host, port: port, mode: mode, cfHost: cfHost, cfPort: cfPort);
  }

  LiveRequest _maybeRewrite(LiveRequest request) {
    final cfg = _currentConfig();
    if (!_proxied(request, cfg)) return request;
    final newUrl = _rewritten(request, cfg);
    return LiveRequest(
      site: request.site,
      url: newUrl,
      method: request.method,
      headers: request.headers,
      body: request.body,
      followRedirects: request.followRedirects,
      timeout: request.timeout,
      cancel: request.cancel,
    );
  }

  @override
  Future<LiveResponse> send(LiveRequest request) => inner.send(_maybeRewrite(request));

  @override
  Future<LiveStreamedResponse> open(LiveRequest request) => inner.open(_maybeRewrite(request));

  @override
  void close() => inner.close();
}

/// Snapshot of the API proxy configuration used for a single request.
class ApiProxyConfig {
  /// Creates an immutable snapshot of the proxy settings for one request.
  const new({
    required this.sites,
    required this.host,
    required this.port,
    required this.mode,
    required this.cfHost,
    required this.cfPort,
  });

  /// Platform ids whose API requests go through the proxy.
  final Set<String> sites;

  /// Forward-proxy host (used in forward mode).
  final String host;

  /// Forward-proxy port.
  final int port;

  /// Which proxy scheme is active (forward or Cloudflare Workers).
  final ApiProxyMode mode;

  /// Cloudflare Workers host (used in Workers mode).
  final String cfHost;

  /// Cloudflare Workers port.
  final int cfPort;
}
