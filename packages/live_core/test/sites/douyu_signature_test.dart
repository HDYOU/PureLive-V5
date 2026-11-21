import 'package:live_core/src/sites/douyu/douyu_signature.dart';
import 'package:test/test.dart';

/// Vectors lifted from biliup's `douyu_signature.rs` test. They pin the
/// S-box transform, the `amd` expansion and the `auth` header to the values
/// the Douyu android app produces.
void main() {
  test('android signature matches the reference vectors', () {
    final params = <String, String>{
      'txdw': '0',
      'cdn': 'hw',
      'dscnt': '0',
      'token': '',
      'rate': '0',
      'hevc': '0',
      'ilow': '0',
      'iar': '0',
      'net': 'WIFI',
      'device': 'PHK110',
    };
    const timestamp = 1790312470;
    const device = DouyuSignature.defaultDeviceId;

    final signature = DouyuSignature.csign(1126960, device, timestamp, params);
    expect(signature, '26660e9d8e79f3476e02b14d4c481353');

    final encrypted = DouyuSignature.amd(signature, device);
    expect(
      encrypted,
      'a76343b9f45e3a695db3c213b25dfbb9'
      'a76343b9f45e3a69a76343b9f45e3a69'
      'a76343b9f45e3a69a76343b9f45e3a69'
      '0a1f3a34734a7149f5bada1c778c0633'
      'f5bada1c778c0633f5bada1c778c0633'
      '5420cc761ed6e0cf',
    );

    final withSig = <String, String>{
      ...params,
      'csign': signature,
      'cptl': '0103',
      'amd': encrypted,
      'client_sys': 'android',
    };
    expect(
      DouyuSignature.headerAuth(
        '/lapi/live/appGetPlayer/stream/1126960',
        timestamp,
        'android1',
        withSig,
      ),
      'f38e7b58edb31472f7c79e43ee1a6969',
    );
  });

  /// `headerAuth` is the `auth` header for any Douyu android request: the
  /// canonical source is `path?k=v&...vq47Hd9JUgfDCytC` over the sorted
  /// params (the dropped set removed, `aid`/`client_sys`/`time` injected).
  /// The follow-room case pins the exact byte layout.
  test('follow room auth header signs the form fields', () {
    const rids = '4767111';
    const time = 1795238856;
    const params = <String, String>{'rids': rids, 'rsAvg': '540'};
    // MD5 of `Livenc/UserRelation/getFollowRoomListByRid?aid=android1`
    // `&client_sys=android&rids=4767111&rsAvg=540&time=1795238856vq47Hd9JUgfDCytC`.
    expect(DouyuSignature.headerAuth('/Livenc/UserRelation/getFollowRoomListByRid', time, 'android1', params), 'b60c2cc8188274a8fe2275dc838f1a3b');
  });
}
