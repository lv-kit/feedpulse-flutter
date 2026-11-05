# feedpulse (Flutter SDK)

Feedpulse の Flutter SDK。ヘッドレス（UI・スクリーンショットは含まない）。

- 設定取得（`GET /v1/config`）とローカルキャッシュ（失敗時は前回値）
- アプリ証明（iOS: App Attest、Android: Play Integrity）とセッション管理
- 項目定義に基づく入力検証、`POST /v1/submit`（冪等キー・再送）、`identify`
- 該当箇所ピッカー（`context.auto.target`）

## 導入

> **利用には Feedpulse への登録が必要。** SDK を使う前に <https://feedpulse.stargazy.xyz/> でアカウントを登録し、プロジェクトを作成して公開鍵（`pk_`）を発行する。さらに、プロジェクトに**アプリを登録**する（iOS: bundle ID と Apple Team ID、Android: package name と署名証明書の SHA-256）。未登録のアプリは `app_not_registered` になる。

要件: Dart `^3.13.4` / Flutter `>=3.22.0`、iOS 14+、Android minSdk 23。

```bash
flutter pub add feedpulse
```

```dart
import 'package:feedpulse/feedpulse.dart';
```

### プラットフォーム設定

- **iOS**: Xcode の Signing & Capabilities で **App Attest** を有効にする（entitlement `com.apple.developer.devicecheck.appattest-environment`。開発ビルドは `development`、配布は `production`）。サーバー側で開発環境の許可（`APPLE_APP_ATTEST_ALLOW_DEVELOPMENT`）が必要。シミュレーターは App Attest 非対応（`attestationUnavailable`）。
- **Android**: Play Console でアプリに **Play Integrity API** を有効にし、Google Cloud プロジェクトを紐づける。Google Play 配信（内部テスト含む）の署名で判定される。エミュレーターや Play ストアの無い端末は `attestationUnavailable`。

## 使い方

```dart
// 1. 起動時に 1 回
Feedpulse.configure(publicKey: 'pk_...'); // baseUrl の既定は本番

// 2. 項目定義を取得（失敗時は前回値。isStale で判別）
final config = await Feedpulse.refreshConfig();
final form = config.form('bug')!;

// 3. ログイン中のユーザーを紐づける（任意）。顧客バックエンドが sk_ で署名した JWT をそのまま渡す。
Feedpulse.identify(jwtFromYourBackend); // null で解除

// 4. 送信。入力は項目定義で事前検証され、不正なら送らず invalidFields を投げる。
try {
  final receipt = await Feedpulse.submit(
    formId: form.id,
    fields: {'title': 'ログインできない', 'severity': 'high'},
    target: target,          // ピッカーの結果（任意）。form.allowTarget のときだけ送る
    custom: {'plan': 'pro'}, // context.custom（任意）
  );
} on FeedpulseException catch (e) {
  switch (e.code) {
    case FeedpulseErrorCode.invalidFields:   // e.fieldErrors: ブロック ID → FieldErrorCode
    case FeedpulseErrorCode.identityInvalid: // e.identityCode: 'expired' など
    case FeedpulseErrorCode.rateLimited:     // e.retryAfterSeconds
    default:
      break;
  }
}
```

### 公開 API

- `Feedpulse.configure({publicKey, baseUrl})` / `Feedpulse.identify(token)` / `Feedpulse.refreshConfig()` / `Feedpulse.submit({formId, fields, target, custom, idempotencyKey})`
- `FeedpulseClient`（`Feedpulse.client`）: 上記の本体。`config` / `lastError` / `loadCachedConfig()`
- `FeedpulseConfig` / `FeedpulseForm` / `FeedpulseBlock` / `SubmitReceipt`
- `FeedpulseException`（`code: FeedpulseErrorCode`、`httpStatus`、`fieldErrors`、`identityCode`、`retryAfterSeconds`）。`FeedpulseErrorCode` は契約のエラーコードと、SDK 側の `notConfigured` / `network` / `attestationUnavailable` / `unexpectedResponse`
- 差し替え口: `AppAttestor`（既定は `NativeAppAttestor`。`DevInsecureAttestor` はローカル開発サーバー専用）、`FeedpulseTransport`、`ConfigStore`
- `validateFields(form, fields)`: 入力検証。値の型は short_text / long_text / email / select / radio = `String`、number / rating = `num`、checkbox = `List<String>`。image / file は未対応

### 挙動

- セッションは 900 秒有効。期限の 60 秒前に取り直し、`invalid_session` なら取り直して 1 回だけやり直す。challenge の期限切れも 1 回だけやり直す。
- `submit` は同じ冪等キーで再送する。対象は通信失敗・429・5xx で、最大 3 回（1 秒から倍々、429 は `Retry-After` を優先）。キーはアプリ側から渡すこともできる。
- iOS は端末鍵 ID を UserDefaults に保存し、初回だけ attestation、以降は assertion を送る。サーバーが `attestation_failed` を返したら保存した鍵を捨てる。
- `Origin` ヘッダーは付けない。`X-FeedPulse-Platform` と `Authorization: Bearer` でネイティブ経路として扱われる。
- 画像・ファイル添付は未対応。

## 該当箇所ピッカー

```dart
// 1. 明示 ID を付ける（難読化・release でも安定）
FeedpulseTarget(
  id: 'checkout_button',
  child: ElevatedButton(onPressed: ..., child: const Text('購入する')),
)

// 2. 不具合報告フォームから呼ぶ。次のタップを奪い、そのウィジェットを返す。
final picker = FeedpulseTargetPicker(screen: 'CheckoutScreen'); // screen 省略時は ModalRoute 名
final target = await picker.pick(context); // キャンセル・特定不能なら null
picker.cancel();                           // 選択中に中止

final json = target?.toJson();
// {platform: flutter, screen, id, path, rect: {x,y,w,h}, label}
```

`pick` の結果（`FeedpulseTargetData`）をそのまま `Feedpulse.submit(target:)` に渡せる。

## 仕組みと方針

- `Overlay` + `Listener` の透明な全面オーバーレイでタップを奪い、`WidgetsBinding.hitTestInView` の経路から
  RenderObject → Element → Widget を引く。Widget Inspector / `debugCreator` は使わないので release でも動く。
- `id` は `FeedpulseTarget(id:)` のみ。無い場合は `path`（ウィジェット型名と `ValueKey` の連なり）、
  `label`（Semantics / Text / Icon.semanticLabel）で補う。型名は `--obfuscate` で変わるため、本番では `FeedpulseTarget` を推奨。
- `TextField` などの入力値（`EditableText`）は読まない。入力欄を指した場合と、`FeedpulseTarget` 配下に入力欄がある場合は `label` も返さない。
  `FeedpulseTarget(includeLabel: false)` で個別に止められる。
- `label` は先頭 `FeedpulseTargetLimits.maxLabel`（既定 80）文字。制御文字は除去する。
- `rect` は View 内の論理ピクセル。`platform` は `flutter`。

## 検証範囲

契約 fixture を使った単体テスト（HTTP とアプリ証明を差し替え）、`flutter analyze`、`dart pub publish --dry-run` は CI で確認している。**実機の App Attest / Play Integrity の動作は未検証**（ネイティブ実装は書いたが、実機・実サーバーでの疎通は手作業で確認が必要）。

## 開発

```bash
flutter analyze
flutter test
dart pub publish --dry-run
```

テストは web の契約 fixture（`test/fixtures/contract.json`。正本は feedpulse-web の `packages/shared/src/native/fixtures/`）を読み、HTTP とアプリ証明を差し替えて検証する。
