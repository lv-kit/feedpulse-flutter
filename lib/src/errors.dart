/// 契約（web の error-response スキーマ）のエラーコードと、SDK 内で起きるエラー。
enum FeedpulseErrorCode {
  invalidJson('invalid_json'),
  invalidPk('invalid_pk'),
  invalidPlatform('invalid_platform'),
  invalidApp('invalid_app'),
  invalidChallenge('invalid_challenge'),
  challengeExpired('challenge_expired'),
  attestationFailed('attestation_failed'),
  appNotRegistered('app_not_registered'),
  invalidSession('invalid_session'),
  rateLimited('rate_limited'),
  unknownProject('unknown_project'),
  unknownForm('unknown_form'),
  invalidForm('invalid_form'),
  invalidIdempotencyKey('invalid_idempotency_key'),
  invalidFields('invalid_fields'),
  identityInvalid('identity_invalid'),
  payloadTooLarge('payload_too_large'),
  unsupportedMediaType('unsupported_media_type'),
  quotaExceeded('quota_exceeded'),
  projectReadOnly('project_read_only'),
  notFound('not_found'),
  internal('internal'),

  // ---- SDK 側で起きるもの（契約のコードではない） ----

  /// `Feedpulse.configure` 前の呼び出し、または不正な引数。
  notConfigured(null),

  /// 通信できなかった（接続失敗・タイムアウト）。
  network(null),

  /// アプリ証明を取得できなかった（Play ストア無し・App Attest 非対応の端末など）。
  attestationUnavailable(null),

  /// サーバーが契約外の応答を返した。
  unexpectedResponse(null);

  const FeedpulseErrorCode(this.wire);

  /// 契約上の文字列。SDK 側のコードは null。
  final String? wire;

  static FeedpulseErrorCode? fromWire(Object? value) {
    if (value is! String) return null;
    for (final c in values) {
      if (c.wire != null && c.wire == value) return c;
    }
    return null;
  }
}

/// `invalid_fields` の検証エラーコード（サーバーと同じ語彙）。
enum FieldErrorCode {
  required('required'),
  type('type'),
  tooLong('too_long'),
  invalidOption('invalid_option'),
  invalidEmail('invalid_email'),
  outOfRange('out_of_range'),
  tooManyFiles('too_many_files'),
  invalidUpload('invalid_upload');

  const FieldErrorCode(this.wire);
  final String wire;

  static FieldErrorCode? fromWire(Object? value) {
    for (final c in values) {
      if (c.wire == value) return c;
    }
    return null;
  }
}

/// SDK が投げる唯一の例外型。
class FeedpulseException implements Exception {
  const FeedpulseException(
    this.code, {
    this.message,
    this.httpStatus,
    this.fieldErrors = const {},
    this.identityCode,
    this.retryAfterSeconds,
    this.cause,
  });

  /// 契約のエラーコード、または SDK 側のコード。
  final FeedpulseErrorCode code;
  final String? message;

  /// サーバー応答のときの HTTP ステータス。
  final int? httpStatus;

  /// [FeedpulseErrorCode.invalidFields] のとき、ブロック ID → 検証エラー。
  /// クライアント側検証でも同じ形で返す。
  final Map<String, FieldErrorCode> fieldErrors;

  /// [FeedpulseErrorCode.identityInvalid] のとき、サーバーが返した理由（`expired` など）。
  final String? identityCode;

  /// `Retry-After`（秒）。429 など。
  final int? retryAfterSeconds;
  final Object? cause;

  /// 同じ送信を再試行してよいか（通信失敗・429・5xx）。
  bool get isRetryable =>
      code == FeedpulseErrorCode.network ||
      code == FeedpulseErrorCode.rateLimited ||
      code == FeedpulseErrorCode.internal ||
      (httpStatus != null && httpStatus! >= 500);

  @override
  String toString() =>
      'FeedpulseException(${code.wire ?? code.name}'
      '${httpStatus != null ? ', status=$httpStatus' : ''}'
      '${message != null ? ', $message' : ''}'
      '${fieldErrors.isNotEmpty ? ', fields=${{for (final e in fieldErrors.entries) e.key: e.value.wire}}' : ''})';
}
