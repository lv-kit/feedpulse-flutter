import 'sanitize.dart';

/// 画面上の該当箇所（`context.auto.target`）。
///
/// feedpulse-web の `target` スキーマ（#106）に合わせた形:
/// `platform` / `screen` / `id` / `path` / `rect` / `label`。
class FeedpulseTargetData {
  const FeedpulseTargetData({
    this.screen,
    this.id,
    this.path,
    this.rect,
    this.label,
  });

  /// 固定値 `flutter`。
  String get platform => 'flutter';

  /// 画面名。`ModalRoute` の名前、または呼び出し側が渡した名前。
  final String? screen;

  /// `FeedpulseTarget(id: ...)` で付けた明示 ID。
  final String? id;

  /// 自動取得したウィジェットパス（補助。難読化で型名が変わりうる）。
  final String? path;

  /// 論理ピクセル単位の画面上の矩形。
  final FeedpulseRect? rect;

  /// Semantics ラベルまたは Text の先頭 N 文字。入力値は含まない。
  final String? label;

  /// `context.auto.target` にそのまま載せられる JSON。null の項目は含めない。
  Map<String, Object?> toJson() {
    final sanitizedId = sanitizeTargetId(id);
    final result = <String, Object?>{
    'platform': platform,
    if (screen != null) 'screen': screen,
    if (path != null) 'path': path,
    if (rect != null) 'rect': rect!.toJson(),
    if (label != null) 'label': label,
    };
    if (sanitizedId != null) result['id'] = sanitizedId;
    return result;
  }

  @override
  String toString() => 'FeedpulseTargetData(${toJson()})';
}

/// `target.rect`。有限の数値のみ。
class FeedpulseRect {
  const FeedpulseRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final double x;
  final double y;
  final double w;
  final double h;

  bool get isFinite => x.isFinite && y.isFinite && w.isFinite && h.isFinite;

  Map<String, Object?> toJson() => <String, Object?>{
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  };

  @override
  bool operator ==(Object other) =>
      other is FeedpulseRect &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'FeedpulseRect($x, $y, $w, $h)';
}
