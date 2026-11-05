import 'package:flutter/services.dart';

import 'errors.dart';

/// 端末・アプリの情報。
class AppEnvironment {
  const AppEnvironment({
    required this.platform,
    required this.appId,
    required this.os,
    required this.timezone,
  });

  /// `ios` または `android`。
  final String platform;

  /// iOS は bundle ID、Android は package name。
  final String appId;

  /// 例: `iOS 18.1` / `Android 15`。
  final String os;

  /// IANA タイムゾーン名。
  final String timezone;
}

/// アプリ証明の取得を抽象化する。既定は [NativeAppAttestor]
/// （iOS: App Attest、Android: Play Integrity）。単体テストや独自方式では差し替える。
abstract interface class AppAttestor {
  Future<AppEnvironment> environment();

  /// サーバー発行の [challenge] に対する `POST /v1/native/session` の `attestation` を返す。
  /// 失敗は [FeedpulseException]（[FeedpulseErrorCode.attestationUnavailable]）。
  Future<Map<String, Object?>> attest(String challenge);

  /// 保存している証明用の状態（iOS の端末鍵 ID）を捨てる。
  /// サーバーが `attestation_failed` を返したときに呼ばれる。
  Future<void> reset();
}

const _channelName = 'dev.feedpulse/native';

/// このパッケージのネイティブ実装（MethodChannel）。
/// iOS は App Attest、Android は Play Integrity（classic request。nonce = challenge）。
class NativeAppAttestor implements AppAttestor {
  NativeAppAttestor({MethodChannel? channel})
    : channel = channel ?? const MethodChannel(_channelName);

  final MethodChannel channel;

  @override
  Future<AppEnvironment> environment() async {
    try {
      final m = await channel.invokeMapMethod<String, Object?>('environment');
      return AppEnvironment(
        platform: m!['platform']! as String,
        appId: m['appId']! as String,
        os: m['os']! as String,
        timezone: m['timezone']! as String,
      );
    } on PlatformException catch (e) {
      throw _unavailable(e);
    } on MissingPluginException catch (e) {
      throw FeedpulseException(
        FeedpulseErrorCode.attestationUnavailable,
        message: 'この環境はネイティブ実装が無い（iOS / Android のみ対応）: ${e.message}',
        cause: e,
      );
    }
  }

  @override
  Future<Map<String, Object?>> attest(String challenge) async {
    try {
      final m = await channel.invokeMapMethod<String, Object?>('attest', {
        'challenge': challenge,
      });
      return m!;
    } on PlatformException catch (e) {
      throw _unavailable(e);
    }
  }

  @override
  Future<void> reset() async {
    try {
      await channel.invokeMethod<void>('resetAttestation');
    } on PlatformException {
      // 掃除に失敗しても次回の証明で再度試す。
    }
  }

  FeedpulseException _unavailable(PlatformException e) => FeedpulseException(
    FeedpulseErrorCode.attestationUnavailable,
    message: '${e.code}: ${e.message}',
    cause: e,
  );
}

/// ローカル開発専用。サーバーが `NATIVE_ATTEST_INSECURE_DEV=true`（`env.dev`）のときだけ通る。
/// 本番では `attestation_failed` になる。
class DevInsecureAttestor implements AppAttestor {
  DevInsecureAttestor({
    required this.platform,
    required this.appId,
    this.os = 'dev',
    this.timezone = 'UTC',
  });

  final String platform;
  final String appId;
  final String os;
  final String timezone;

  @override
  Future<AppEnvironment> environment() async => AppEnvironment(
    platform: platform,
    appId: appId,
    os: os,
    timezone: timezone,
  );

  @override
  Future<Map<String, Object?>> attest(String challenge) async => {
    'type': 'dev_insecure',
  };

  @override
  Future<void> reset() async {}
}
