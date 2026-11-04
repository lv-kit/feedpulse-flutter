import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'feedpulse_target.dart';
import 'sanitize.dart';
import 'target_data.dart';

/// 画面座標 [position]（[viewId] の View 内）にあるウィジェットから `target` を作る。
///
/// - `WidgetsBinding.hitTestInView` の結果（RenderObject の経路）だけを使う。
///   Widget Inspector や `debugCreator` は使わないため release でも動く。
/// - `TextField` などの入力値（`EditableText` 配下）は読まない。
///   入力欄を指したときはラベルも返さない。
/// - 何も見つからなければ null。
FeedpulseTargetData? resolveTargetAt({
  required Offset position,
  required int viewId,
  FeedpulseTargetLimits limits = const FeedpulseTargetLimits(),
  String? screen,
}) {
  final binding = WidgetsBinding.instance;
  final result = HitTestResult();
  binding.hitTestInView(result, position, viewId);

  final hit = <RenderObject>[
    for (final entry in result.path)
      if (entry.target is RenderObject && entry.target is! RenderView)
        entry.target as RenderObject,
  ];
  if (hit.isEmpty) return null;

  final elements = _elementsFor(binding.rootElement, hit.toSet());
  if (elements.isEmpty) return null;

  // 経路は葉 → 根の順。
  RenderObject? explicit;
  for (final ro in hit) {
    if (ro is RenderFeedpulseTarget && elements.containsKey(ro)) {
      explicit = ro;
      break;
    }
  }

  RenderObject? chosen = explicit;
  if (chosen == null) {
    for (final ro in hit) {
      if (elements.containsKey(ro)) {
        chosen = ro;
        break;
      }
    }
  }
  if (chosen == null) return null;
  final chosenElement = elements[chosen]!;
  final leafElement = elements[hit.firstWhere(elements.containsKey)]!;

  // 入力欄の上ならラベルは一切返さない。
  final sensitive = _hasEditableAncestor(leafElement) ||
      _hasEditableAncestor(chosenElement) ||
      (explicit != null && _containsEditable(chosenElement));

  String? label;
  final allowLabel =
      !sensitive && !(explicit is RenderFeedpulseTarget && !explicit.includeLabel);
  if (allowLabel) {
    label = _findLabel(chosenElement, deep: explicit != null);
    if (label == null && explicit == null) {
      label = _labelFromAncestors(chosenElement);
    }
  }

  final maxPath = math.min(limits.maxPath, FeedpulseTargetLimits.serverMaxPath);
  final id = explicit is RenderFeedpulseTarget
      ? sanitizeTargetString(
          explicit.id,
          math.min(limits.maxId, FeedpulseTargetLimits.serverMaxId),
        )
      : null;
  final path = _buildPath(chosenElement, maxPath);
  // サーバーは id も path も無い target を捨てる。
  if (id == null && path == null) return null;

  return FeedpulseTargetData(
    screen: sanitizeTargetString(
      screen,
      math.min(limits.maxScreen, FeedpulseTargetLimits.serverMaxScreen),
    ),
    id: id,
    path: path,
    rect: _rectOf(chosen),
    label: sanitizeTargetString(
      label,
      math.min(limits.maxLabel, FeedpulseTargetLimits.serverMaxLabel),
    ),
  );
}

Map<RenderObject, Element> _elementsFor(
  Element? root,
  Set<RenderObject> wanted,
) {
  final found = <RenderObject, Element>{};
  if (root == null) return found;
  final stack = <Element>[root];
  while (stack.isNotEmpty && found.length < wanted.length) {
    final element = stack.removeLast();
    if (element is RenderObjectElement && wanted.contains(element.renderObject)) {
      found[element.renderObject] = element;
    }
    element.visitChildren(stack.add);
  }
  return found;
}

bool _hasEditableAncestor(Element element) {
  if (element.widget is EditableText) return true;
  var editable = false;
  element.visitAncestorElements((e) {
    if (e.widget is EditableText) {
      editable = true;
      return false;
    }
    return true;
  });
  return editable;
}

FeedpulseRect? _rectOf(RenderObject ro) {
  if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
  final topLeft = ro.localToGlobal(Offset.zero);
  final rect = FeedpulseRect(
    x: _round(topLeft.dx),
    y: _round(topLeft.dy),
    w: _round(ro.size.width),
    h: _round(ro.size.height),
  );
  // サーバーは |値| > 1,000,000、w/h < 0、非有限の rect を含む target ごと捨てる。
  const m = FeedpulseTargetLimits.serverMaxRectAbs;
  final ok = rect.isFinite &&
      rect.x.abs() <= m &&
      rect.y.abs() <= m &&
      rect.w.abs() <= m &&
      rect.h.abs() <= m &&
      rect.w >= 0 &&
      rect.h >= 0;
  return ok ? rect : null;
}

double _round(double v) => v.isFinite ? (v * 100).roundToDouble() / 100 : v;

String? _labelOf(Widget widget) {
  if (widget is Semantics) {
    final l = widget.properties.label;
    if (l != null && l.trim().isNotEmpty) return l;
  } else if (widget is Text) {
    final t = widget.data ?? widget.textSpan?.toPlainText();
    if (t != null && t.trim().isNotEmpty) return t;
  } else if (widget is Icon) {
    final l = widget.semanticLabel;
    if (l != null && l.trim().isNotEmpty) return l;
  }
  return null;
}

/// [start] 配下（自身を含む）に入力欄があるか。打ち切りなしで調べる。
bool _containsEditable(Element start) {
  final stack = <Element>[start];
  while (stack.isNotEmpty) {
    final e = stack.removeLast();
    if (e.widget is EditableText) return true;
    e.visitChildren(stack.add);
  }
  return false;
}

/// [start] 自身と配下を深さ優先で探す。配下に入力欄があれば null を返す。
String? _findLabel(Element start, {required bool deep}) {
  String? found;
  var sensitive = false;
  var visited = 0;

  void visit(Element e, int depth) {
    if (sensitive || visited++ > 2000) return;
    if (e.widget is EditableText) {
      sensitive = true;
      return;
    }
    found ??= _labelOf(e.widget);
    if (depth >= (deep ? 60 : 6)) return;
    e.visitChildren((c) => visit(c, depth + 1));
  }

  visit(start, 0);
  return sensitive ? null : found;
}

String? _labelFromAncestors(Element start) {
  String? found;
  var level = 0;
  start.visitAncestorElements((e) {
    final l = _labelOf(e.widget);
    if (l != null) {
      found = l;
      return false;
    }
    return ++level < 4;
  });
  return found;
}

String? _keyTag(Widget widget) {
  final key = widget.key;
  if (key is ValueKey) {
    final v = key.value;
    if (v is String || v is num) return '$v';
  }
  return null;
}

String _typeName(Widget widget) {
  final name = widget.runtimeType.toString();
  final tag = _keyTag(widget);
  return tag == null ? name : '$name[$tag]';
}

String? _buildPath(Element chosen, int max) {
  final names = <String>[];
  chosen.visitAncestorElements((e) {
    final w = e.widget;
    final isComponent = e is ComponentElement;
    final isPrivate = w.runtimeType.toString().startsWith('_');
    final tagged = _keyTag(w) != null;
    if (isComponent && (!isPrivate || tagged)) names.add(_typeName(w));
    return names.length < 6;
  });
  final parts = [...names.reversed, _typeName(chosen.widget)];
  var path = parts.join(' > ');
  // 長すぎるときは根側を捨てる（葉に近い方が情報量が多い）。
  if (path.length > max) {
    path = path.substring(path.length - max);
    final first = path.codeUnitAt(0);
    if (first >= 0xDC00 && first <= 0xDFFF) path = path.substring(1);
  }
  return sanitizeTargetString(path, max);
}
