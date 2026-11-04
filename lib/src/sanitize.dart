/// `target` の文字列上限。#106 の確定値が出るまでの保守的な既定値。
class FeedpulseTargetLimits {
  const FeedpulseTargetLimits({
    this.maxLabel = 80,
    this.maxId = 128,
    this.maxPath = 256,
    this.maxScreen = 128,
  });

  /// ラベルは先頭この文字数（rune 単位）まで。
  final int maxLabel;
  final int maxId;
  final int maxPath;
  final int maxScreen;
}

final RegExp _controlChars = RegExp(r'[\u0000-\u001F\u007F-\u009F  ]');
final RegExp _spaces = RegExp(r'\s+');

/// 制御文字を空白に置き、空白を畳み、rune 単位で [max] 文字に切る。空なら null。
String? sanitizeTargetString(String? input, int max) {
  if (input == null || max <= 0) return null;
  final cleaned =
      input.replaceAll(_controlChars, ' ').replaceAll(_spaces, ' ').trim();
  if (cleaned.isEmpty) return null;
  final runes = cleaned.runes;
  if (runes.length <= max) return cleaned;
  return String.fromCharCodes(runes.take(max)).trimRight();
}
