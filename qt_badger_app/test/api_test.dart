import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qt_badger/src/api/badge_api.dart';

BadgeApi _api(MockClientHandler handler, {String key = ''}) => BadgeApi(host: '192.168.157.74', key: key, client: MockClient(handler));

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  test('addTask posts the text and returns the updated list', () async {
    late http.Request seen;
    final api = _api((req) async {
      seen = req;
      return _json({
        'ok': true,
        'tasks': [
          {'index': 0, 'text': 'Meet Alex', 'done': false},
        ],
      });
    });
    final tasks = await api.addTask('Meet Alex');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'http://192.168.157.74:7000/api/tasks');
    expect(jsonDecode(seen.body), {'text': 'Meet Alex'});
    expect(tasks.single.text, 'Meet Alex');
  });

  test('setSettings sends only the fields that were given', () async {
    late Map<String, dynamic> body;
    final api = _api((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return _json({'backlight': 200});
    });
    await api.setSettings(backlight: 200);
    expect(body, {'backlight': 200});
    await api.setSettings(haptic: false, peerRangeM: 10);
    expect(body, {'haptic': false, 'peer_range_m': 10});
  });

  test('nav sends an action or a screen', () async {
    late Map<String, dynamic> body;
    final api = _api((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return _json({'ok': true});
    });
    await api.nav(action: 'right');
    expect(body, {'action': 'right'});
    await api.nav(screen: 'tasks');
    expect(body, {'screen': 'tasks'});
  });

  test('setProfile: keepQr omits it, null removes it, a map sets it', () async {
    late Map<String, dynamic> body;
    final api = _api((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return _json({'name': 'Ama', 'title': '', 'org': '', 'has_qr': false, 'qr_size': 0});
    });
    await api.setProfile(name: 'Ama');
    expect(body.containsKey('qr'), isFalse);
    await api.setProfile(name: 'Ama', qr: null);
    expect(body.containsKey('qr'), isTrue);
    expect(body['qr'], isNull);
    await api.setProfile(name: 'Ama', qr: {'n': 21, 'hex': 'ff'});
    expect(body['qr'], {'n': 21, 'hex': 'ff'});
  });

  test('sends the access key header only when a key is set', () async {
    final headers = <Map<String, String>>[];
    final open = _api((req) async {
      headers.add(req.headers);
      return _json({'ok': true, 'app': 'QT BADGEr'});
    });
    await open.health();
    final locked = _api((req) async {
      headers.add(req.headers);
      return _json({'ok': true, 'app': 'QT BADGEr'});
    }, key: 's3cret');
    await locked.health();
    expect(headers[0].containsKey('X-Badge-Key'), isFalse);
    expect(headers[1]['X-Badge-Key'], 's3cret');
  });

  test('events(after) asks for the right window and parses the batch', () async {
    late Uri url;
    final api = _api((req) async {
      url = req.url;
      return _json({
        'latest': 12,
        'events': [
          {'seq': 11, 't': 1790195982, 'type': 'voice', 'text': 'hello'},
          {'seq': 12, 't': 1790195983, 'type': 'link', 'mcu': true},
        ],
      });
    });
    final batch = await api.events(10);
    expect(url.queryParameters['after'], '10');
    expect(batch.latest, 12);
    expect(batch.events.map((e) => e.type), ['voice', 'link']);
    expect(batch.events.first.text, 'hello');
  });

  test('a 400 from the hub becomes its own readable message', () async {
    final api = _api((req) async => _json({'detail': "the badge's task list is full (8 max) - clear some first"}, 400));
    expect(api.addTask('x'), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('full'))));
  });

  test('401 is reported as unauthorized', () async {
    final api = _api((req) async => _json({'detail': 'missing or wrong access key'}, 401));
    expect(api.status(), throwsA(isA<ApiException>().having((e) => e.unauthorized, 'unauthorized', isTrue)));
  });

  test('503 means the hub is up but the badge is down', () async {
    final api = _api((req) async => _json({'detail': 'badge not answering', 'mcu': false}, 503));
    expect(api.alert(), throwsA(isA<ApiException>().having((e) => e.badgeDown, 'badgeDown', isTrue)));
  });

  test('network failure and non-JSON replies give helpful errors', () async {
    final down = _api((req) async => throw http.ClientException('Connection refused'));
    expect(down.status(), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("Can't reach the hub"))));
    final notHub = _api((req) async => http.Response('<html>router login</html>', 200));
    expect(notHub.status(), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('not JSON'))));
  });

  test('a slow hub times out instead of hanging the UI', () async {
    final api = _api((req) => Completer<http.Response>().future);
    expect(
      api.health(timeout: const Duration(milliseconds: 50)),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("didn't answer"))),
    );
  });
}
