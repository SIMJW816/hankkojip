import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Api {
  Api(String address, {this._controlKey = ''}) : base = Uri.parse(address) {
    if (!['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw const FormatException('http://서버주소:포트 형식으로 입력해 주세요.');
    }
  }
  final Uri base;
  final String _controlKey;

  Future<Map<String, dynamic>> call(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await (() async {
        final request = await client.openUrl(method, base.resolve('/api$path'));
        if (_controlKey.isNotEmpty &&
            (path == '/jobs' ||
                (path.startsWith('/jobs/') && path.endsWith('/stop')) ||
                path.startsWith('/slots/'))) {
          request.followRedirects = false;
          request.headers.set('X-UART-Control-Token', _controlKey);
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final value = jsonDecode(await utf8.decoder.bind(response).join());
        if (value is! Map<String, dynamic>) {
          throw const FormatException('서버 응답 형식이 올바르지 않습니다.');
        }
        if (response.statusCode >= 400) {
          throw ApiException(value['error']?.toString() ?? '서버 오류');
        }
        return value;
      })().timeout(
        Duration(
          seconds: path == '/suggestions' || path == '/ai/chat' ? 45 : 12,
        ),
      );
    } on SocketException {
      throw ApiException('서버에 연결할 수 없습니다. 주소, Wi-Fi와 로컬 네트워크 권한을 확인하세요.');
    } on TimeoutException {
      if (path == '/suggestions' || path == '/ai/chat') {
        throw ApiException('AI 응답 시간이 초과되었습니다. 잠시 후 다시 시도해 주세요.');
      }
      throw ApiException('응답 시간이 초과되었습니다. 계량 요청은 같은 승인창에서 재시도하세요.');
    } finally {
      client.close(force: true);
    }
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
