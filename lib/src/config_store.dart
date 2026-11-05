import 'package:flutter/services.dart';

/// config のローカル保存。
abstract interface class ConfigStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// プロセス内だけに持つ実装（テスト用・ネイティブ非対応環境用）。
class MemoryConfigStore implements ConfigStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

/// ネイティブの永続ストア（iOS: UserDefaults、Android: SharedPreferences）。
/// 読み書きの失敗は握りつぶす（キャッシュなので無くても動く）。
class NativeConfigStore implements ConfigStore {
  NativeConfigStore({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('dev.feedpulse/native');

  final MethodChannel channel;

  @override
  Future<String?> read(String key) async {
    try {
      return await channel.invokeMethod<String>('storeRead', {'key': key});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await channel.invokeMethod<void>('storeWrite', {
        'key': key,
        'value': value,
      });
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }
}
