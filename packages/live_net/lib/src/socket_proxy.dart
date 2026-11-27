import 'package:live_net/src/proxy.dart';
import 'package:live_net/src/socket.dart';

/// Configuration for the danmaku socket proxy, read live on each connect.
class SocketProxyConfig {
  /// Creates an immutable snapshot of the socket proxy settings.
  const new({required this.sites, required this.cfHost, required this.port});

  /// Platform ids whose sockets go through the Cloudflare proxy.
  final Set<String> sites;

  /// Cloudflare Workers host (e.g. `proxy.hyou.kdns.fr`).
  final String cfHost;

  /// Port of the Cloudflare Workers host.
  final int port;

  /// Whether [site]'s socket should be proxied.
  bool enabledFor(String site) => cfHost.isNotEmpty && sites.contains(site);
}

/// Wraps [inner] with a [SocketConnector] that rewrites the endpoint URL for
/// the Cloudflare Workers proxy before delegating.
///
/// [site] is the platform id this connector serves; when the live [config]
/// has that site enabled, the original `wss://host/path` endpoint is
/// rewritten to `wss://cfHost:port/wss://host/path`.
SocketConnector socketProxyConnector(
  SocketConnector inner, {
  required String site,
  required SocketProxyConfig Function() config,
}) {
  return (
    Uri endpoint, {
    required Map<String, String> headers,
    required Iterable<String>? protocols,
    required ProxyRoute route,
    required Duration connectTimeout,
  }) {
    final cfg = config();
    if (!cfg.enabledFor(site)) {
      return inner(endpoint, headers: headers, protocols: protocols, route: route, connectTimeout: connectTimeout);
    }
    // Rewrite: wss://cfHost:port/<original full URL>
    final originalUrl = endpoint.toString();
    final proxied = Uri(scheme: 'wss', host: cfg.cfHost, port: cfg.port, path: '/$originalUrl');
    return inner(proxied, headers: headers, protocols: protocols, route: route, connectTimeout: connectTimeout);
  };
}
