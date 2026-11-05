import 'attestor.dart';
import 'client.dart';
import 'config_store.dart';
import 'errors.dart';
import 'models.dart';
import 'target_data.dart';
import 'transport.dart';

/// SDK の入口。`configure` を 1 回呼んでから `submit` などを使う。
abstract final class Feedpulse {
  /// 既定の API ベース URL（本番の ingest）。
  static const defaultBaseUrl = 'https://ingest.feedpulse.stargazy.xyz';

  static FeedpulseClient? _client;

  /// SDK を初期化する。アプリ起動時に 1 回呼ぶ。再度呼ぶと置き換わる。
  /// 通信は最初の [refreshConfig] / [submit] で始まる。
  ///
  /// [attestor] / [transport] / [store] は主にテスト用の差し替え口。
  static FeedpulseClient configure({
    required String publicKey,
    String baseUrl = defaultBaseUrl,
    AppAttestor? attestor,
    FeedpulseTransport? transport,
    ConfigStore? store,
  }) {
    if (publicKey.trim().isEmpty) {
      throw const FeedpulseException(
        FeedpulseErrorCode.notConfigured,
        message: 'publicKey が空',
      );
    }
    final uri = Uri.tryParse(baseUrl);
    final local =
        uri != null &&
        const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
    if (uri == null ||
        !(uri.scheme == 'https' || (uri.scheme == 'http' && local))) {
      throw const FeedpulseException(
        FeedpulseErrorCode.notConfigured,
        message:
            'baseUrl は https（開発用の localhost / 127.0.0.1 / 10.0.2.2 のみ http 可）',
      );
    }
    return _client = FeedpulseClient(
      publicKey: publicKey,
      baseUrl: baseUrl,
      attestor: attestor,
      transport: transport,
      store: store,
    );
  }

  /// [configure] で作ったクライアント。未設定なら `notConfigured` を投げる。
  static FeedpulseClient get client =>
      _client ??
      (throw const FeedpulseException(
        FeedpulseErrorCode.notConfigured,
        message: 'Feedpulse.configure を先に呼ぶ',
      ));

  /// [FeedpulseClient.identify]
  static void identify(String? token) => client.identify(token);

  /// [FeedpulseClient.refreshConfig]
  static Future<FeedpulseConfig> refreshConfig() => client.refreshConfig();

  /// [FeedpulseClient.submit]
  static Future<SubmitReceipt> submit({
    required String formId,
    required Map<String, Object?> fields,
    FeedpulseTargetData? target,
    Map<String, Object>? custom,
    String? idempotencyKey,
  }) => client.submit(
    formId: formId,
    fields: fields,
    target: target,
    custom: custom,
    idempotencyKey: idempotencyKey,
  );
}
