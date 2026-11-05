import CryptoKit
import DeviceCheck
import Flutter
import UIKit

/// Feedpulse のネイティブ側。App Attest、端末情報、config の保存を Dart に提供する。
/// 実機の App Attest 動作は CI では検証していない（シミュレーターは App Attest 非対応）。
public class FeedpulsePlugin: NSObject, FlutterPlugin {
    private static let keyIdDefaultsKey = "dev.feedpulse.appattest.keyId"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dev.feedpulse/native", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(FeedpulsePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "environment":
            result([
                "platform": "ios",
                "appId": Bundle.main.bundleIdentifier ?? "",
                "os": "iOS \(UIDevice.current.systemVersion)",
                "timezone": TimeZone.current.identifier,
            ])
        case "attest":
            guard let challenge = args?["challenge"] as? String else {
                result(FlutterError(code: "bad_args", message: "challenge が無い", details: nil))
                return
            }
            attest(challenge: challenge, result: result)
        case "resetAttestation":
            UserDefaults.standard.removeObject(forKey: Self.keyIdDefaultsKey)
            result(nil)
        case "storeRead":
            result(UserDefaults.standard.string(forKey: "dev.feedpulse.store." + (args?["key"] as? String ?? "")))
        case "storeWrite":
            if let key = args?["key"] as? String, let value = args?["value"] as? String {
                UserDefaults.standard.set(value, forKey: "dev.feedpulse.store." + key)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 鍵 ID が保存済みなら assertion、無ければ鍵を作って attestation。
    /// clientDataHash = SHA256(challenge の UTF-8)。keyId は base64（標準、パディングあり）のまま送る。
    private func attest(challenge: String, result: @escaping FlutterResult) {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            result(FlutterError(code: "app_attest_unsupported", message: "この端末は App Attest 非対応（シミュレーターなど）", details: nil))
            return
        }
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        if let keyId = UserDefaults.standard.string(forKey: Self.keyIdDefaultsKey) {
            service.generateAssertion(keyId, clientDataHash: hash) { assertion, error in
                if let assertion = assertion {
                    result([
                        "type": "app_attest_assertion",
                        "keyId": keyId,
                        "assertion": assertion.base64EncodedString(),
                    ])
                } else {
                    result(FlutterError(code: "app_attest_failed", message: error?.localizedDescription, details: nil))
                }
            }
            return
        }
        service.generateKey { keyId, error in
            guard let keyId = keyId else {
                result(FlutterError(code: "app_attest_failed", message: error?.localizedDescription, details: nil))
                return
            }
            service.attestKey(keyId, clientDataHash: hash) { attestation, error in
                if let attestation = attestation {
                    // 保存は attestation を得た後。サーバーが拒否したら Dart が resetAttestation を呼ぶ。
                    UserDefaults.standard.set(keyId, forKey: Self.keyIdDefaultsKey)
                    result([
                        "type": "app_attest_attestation",
                        "keyId": keyId,
                        "attestation": attestation.base64EncodedString(),
                    ])
                } else {
                    result(FlutterError(code: "app_attest_failed", message: error?.localizedDescription, details: nil))
                }
            }
        }
    }
}
