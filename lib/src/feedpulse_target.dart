import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 子ウィジェットに明示 ID を付ける。ピッカーはこの ID を最優先で `target.id` に使う。
///
/// 難読化（`--obfuscate`）されたリリースビルドでも ID は変わらない。
/// 見た目・レイアウト・ヒットテストには影響しない。
class FeedpulseTarget extends SingleChildRenderObjectWidget {
  const FeedpulseTarget({
    super.key,
    required this.id,
    this.includeLabel = true,
    super.child,
  });

  /// 明示 ID（例: `checkout_button`）。
  final String id;

  /// false にするとこの配下からラベル（Text / Semantics）を取得しない。
  final bool includeLabel;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFeedpulseTarget(id: id, includeLabel: includeLabel);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderFeedpulseTarget renderObject,
  ) {
    renderObject
      ..id = id
      ..includeLabel = includeLabel;
  }
}

/// [FeedpulseTarget] の RenderObject。ヒットテスト経路に載るため、
/// release ビルドでも RenderObject から ID を引ける。
class RenderFeedpulseTarget extends RenderProxyBox {
  RenderFeedpulseTarget({required this.id, required this.includeLabel});

  String id;
  bool includeLabel;
}
