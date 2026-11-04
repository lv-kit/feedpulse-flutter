import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'sanitize.dart';
import 'target_data.dart';
import 'target_resolver.dart';

/// 画面上のウィジェットをタップで選び、[FeedpulseTargetData] を返すピッカー。
///
/// UI は持たない。見えない全面オーバーレイが次のタップを奪い、その座標の
/// ウィジェットを特定して終了する（スクリーンショットは撮らない）。
/// 結果は顧客のフォームが `context.auto.target` として送信に載せる。
///
/// ```dart
/// final picker = FeedpulseTargetPicker();
/// final target = await picker.pick(context); // キャンセルなら null
/// final json = target?.toJson();
/// ```
class FeedpulseTargetPicker {
  FeedpulseTargetPicker({
    this.limits = const FeedpulseTargetLimits(),
    this.screen,
  });

  /// 文字列の長さ上限。ラベルは `limits.maxLabel` 文字まで。
  final FeedpulseTargetLimits limits;

  /// 画面名。null のときは `pick` に渡した context の `ModalRoute` 名を使う。
  final String? screen;

  OverlayEntry? _entry;
  Completer<FeedpulseTargetData?>? _completer;

  bool get isPicking => _completer != null;

  /// 次のタップを待ち、そのウィジェットの `target` を返す。
  /// [cancel] が呼ばれたとき、または何も特定できなかったときは null。
  ///
  /// すでに選択中なら、前の選択をキャンセルして新しく始める。
  Future<FeedpulseTargetData?> pick(BuildContext context) {
    cancel();

    final overlay = Overlay.of(context, rootOverlay: true);
    final viewId = View.of(context).viewId;
    final screenName = screen ?? _routeName(context);
    final completer = Completer<FeedpulseTargetData?>();
    final overlayKey = GlobalKey<_PickerOverlayState>();
    late final OverlayEntry entry;

    void finish(FeedpulseTargetData? data) {
      if (!identical(_completer, completer)) return;
      entry.remove();
      entry.dispose();
      _entry = null;
      _completer = null;
      completer.complete(data);
    }

    entry = OverlayEntry(
      builder: (_) => _PickerOverlay(
        key: overlayKey,
        onTap: (position) {
          FeedpulseTargetData? data;
          try {
            data = overlayKey.currentState!.probe(
              () => resolveTargetAt(
                position: position,
                viewId: viewId,
                limits: limits,
                screen: screenName,
              ),
            );
          } catch (_) {
            data = null;
          }
          finish(data);
        },
      ),
    );

    _entry = entry;
    _completer = completer;
    overlay.insert(entry);
    return completer.future;
  }

  /// 選択を中止する。待機中の [pick] は null で完了する。
  void cancel() {
    final completer = _completer;
    if (completer == null) return;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _completer = null;
    completer.complete(null);
  }

  static String? _routeName(BuildContext context) {
    final name = ModalRoute.of(context)?.settings.name;
    return (name == null || name.isEmpty) ? null : name;
  }
}

class _PickerOverlay extends StatefulWidget {
  const _PickerOverlay({super.key, required this.onTap});

  final void Function(Offset globalPosition) onTap;

  @override
  State<_PickerOverlay> createState() => _PickerOverlayState();
}

class _PickerOverlayState extends State<_PickerOverlay> {
  Offset? _down;
  final GlobalKey _layerKey = GlobalKey();

  /// オーバーレイ自身をヒットテストから外して [body] を実行する。
  T probe<T>(T Function() body) {
    final ro = _layerKey.currentContext?.findRenderObject();
    if (ro is _RenderPassThrough) {
      ro.passThrough = true;
      try {
        return body();
      } finally {
        ro.passThrough = false;
      }
    }
    return body();
  }

  @override
  Widget build(BuildContext context) {
    // 指を離したときに確定する。押下は奪うだけで下のウィジェットへ渡さない。
    return _PassThroughBox(
      key: _layerKey,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _down = e.position,
        onPointerCancel: (_) => _down = null,
        onPointerUp: (e) {
          final down = _down;
          _down = null;
          if (down == null) return;
          widget.onTap(e.position);
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// [_RenderPassThrough.passThrough] が true の間、配下をヒットテストから外す。
class _PassThroughBox extends SingleChildRenderObjectWidget {
  const _PassThroughBox({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPassThrough();
}

class _RenderPassThrough extends RenderProxyBox {
  bool passThrough = false;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (passThrough) return false;
    return super.hitTest(result, position: position);
  }
}
