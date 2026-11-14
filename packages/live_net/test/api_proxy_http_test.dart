import 'dart:convert';

import 'package:live_net/live_net.dart';
import 'package:test/test.dart';

/// Records the URL each [LiveRequest] was rewritten to.
final class _Recorder implements LiveHttp {
  final List<Uri> urls = [];
  @override
  Future<LiveResponse> send(LiveRequest request) async {
    urls.add(request.url);
    return LiveResponse(status: 200, bytes: const [], url: request.url);
  }

  @override
  Future<LiveStreamedResponse> open(LiveRequest request) async {
    urls.add(request.url);
    return LiveStreamedResponse(status: 200, body: const Stream<List<int>>.empty(), url: request.url);
  }

  @override
  void close() {}
}

void main() {
  const proxyHost = 'proxy.moonchan.xyz';
  const proxyPort = 443;
  const sites = {'bilibili', 'douyu'};

  test('a proxied site: URL host is replaced and proxy_host/proxy_referer are appended', () async {
    final recorder = _Recorder();
    final api = ApiProxyHttp(recorder, sites: sites, host: proxyHost, port: proxyPort);
    final request = LiveRequest(
      site: 'bilibili',
      url: Uri.parse('https://api.live.bilibili.com/live_user/v1/UserInfo'),
    );
    await api.send(request);
    expect(recorder.urls, hasLength(1));
    final url = recorder.urls.single;
    expect(url.host, proxyHost);
    expect(url.port, proxyPort);
    expect(url.scheme, 'https');
    expect(url.path, '/live_user/v1/UserInfo');
    final query = url.queryParameters;
    expect(query['proxy_host'], 'api.live.bilibili.com');
    expect(query['proxy_referer'], 'https://api.live.bilibili.com/');
  });

  test('an existing query string is preserved and proxy params are appended', () async {
    final recorder = _Recorder();
    final api = ApiProxyHttp(recorder, sites: sites, host: proxyHost, port: proxyPort);
    final request = LiveRequest(site: 'douyu', url: Uri.parse('https://api.douyu.com/beta/room/1?sign=abc123'));
    await api.send(request);
    final url = recorder.urls.single;
    expect(url.queryParameters['sign'], 'abc123');
    expect(url.queryParameters['proxy_host'], 'api.douyu.com');
    expect(url.queryParameters['proxy_referer'], 'https://api.douyu.com/');
  });

  test('a non-proxied site passes through unchanged', () async {
    final recorder = _Recorder();
    final api = ApiProxyHttp(recorder, sites: sites, host: proxyHost, port: proxyPort);
    final original = Uri.parse('https://api.twitch.tv/gql');
    final request = LiveRequest(site: 'twitch', url: original);
    await api.send(request);
    expect(recorder.urls.single, original);
  });

  test('an empty host means no proxying even if the site is listed', () async {
    final recorder = _Recorder();
    final api = ApiProxyHttp(recorder, sites: sites, host: '', port: proxyPort);
    final original = Uri.parse('https://api.live.bilibili.com/live_user/v1/UserInfo');
    await api.send(LiveRequest(site: 'bilibili', url: original));
    expect(recorder.urls.single, original);
  });

  test('method, headers, body and timeout are preserved on rewrite', () async {
    final recorder = _Recorder();
    final api = ApiProxyHttp(recorder, sites: sites, host: proxyHost, port: proxyPort);
    final cancel = CancelToken();
    await api.send(
      LiveRequest(
        site: 'douyu',
        url: Uri.parse('https://game.douyu.com/lapi/live/h5/room/1'),
        method: 'POST',
        headers: const {'content-type': 'application/json'},
        body: utf8.encode('{"room_id":1}'),
        followRedirects: false,
        timeout: const Duration(seconds: 5),
        cancel: cancel,
      ),
    );
    final url = recorder.urls.single;
    expect(url.host, proxyHost);
    expect(url.path, '/lapi/live/h5/room/1');
    expect(url.queryParameters['proxy_host'], 'game.douyu.com');
  });

  test('open() is also proxied', () async {
    final recorder = _Recorder();
    final api = ApiProxyHttp(recorder, sites: sites, host: proxyHost, port: proxyPort);
    await api.open(LiveRequest(site: 'bilibili', url: Uri.parse('https://api.bilibili.com/x/v2/dm')));
    expect(recorder.urls.single.host, proxyHost);
    expect(recorder.urls.single.queryParameters['proxy_host'], 'api.bilibili.com');
  });
}
