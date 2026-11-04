/// `target` の上限。web `TARGET_LIMITS`（#106）に合わせる:
/// screen 512 / id 200 / path 512 / label 200（UTF-16 長）、rect は絶対値 1,000,000 以下。
/// サーバーは超過時に切り詰めず target ごと捨てるため、SDK 側で上限内に収める。
class FeedpulseTargetLimits {
  const FeedpulseTargetLimits({
    this.maxLabel = 80,
    this.maxId = serverMaxId,
    this.maxPath = serverMaxPath,
    this.maxScreen = serverMaxScreen,
  });

  static const int serverMaxScreen = 512;
  static const int serverMaxId = 200;
  static const int serverMaxPath = 512;
  static const int serverMaxLabel = 200;
  static const double serverMaxRectAbs = 1000000;

  /// ラベルは先頭この文字数まで。既定 80、サーバー上限 200 を超えない。
  final int maxLabel;
  final int maxId;
  final int maxPath;
  final int maxScreen;
}

final RegExp _controlChars = RegExp(r'[\u0000-\u001F\u007F-\u009F  ]');
final RegExp _spaces = RegExp(r'\s+');

/// 制御文字を空白に置き、空白を畳み、UTF-16 長 [max] 以内に切る（rune 単位で切る）。空なら null。
String? sanitizeTargetString(String? input, int max) {
  if (input == null || max <= 0) return null;
  final cleaned =
      input.replaceAll(_controlChars, ' ').replaceAll(_spaces, ' ').trim();
  if (cleaned.isEmpty) return null;
  if (cleaned.length <= max) return cleaned;
  final out = StringBuffer();
  var len = 0;
  for (final r in cleaned.runes) {
    final unit = r > 0xFFFF ? 2 : 1;
    if (len + unit > max) break;
    out.writeCharCode(r);
    len += unit;
  }
  final text = out.toString().trimRight();
  return text.isEmpty ? null : text;
}
