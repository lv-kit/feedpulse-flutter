# feedpulse (Flutter SDK)

Feedpulse の Flutter SDK。現状は「該当箇所ピッカー」のみ（ヘッドレス。UI・スクリーンショットは含まない）。
結果は `context.auto.target` に載せる `target` として返る。

## 使い方

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

## 仕組みと方針

- `Overlay` + `Listener` の透明な全面オーバーレイでタップを奪い、`WidgetsBinding.hitTestInView` の経路から
  RenderObject → Element → Widget を引く。Widget Inspector / `debugCreator` は使わないので release でも動く。
- `id` は `FeedpulseTarget(id:)` のみ。無い場合は `path`（ウィジェット型名と `ValueKey` の連なり）、
  `label`（Semantics / Text / Icon.semanticLabel）で補う。型名は `--obfuscate` で変わるため、本番では `FeedpulseTarget` を推奨。
- `TextField` などの入力値（`EditableText`）は読まない。入力欄を指した場合と、`FeedpulseTarget` 配下に入力欄がある場合は `label` も返さない。
  `FeedpulseTarget(includeLabel: false)` で個別に止められる。
- `label` は先頭 `FeedpulseTargetLimits.maxLabel`（既定 80）文字。制御文字は除去する。
- `rect` は View 内の論理ピクセル。`platform` は `flutter`。

## 開発

```bash
flutter analyze
flutter test
```
