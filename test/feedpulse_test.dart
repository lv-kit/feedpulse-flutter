import 'dart:async';
import 'dart:convert';

import 'package:feedpulse/feedpulse.dart';
import 'package:feedpulse/src/sanitize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _allowedKeys = {'platform', 'screen', 'id', 'path', 'rect', 'label'};

/// #106 の target スキーマ（形のみ）に通るか。
void expectValidTarget(FeedpulseTargetData t, {int maxLabel = 80}) {
  final json = t.toJson();
  expect(_allowedKeys, containsAll(json.keys));
  expect(json['platform'], 'flutter');
  for (final k in ['screen', 'id', 'path', 'label']) {
    if (json.containsKey(k)) expect(json[k], isA<String>());
  }
  if (json['label'] != null) {
    expect((json['label']! as String).runes.length, lessThanOrEqualTo(maxLabel));
  }
  if (json['rect'] != null) {
    final r = json['rect']! as Map<String, Object?>;
    expect(r.keys.toSet(), {'x', 'y', 'w', 'h'});
    for (final v in r.values) {
      expect((v! as double).isFinite, isTrue);
    }
  }
  // JSON 化できる（NaN / Infinity が無い）。
  expect(() => jsonEncode(json), returnsNormally);
}

class _Harness extends StatelessWidget {
  const _Harness({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: children),
      );
}

void main() {
  late FeedpulseTargetPicker picker;
  FeedpulseTargetData? picked;
  var done = false;

  setUp(() {
    picker = FeedpulseTargetPicker();
    picked = null;
    done = false;
  });

  Future<void> startPick(WidgetTester tester) async {
    final ctx = tester.element(find.byType(Scaffold));
    unawaited(picker.pick(ctx).then((v) {
      picked = v;
      done = true;
    }));
    await tester.pump();
  }

  testWidgets('FeedpulseTarget の id が target.id に入る', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(
          id: 'checkout_button',
          child: ElevatedButton(
            onPressed: () => pressed++,
            child: const Text('購入する'),
          ),
        ),
      ]),
    ));

    await startPick(tester);
    expect(picker.isPicking, isTrue);
    await tester.tap(find.text('購入する'));
    await tester.pump();

    expect(done, isTrue);
    expect(picker.isPicking, isFalse);
    expect(pressed, 0, reason: 'ピッカーがタップを奪い、下のボタンは反応しない');
    final t = picked!;
    expect(t.platform, 'flutter');
    expect(t.id, 'checkout_button');
    expect(t.label, '購入する');
    expect(t.rect, isNotNull);
    expect(t.rect!.w, greaterThan(0));
    expect(t.path, endsWith('FeedpulseTarget'));
    expectValidTarget(t);

    // ピッカー終了後は通常どおりタップできる。
    await tester.tap(find.text('購入する'));
    expect(pressed, 1);
  });

  testWidgets('明示 ID が無いとき path / label で補う', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: _Harness(children: [
        Text('ようこそ', key: ValueKey('welcome')),
      ]),
    ));
    await startPick(tester);
    await tester.tap(find.text('ようこそ'));
    await tester.pump();

    final t = picked!;
    expect(t.id, isNull);
    expect(t.label, 'ようこそ');
    expect(t.path, isNotNull);
    expectValidTarget(t);
  });

  testWidgets('Semantics ラベルを使う', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: _Harness(children: [
        Semantics(
          label: '閉じる',
          child: const SizedBox(
            width: 80,
            height: 40,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      ]),
    ));
    await startPick(tester);
    await tester.tapAt(const Offset(40, 20));
    await tester.pump();
    expect(picked!.label, '閉じる');
  });

  testWidgets('ラベルは先頭 N 文字に切る', (tester) async {
    picker = FeedpulseTargetPicker(
      limits: const FeedpulseTargetLimits(maxLabel: 5),
    );
    await tester.pumpWidget(const MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(id: 'long', child: Text('あいうえおかきくけこ')),
      ]),
    ));
    await startPick(tester);
    await tester.tap(find.text('あいうえおかきくけこ'));
    await tester.pump();
    expect(picked!.label, 'あいうえお');
    expectValidTarget(picked!, maxLabel: 5);
  });

  testWidgets('TextField の入力値・obscureText を取得しない', (tester) async {
    final plain = TextEditingController(text: 'my-plain-input-value');
    final secret = TextEditingController(text: 'p@ssw0rd-SECRET');
    await tester.pumpWidget(MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(
          id: 'email_field',
          child: TextField(controller: plain),
        ),
        FeedpulseTarget(
          id: 'password_field',
          child: TextField(controller: secret, obscureText: true),
        ),
        TextField(controller: TextEditingController(text: 'no-id-field-value')),
      ]),
    ));

    final fields = find.byType(TextField);
    for (var i = 0; i < 3; i++) {
      picked = null;
      await startPick(tester);
      await tester.tap(fields.at(i));
      await tester.pump();
      final t = picked!;
      final dump = jsonEncode(t.toJson());
      expect(dump, isNot(contains('my-plain-input-value')));
      expect(dump, isNot(contains('p@ssw0rd')));
      expect(dump, isNot(contains('SECRET')));
      expect(dump, isNot(contains('no-id-field-value')));
      expect(t.label, isNull, reason: '入力欄ではラベルも返さない');
      expectValidTarget(t);
      if (i == 0) expect(t.id, 'email_field');
      if (i == 1) expect(t.id, 'password_field');
    }
  });

  testWidgets('入力欄を含む FeedpulseTarget の周囲を指してもラベルを返さない',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(
          id: 'form',
          child: Column(children: [
            const Text('メールアドレス'),
            TextField(controller: TextEditingController(text: 'secret-value')),
          ]),
        ),
      ]),
    ));
    await startPick(tester);
    await tester.tap(find.text('メールアドレス'));
    await tester.pump();
    expect(picked!.id, 'form');
    expect(picked!.label, isNull);
    expect(jsonEncode(picked!.toJson()), isNot(contains('secret-value')));
  });

  testWidgets('includeLabel: false ならラベルを返さない', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(id: 'x', includeLabel: false, child: Text('非公開')),
      ]),
    ));
    await startPick(tester);
    await tester.tap(find.text('非公開'));
    await tester.pump();
    expect(picked!.id, 'x');
    expect(picked!.label, isNull);
  });

  testWidgets('cancel() で null を返しオーバーレイを外す', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Harness(children: [
        ElevatedButton(onPressed: () => pressed++, child: const Text('go')),
      ]),
    ));
    await startPick(tester);
    picker.cancel();
    await tester.pump();
    expect(done, isTrue);
    expect(picked, isNull);
    expect(picker.isPicking, isFalse);
    await tester.tap(find.text('go'));
    expect(pressed, 1);
  });

  testWidgets('画面名: 引数が無ければ ModalRoute の名前', (tester) async {
    await tester.pumpWidget(MaterialApp(
      initialRoute: '/checkout',
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const _Harness(children: [
          FeedpulseTarget(id: 'a', child: Text('A')),
        ]),
      ),
    ));
    await startPick(tester);
    await tester.tap(find.text('A'));
    await tester.pump();
    expect(picked!.screen, '/checkout');
  });

  testWidgets('画面名: 顧客が渡した名前を優先', (tester) async {
    picker = FeedpulseTargetPicker(screen: 'CheckoutScreen');
    await tester.pumpWidget(const MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(id: 'a', child: Text('A')),
      ]),
    ));
    await startPick(tester);
    await tester.tap(find.text('A'));
    await tester.pump();
    expect(picked!.screen, 'CheckoutScreen');
  });

  testWidgets('再度 pick するとき前の選択はキャンセルされる', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: _Harness(children: [
        FeedpulseTarget(id: 'a', child: Text('A')),
      ]),
    ));
    final ctx = tester.element(find.byType(Scaffold));
    final first = picker.pick(ctx);
    await tester.pump();
    final second = picker.pick(ctx);
    await tester.pump();
    expect(await first, isNull);
    await tester.tap(find.text('A'));
    await tester.pump();
    expect((await second)!.id, 'a');
  });

  group('サーバー上限（#106）', () {
    test('既定の上限は web TARGET_LIMITS と同じ', () {
      const l = FeedpulseTargetLimits();
      expect(l.maxScreen, 512);
      expect(l.maxId, 128);
      expect(l.maxPath, 512);
      expect(FeedpulseTargetLimits.serverMaxLabel, 200);
      expect(FeedpulseTargetLimits.serverMaxRectAbs, 1000000);
    });

    testWidgets('上限を超える設定でもサーバー上限に収める', (tester) async {
      picker = FeedpulseTargetPicker(
        limits: const FeedpulseTargetLimits(
          maxLabel: 1000,
          maxId: 1000,
          maxPath: 1000,
          maxScreen: 1000,
        ),
        screen: 's' * 600,
      );
      await tester.pumpWidget(MaterialApp(
        home: _Harness(children: [
          FeedpulseTarget(id: 'i' * 300, child: Text('l' * 300)),
        ]),
      ));
      await startPick(tester);
      await tester.tap(find.byType(Text).first);
      await tester.pump();
      final t = picked!;
      expect(t.id!.length, 128);
      expect(t.label!.length, 200);
      expect(t.screen!.length, 512);
      expect(t.path!.length, lessThanOrEqualTo(512));
      expect(t.platform, 'flutter');
    });

    test('UTF-16 長で切る（サロゲートペアを割らない）', () {
      final out = sanitizeTargetString('😀' * 5, 5)!;
      expect(out.length, 4);
      expect(out, '😀😀');
    });
  });

  group('sanitizeTargetString', () {
    test('制御文字を除き空白を畳み rune 単位で切る', () {
      expect(sanitizeTargetString('a\u0000b\n\tc', 10), 'a b c');
      expect(sanitizeTargetString('😀😀😀😀', 4), '😀😀');
      expect(sanitizeTargetString('   ', 5), isNull);
      expect(sanitizeTargetString(null, 5), isNull);
    });
  });

  group('FeedpulseTargetData.toJson', () {
    test('直接指定された ID もサーバー上限に収める', () {
      final target = FeedpulseTargetData(id: '${'a' * 127}😀', label: 'label');
      final json = target.toJson();
      expect(json['id'], 'a' * 127);
      expect(json['label'], 'label');
      expect(FeedpulseTargetData(id: '  a  b\nc  ').toJson()['id'], 'a  bc');
      expect(FeedpulseTargetData(id: '${'a' * 126}😀').toJson()['id'], '${'a' * 126}😀');
    });
    test('null を含めず rect は x/y/w/h', () {
      const t = FeedpulseTargetData(
        id: 'a',
        rect: FeedpulseRect(x: 1, y: 2, w: 3, h: 4),
      );
      expect(t.toJson(), {
        'platform': 'flutter',
        'id': 'a',
        'rect': {'x': 1.0, 'y': 2.0, 'w': 3.0, 'h': 4.0},
      });
    });
  });
}
