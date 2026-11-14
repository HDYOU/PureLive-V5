import 'dart:async';

import 'package:live_net/src/live_http.dart';
import 'package:live_net/src/request.dart';
import 'package:live_net/src/response.dart';
import 'package:live_net/src/streamed_response.dart';

/// A forward-proxy decorator for [LiveHttp]: when the request's [LiveRequest.site]
/// is in [sites] and [host] is non-empty, rewrites the URL to
/// `https://[host]:[port]/[originalPath]` and appends `proxy_host` and
/// `proxy_referer` query parameters so the proxy server knows where to fetch
/// from.  Requests for sites not in [sites] pass through unchanged.
///
/// 3.x's `HttpClient.proxyUrl` (lib/core/common/http_client.dart:266) did
/// the same for its dio client:
///
/// ```dart
/// var siteKey = findSiteKeyByStackTrace();
/// if (isProxyUrl(siteKey)) {
///   var parse = Uri.parse(url);
///   var host = parse.host;
///   var replaceUrl = url.replaceFirst(host, "proxy.moonchan.xyz");
///   queryParameters["proxy_host"] = host;
///   queryParameters["proxy_referer"] = "https://$host/";
/// }
/// ```
final class ApiProxyHttp implements LiveHttp {
  /// Creates the decorator over [inner].
  new(this.inner, {required this.sites, required this.host, required this.port});

  /// The transport that does the actual work.
  final LiveHttp inner;

  /// Platform ids whose requests go through the forward proxy (read from
  /// settings; an empty list means no proxying).
  final Set<String> sites;

  /// Forward-proxy host (e.g. `proxy.moonchan.xyz`).
  final String host;

  /// Forward-proxy port.
  final int port;

  /// Whether [request]'s [LiveRequest.site] should be proxied.
  bool _proxied(LiveRequest request) => host.isNotEmpty && sites.contains(request.site);

  /// The forward-proxy URL for [request], with `proxy_host` and
  /// `proxy_referer` appended to its query string.
  Uri _rewritten(LiveRequest request) {
    final url = request.url;
    final originalHost = url.host;
    const scheme = 'https';
    final path = url.path.isEmpty ? '/' : url.path;
    var query = url.query;
    query += '${query.isEmpty ? '' : '&'}proxy_host=${Uri.encodeQueryComponent(originalHost)}';
    query += '&proxy_referer=${Uri.encodeQueryComponent('https://$originalHost/')}';
    return Uri(scheme: scheme, host: host, port: port, path: path, query: query);
  }

  LiveRequest _maybeRewrite(LiveRequest request) {
    if (!_proxied(request)) return request;
    final newUrl = _rewritten(request);
    // Preserve the original method, headers, body and cancel token; only
    // the URL changes.
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
