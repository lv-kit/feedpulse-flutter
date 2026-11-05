import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FeedpulseRequest {
  const FeedpulseRequest(this.method, this.url, this.headers, [this.body]);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
}

class FeedpulseResponse {
  const FeedpulseResponse(this.status, this.headers, this.body);
  final int status;

  /// キーは小文字。
  final Map<String, String> headers;
  final String body;
}

/// HTTP の差し替え口。通信失敗は [IOException] / [TimeoutException] を投げる。
/// `Origin` ヘッダーは付けない（付けるとサーバーが Web 経路として扱う）。
abstract interface class FeedpulseTransport {
  Future<FeedpulseResponse> send(FeedpulseRequest request);
}

/// `dart:io` の [HttpClient] による既定の実装。
class IoFeedpulseTransport implements FeedpulseTransport {
  IoFeedpulseTransport({this.timeout = const Duration(seconds: 30)});
  final Duration timeout;

  @override
  Future<FeedpulseResponse> send(FeedpulseRequest request) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(request.method, request.url);
      request.headers.forEach(req.headers.set);
      if (request.body != null) {
        final bytes = utf8.encode(request.body!);
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(', '));
      return FeedpulseResponse(res.statusCode, headers, body);
    } finally {
      client.close(force: true);
    }
  }
}
