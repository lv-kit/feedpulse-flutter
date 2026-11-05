import 'package:feedpulse/feedpulse.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 自分のプロジェクトの公開鍵（pk_...）に置き換える。アプリの登録が必要。
  Feedpulse.configure(publicKey: 'pk_your_public_key');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = FeedpulseTargetPicker();
  String _result = '（未選択）';
  FeedpulseTargetData? _target;

  Future<void> _pick() async {
    final target = await _picker.pick(context);
    setState(() {
      _target = target;
      _result = target == null ? 'キャンセル' : '${target.toJson()}';
    });
  }

  /// config 取得 → 入力検証 → 送信。失敗は FeedpulseException。
  Future<void> _send() async {
    try {
      final config = await Feedpulse.refreshConfig();
      final form = config.form('bug');
      if (form == null) {
        setState(() => _result = "slug 'bug' のフォームが無い");
        return;
      }
      final receipt = await Feedpulse.submit(
        formId: form.id,
        fields: {'title': 'サンプルからの送信'},
        target: _target,
      );
      setState(() => _result = '送信済み: ${receipt.id}');
    } on FeedpulseException catch (e) {
      setState(() => _result = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Feedpulse')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FeedpulseTarget(
            id: 'checkout_button',
            child: ElevatedButton(onPressed: () {}, child: const Text('購入する')),
          ),
          const SizedBox(height: 16),
          const FeedpulseTarget(
            id: 'email_field',
            child: TextField(decoration: InputDecoration(labelText: 'Email')),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _pick, child: const Text('該当箇所を選ぶ')),
          TextButton(onPressed: _picker.cancel, child: const Text('キャンセル')),
          FilledButton(onPressed: _send, child: const Text('送信')),
          const SizedBox(height: 16),
          Text(_result),
        ],
      ),
    ),
  );
}
