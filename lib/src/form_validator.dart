import 'errors.dart';
import 'models.dart';

final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// 項目定義に基づくクライアント側の入力検証。サーバーと同じ語彙で返す。
/// 最終的な判定はサーバー。ここは往復を省くための事前チェック。
///
/// 値の型: short_text / long_text / email / select / radio = String、
/// number / rating = num、checkbox = `List<String>`。
/// image / file は未対応（検証しない。送信もしない）。
Map<String, FieldErrorCode> validateFields(
  FeedpulseForm form,
  Map<String, Object?> fields,
) {
  final errors = <String, FieldErrorCode>{};
  final known = {for (final b in form.blocks) b.id};
  for (final k in fields.keys) {
    if (!known.contains(k)) errors[k] = FieldErrorCode.type;
  }
  for (final b in form.blocks) {
    if (b.type == 'image' || b.type == 'file') continue;
    final v = fields[b.id];
    if (_isEmpty(v)) {
      if (b.required) errors[b.id] = FieldErrorCode.required;
      continue;
    }
    final e = _check(b, v!);
    if (e != null) errors[b.id] = e;
  }
  return errors;
}

bool _isEmpty(Object? v) => switch (v) {
  null => true,
  String s => s.trim().isEmpty,
  Iterable<Object?> i => i.isEmpty,
  _ => false,
};

bool _finite(Object v) => v is num && v.isFinite;

FieldErrorCode? _check(FeedpulseBlock b, Object v) {
  switch (b.type) {
    case 'short_text':
    case 'long_text':
      if (v is! String) return FieldErrorCode.type;
      if (b.maxLength != null && v.length > b.maxLength!) {
        return FieldErrorCode.tooLong;
      }
      return null;
    case 'email':
      if (v is! String) return FieldErrorCode.type;
      if (b.maxLength != null && v.length > b.maxLength!) {
        return FieldErrorCode.tooLong;
      }
      return _email.hasMatch(v) ? null : FieldErrorCode.invalidEmail;
    case 'number':
    case 'rating':
      if (!_finite(v)) return FieldErrorCode.type;
      final n = v as num;
      if (b.min != null && n < b.min!) return FieldErrorCode.outOfRange;
      if (b.max != null && n > b.max!) return FieldErrorCode.outOfRange;
      return null;
    case 'select':
    case 'radio':
      if (v is! String) return FieldErrorCode.type;
      return b.options.any((o) => o.value == v)
          ? null
          : FieldErrorCode.invalidOption;
    case 'checkbox':
      if (v is! Iterable || v.any((x) => x is! String)) {
        return FieldErrorCode.type;
      }
      for (final x in v) {
        if (!b.options.any((o) => o.value == x)) {
          return FieldErrorCode.invalidOption;
        }
      }
      return null;
    default:
      return null;
  }
}
