## 0.1.0

- SDK 本体を追加: `Feedpulse.configure` / `refreshConfig` / `submit` / `identify`、`FeedpulseException`（契約のエラーコード）。
- アプリ証明を追加: iOS は App Attest、Android は Play Integrity（プラグインとして `ios/` `android/` を追加）。`POST /v1/native/session` のセッションを 900 秒キャッシュし、期限前に更新。
- `GET /v1/config` の取得とローカルキャッシュ（失敗時は前回値）、項目定義に基づくクライアント側検証。
- `POST /v1/submit`: 冪等キー、再送（バックオフ、429 は `Retry-After` を尊重）、`context.auto.target` / `context.identity` / `context.custom`。
- 既存のピッカー API（`FeedpulseTarget` / `FeedpulseTargetPicker`）は変更なし。
- 実機の App Attest / Play Integrity は未検証。

## 0.0.1

- 該当箇所ピッカー（FeedpulseTarget / FeedpulseTargetPicker）を追加。
