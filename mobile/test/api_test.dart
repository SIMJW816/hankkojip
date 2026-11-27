import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hankkojip/api.dart';

void main() {
  test('서버 주소 검증', () {
    for (final address in [
      'file:///tmp',
      'localhost:5000',
      'http://user:pass@host',
      'http://host/api',
    ]) {
      expect(() => Api(address), throwsFormatException);
    }
  });
  test('JSON 전송, 한글 응답, 서버 검증 오류 전달', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/api/jobs');
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body['request_key'], 'same-key');
      request.response.statusCode = 409;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': '이미 진행 중인 제조가 있습니다.'}));
      await request.response.close();
    });
    final api = Api('http://127.0.0.1:${server.port}');
    await expectLater(
      api.call('/jobs', method: 'POST', body: {'request_key': 'same-key'}),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('이미 진행 중'),
        ),
      ),
    );
  });

  test('실계량 제어 키는 제조 요청에만 전달', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final key = List.filled(32, 'a').join(); // 테스트용 값
    final keys = <String, String?>{};
    server.listen((request) async {
      keys[request.uri.path] = request.headers.value('X-UART-Control-Token');
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final api = Api('http://127.0.0.1:${server.port}', controlKey: key);
    await api.call('/state');
    await api.call('/jobs', method: 'POST', body: {'device_mode': 'uart'});
    await api.call('/jobs/test-job/stop', method: 'POST', body: {});
    expect(keys, {
      '/api/state': null,
      '/api/jobs': key,
      '/api/jobs/test-job/stop': key,
    });
  });
}
