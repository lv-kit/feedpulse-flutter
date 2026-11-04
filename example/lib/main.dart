import 'package:feedpulse/feedpulse.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

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

  Future<void> _pick() async {
    final target = await _picker.pick(context);
    setState(() => _result = target == null ? 'キャンセル' : '${target.toJson()}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Feedpulse target picker')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FeedpulseTarget(
                id: 'checkout_button',
                child: ElevatedButton(
                  onPressed: () {},
                  child: const Text('購入する'),
                ),
              ),
              const SizedBox(height: 16),
              const FeedpulseTarget(
                id: 'email_field',
                child: TextField(decoration: InputDecoration(labelText: 'Email')),
              ),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _pick, child: const Text('該当箇所を選ぶ')),
              TextButton(onPressed: _picker.cancel, child: const Text('キャンセル')),
              const SizedBox(height: 16),
              Text(_result),
            ],
          ),
        ),
      );
}
