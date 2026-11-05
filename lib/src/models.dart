class FeedpulseOption {
  const FeedpulseOption(this.value, this.label);
  final String value;
  final String label;
}

/// フォームの項目（ブロック）定義。`type` は short_text / long_text / email /
/// number / select / radio / checkbox / rating / image / file。
class FeedpulseBlock {
  const FeedpulseBlock({
    required this.id,
    required this.type,
    required this.label,
    required this.required,
    this.maxLength,
    this.min,
    this.max,
    this.options = const [],
    this.maxFiles,
    this.maxTotalBytes,
  });

  final String id;
  final String type;
  final String label;
  final bool required;
  final int? maxLength;
  final num? min;
  final num? max;
  final List<FeedpulseOption> options;
  final int? maxFiles;
  final int? maxTotalBytes;

  factory FeedpulseBlock.fromJson(Map<String, Object?> j) => FeedpulseBlock(
    id: j['id']! as String,
    type: j['type']! as String,
    label: j['label']! as String,
    required: j['required']! as bool,
    maxLength: (j['maxLength'] as num?)?.toInt(),
    min: j['min'] as num?,
    max: j['max'] as num?,
    options: [
      for (final o in (j['options'] as List?) ?? const [])
        FeedpulseOption((o as Map)['value']! as String, o['label']! as String),
    ],
    maxFiles: (j['maxFiles'] as num?)?.toInt(),
    maxTotalBytes: (j['maxTotalBytes'] as num?)?.toInt(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'label': label,
    'required': required,
    if (maxLength != null) 'maxLength': maxLength,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (options.isNotEmpty)
      'options': [
        for (final o in options) {'value': o.value, 'label': o.label},
      ],
    if (maxFiles != null) 'maxFiles': maxFiles,
    if (maxTotalBytes != null) 'maxTotalBytes': maxTotalBytes,
  };
}

class FeedpulseForm {
  const FeedpulseForm({
    required this.id,
    required this.slug,
    required this.name,
    required this.type,
    required this.version,
    required this.allowTarget,
    required this.blocks,
  });

  final String id;
  final String slug;
  final String name;

  /// `inquiry` / `bug` / `improvement`。
  final String type;

  /// 公開済みの版。
  final int version;

  /// true のときだけ `context.auto.target` を送る。
  final bool allowTarget;
  final List<FeedpulseBlock> blocks;

  factory FeedpulseForm.fromJson(Map<String, Object?> j) {
    final def = j['definition']! as Map;
    return FeedpulseForm(
      id: j['id']! as String,
      slug: j['slug']! as String,
      name: j['name']! as String,
      type: j['type']! as String,
      version: (j['version']! as num).toInt(),
      allowTarget: (def['allowTarget'] as bool?) ?? false,
      blocks: [
        for (final b in def['blocks']! as List)
          FeedpulseBlock.fromJson((b as Map).cast<String, Object?>()),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'slug': slug,
    'name': name,
    'type': type,
    'version': version,
    'definition': {
      'allowTarget': allowTarget,
      'blocks': [for (final b in blocks) b.toJson()],
    },
  };
}

/// `GET /v1/config` の内容。
class FeedpulseConfig {
  const FeedpulseConfig({
    required this.forms,
    required this.fetchedAt,
    this.isStale = false,
  });

  final List<FeedpulseForm> forms;

  /// 取得時刻。
  final DateTime fetchedAt;

  /// 通信に失敗して前回の保存値を返しているとき true。
  final bool isStale;

  FeedpulseForm? form(String slug) {
    for (final f in forms) {
      if (f.slug == slug) return f;
    }
    return null;
  }

  FeedpulseForm? formById(String id) {
    for (final f in forms) {
      if (f.id == id) return f;
    }
    return null;
  }

  FeedpulseConfig asStale() =>
      FeedpulseConfig(forms: forms, fetchedAt: fetchedAt, isStale: true);
}

/// `POST /v1/submit` の受理結果（202）。
class SubmitReceipt {
  const SubmitReceipt(this.id);
  final String id;
}
