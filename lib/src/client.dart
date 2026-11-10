import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'attestor.dart';
import 'config_store.dart';
import 'errors.dart';
import 'form_validator.dart';
import 'models.dart';
import 'target_data.dart';
import 'transport.dart';

/// 再送の設定。待ち時間は `baseDelay * 2^回数`。429 の `Retry-After` があればそちらを優先（[maxDelay] で頭打ち）。
class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 3,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 120),
  });

  final int maxRetries;
  final Duration baseDelay;
  final Duration maxDelay;
}

final _idempotencyKey = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// 期限のこの秒数前になったらセッションを取り直す。
const _sessionRefreshMarginSeconds = 60;

String _randomIdempotencyKey() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class _Session {
  _Session(this.token, this.expiresAtSeconds);
  final String token;
  final int expiresAtSeconds;
}

/// Feedpulse のヘッドレスクライアント。通常は `Feedpulse.configure` で作る。
///
/// 失敗は [FeedpulseException]。
class FeedpulseClient {
  FeedpulseClient({
    required this.publicKey,
    required this.baseUrl,
    AppAttestor? attestor,
    FeedpulseTransport? transport,
    ConfigStore? store,
    this.retryPolicy = const RetryPolicy(),
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    String Function()? newIdempotencyKey,
    Map<String, String> Function(AppEnvironment env)? deviceContext,
  }) : _attestor = attestor ?? NativeAppAttestor(),
       _transport = transport ?? IoFeedpulseTransport(),
       _store = store ?? NativeConfigStore(),
       _now = now ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       _newKey = newIdempotencyKey ?? _randomIdempotencyKey,
       _deviceContext = deviceContext ?? _defaultDeviceContext,
       _base = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl;

  final String publicKey;
  final String baseUrl;
  final RetryPolicy retryPolicy;
  final AppAttestor _attestor;
  final FeedpulseTransport _transport;
  final ConfigStore _store;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;
  final String Function() _newKey;
  final Map<String, String> Function(AppEnvironment env) _deviceContext;
  final String _base;

  _Session? _session;
  Future<String>? _sessionInFlight;
  AppEnvironment? _env;
  String? _identityToken;
  FeedpulseConfig? _config;
  FeedpulseException? _lastError;
  Future<void>? _cacheLoad;

  String get _cacheKey => 'config|$_base|$publicKey';

  /// 直近の config。保存値から復元したものや通信失敗後の前回値は `isStale == true`。
  /// 未取得なら null（保存値の読み込みは最初の [refreshConfig] / [submit] / [loadCachedConfig] で行う）。
  FeedpulseConfig? get config => _config;

  /// 直近の通信エラー。成功すると null に戻る。
  FeedpulseException? get lastError => _lastError;

  /// 身元確認トークン（顧客バックエンドが `sk_` で署名した JWT）を設定する。
  /// SDK は検証せず `context.identity` にそのまま載せる。null か空文字で解除。
  void identify(String? token) {
    _identityToken = (token == null || token.trim().isEmpty) ? null : token;
  }

  /// 保存済みの config を読む（通信しない）。無ければ null。
  Future<FeedpulseConfig?> loadCachedConfig() async {
    await _ensureCacheLoaded();
    return _config;
  }

  /// 保存値の読み込みは一度だけ行う。ただし読み込み自体が失敗したときは
  /// Future を捨て、次の呼び出しで再試行する（キャッシュの一時障害で止まらない）。
  Future<void> _ensureCacheLoaded() => _cacheLoad ??= () async {
    if (_config != null) return;
    final String? text;
    try {
      text = await _store.read(_cacheKey);
    } catch (_) {
      _cacheLoad = null;
      return;
    }
    if (text == null) return;
    try {
      final o = jsonDecode(text) as Map<String, Object?>;
      _config ??= FeedpulseConfig(
        forms: [
          for (final f in o['forms']! as List)
            FeedpulseForm.fromJson((f as Map).cast<String, Object?>()),
        ],
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          (o['fetchedAt']! as num).toInt(),
        ),
        isStale: true,
      );
    } catch (_) {
      // 壊れた保存値はキャッシュ無し扱い。
    }
  }();

  /// `GET /v1/config` を取りに行く。通信に失敗したら前回値（`isStale == true`）を返し、
  /// 前回値も無ければ例外。
  Future<FeedpulseConfig> refreshConfig() async {
    await _ensureCacheLoaded();
    try {
      final res = await _authed(
        'GET',
        '/v1/config?pk=${Uri.encodeQueryComponent(publicKey)}',
        null,
      );
      final json = _parseObject(res.body);
      final List<FeedpulseForm> forms;
      try {
        forms = [
          for (final f in json['forms']! as List)
            FeedpulseForm.fromJson((f as Map).cast<String, Object?>()),
        ];
      } catch (e) {
        throw FeedpulseException(
          FeedpulseErrorCode.unexpectedResponse,
          message: 'config を解釈できない: $e',
          cause: e,
        );
      }
      final fresh = FeedpulseConfig(forms: forms, fetchedAt: _now());
      _config = fresh;
      _lastError = null;
      try {
        await _store.write(
          _cacheKey,
          jsonEncode({
            'fetchedAt': fresh.fetchedAt.millisecondsSinceEpoch,
            'forms': [for (final f in forms) f.toJson()],
          }),
        );
      } catch (_) {
        // 保存に失敗しても取得済みの config は返す（キャッシュなので無くても動く）。
      }
      return fresh;
    } on FeedpulseException catch (e) {
      _lastError = e;
      final cached = _config;
      if (cached != null) return _config = cached.asStale();
      rethrow;
    }
  }

  /// フィードバックを送る。
  ///
  /// 1. 項目定義（未取得なら [refreshConfig]）で [fields] を検証し、不正なら送らず
  ///    [FeedpulseErrorCode.invalidFields] を投げる。
  /// 2. 冪等キーを付けて `POST /v1/submit`。通信失敗・429・5xx は [RetryPolicy] に従い
  ///    同じキーで再送する。
  ///
  /// - [formId]: `forms[].id`。
  /// - [fields]: ブロック ID → 値（型は `validateFields` の説明を参照）。
  /// - [target]: ピッカーの結果。フォームが `allowTarget` のときだけ `context.auto.target` に載せる。
  /// - [custom]: `context.custom`（値は String / 有限の num / bool）。
  /// - [idempotencyKey]: 省略すると SDK が生成。アプリ側で再送を管理するときは同じ値を渡す
  ///   （`^[A-Za-z0-9_-]{16,64}$`）。
  Future<SubmitReceipt> submit({
    required String formId,
    required Map<String, Object?> fields,
    FeedpulseTargetData? target,
    Map<String, Object>? custom,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? _newKey();
    if (!_idempotencyKey.hasMatch(key)) {
      throw const FeedpulseException(
        FeedpulseErrorCode.invalidIdempotencyKey,
        message: r'idempotencyKey は ^[A-Za-z0-9_-]{16,64}$',
      );
    }
    final sendFields = <String, Object?>{
      for (final e in fields.entries)
        if (e.value != null &&
            !(e.value is String && (e.value! as String).trim().isEmpty))
          e.key: e.value,
    };
    if (custom != null) {
      for (final v in custom.values) {
        final ok = v is String || v is bool || (v is num && v.isFinite);
        if (!ok) {
          throw const FeedpulseException(
            FeedpulseErrorCode.notConfigured,
            message: 'custom の値は String / 有限の num / bool のみ',
          );
        }
      }
    }

    await _ensureCacheLoaded();
    var current = _config;
    var form = current?.formById(formId);
    if (form == null) {
      current = await refreshConfig();
      form = current.formById(formId);
    }
    if (form == null) {
      throw FeedpulseException(
        FeedpulseErrorCode.unknownForm,
        message: 'formId=$formId は config に無い',
      );
    }
    var errors = validateFields(form, sendFields);
    if (errors.isNotEmpty && current?.isStale == true) {
      // 古い保存値で弾かない。最新の定義を取り直して検証し直す（取れなければ古い定義のまま）。
      form = (await refreshConfig()).formById(formId) ?? form;
      errors = validateFields(form, sendFields);
    }
    if (errors.isNotEmpty) {
      throw FeedpulseException(
        FeedpulseErrorCode.invalidFields,
        message: '入力が不正',
        fieldErrors: errors,
      );
    }

    final env = await _environment();
    final auto = <String, Object?>{..._deviceContext(env)};
    if (target != null && form.allowTarget) auto['target'] = target.toJson();
    final context = <String, Object?>{
      'auto': auto,
      if (custom != null && custom.isNotEmpty) 'custom': custom,
      if (_identityToken != null) 'identity': _identityToken,
    };
    final body = jsonEncode({
      'formId': formId,
      'idempotencyKey': key,
      'fields': sendFields,
      'context': context,
    });

    var attempt = 0;
    while (true) {
      try {
        final res = await _authed('POST', '/v1/submit', body);
        final id = _parseObject(res.body)['id'];
        if (id is! String || id.isEmpty) {
          throw FeedpulseException(
            FeedpulseErrorCode.unexpectedResponse,
            message: 'submit の応答に id が無い',
            httpStatus: res.status,
          );
        }
        _lastError = null;
        return SubmitReceipt(id);
      } on FeedpulseException catch (e) {
        if (!e.isRetryable || attempt >= retryPolicy.maxRetries) {
          _lastError = e;
          rethrow;
        }
        final wait = e.retryAfterSeconds != null
            ? Duration(seconds: e.retryAfterSeconds!)
            : retryPolicy.baseDelay * (1 << attempt);
        await _sleep(wait > retryPolicy.maxDelay ? retryPolicy.maxDelay : wait);
        attempt++;
      }
    }
  }

  // ---- セッション ----

  Future<AppEnvironment> _environment() async =>
      _env ??= await _attestor.environment();

  Future<String> _ensureSession({required bool forceNew}) {
    final cur = _session;
    if (!forceNew &&
        cur != null &&
        _now().millisecondsSinceEpoch ~/ 1000 <
            cur.expiresAtSeconds - _sessionRefreshMarginSeconds) {
      return Future.value(cur.token);
    }
    // 同時呼び出しは 1 回の取得にまとめる（challenge は 1 回限りなので並行させない）。
    final inFlight = _sessionInFlight;
    if (inFlight != null) return inFlight;
    final f = _openSessionWithRecovery();
    _sessionInFlight = f;
    return f.whenComplete(() => _sessionInFlight = null);
  }

  Future<String> _openSessionWithRecovery() async {
    _session = null;
    try {
      return await _openSession();
    } on FeedpulseException catch (e) {
      // challenge の期限切れ（端末が遅い等）は取り直して 1 回だけやり直す。
      if (e.code != FeedpulseErrorCode.challengeExpired &&
          e.code != FeedpulseErrorCode.invalidChallenge) {
        rethrow;
      }
      return _openSession();
    }
  }

  Future<String> _openSession({bool retryOnStaleKey = true}) async {
    final env = await _environment();
    final ch = await _call(
      'POST',
      '/v1/native/challenge',
      jsonEncode({'pk': publicKey}),
      null,
      env,
    );
    final challenge = _parseObject(ch.body)['challenge'];
    if (challenge is! String || challenge.isEmpty) {
      throw FeedpulseException(
        FeedpulseErrorCode.unexpectedResponse,
        message: 'challenge の応答が不正',
        httpStatus: ch.status,
      );
    }
    final attestation = await _attestor.attest(challenge);
    final FeedpulseResponse res;
    try {
      res = await _call(
        'POST',
        '/v1/native/session',
        jsonEncode({
          'pk': publicKey,
          'platform': env.platform,
          'appId': env.appId,
          'challenge': challenge,
          'attestation': attestation,
        }),
        null,
        env,
      );
    } on FeedpulseException catch (e) {
      if (e.code == FeedpulseErrorCode.attestationFailed) {
        // iOS: サーバーが知らない鍵 ID を使い続けないよう、保存した鍵を捨てる。
        await _attestor.reset();
        // 保存していた鍵がサーバーに無い（前回の attestation が届かなかった等）。
        // 新しい challenge で鍵を作り直して 1 回だけやり直す。
        if (retryOnStaleKey && attestation['type'] == 'app_attest_assertion') {
          return _openSession(retryOnStaleKey: false);
        }
      }
      rethrow;
    }
    final json = _parseObject(res.body);
    final jwt = json['session'];
    final exp = json['expiresAt'];
    if (jwt is! String || jwt.isEmpty || exp is! num) {
      throw FeedpulseException(
        FeedpulseErrorCode.unexpectedResponse,
        message: 'session の応答が不正',
        httpStatus: res.status,
      );
    }
    _session = _Session(jwt, exp.toInt());
    await _attestor.commit();
    return jwt;
  }

  /// セッション付きの呼び出し。`invalid_session` なら取り直して 1 回だけやり直す。
  Future<FeedpulseResponse> _authed(
    String method,
    String pathAndQuery,
    String? body,
  ) async {
    final env = await _environment();
    var refreshed = false;
    var forceNew = false;
    while (true) {
      final token = await _ensureSession(forceNew: forceNew);
      try {
        return await _call(method, pathAndQuery, body, token, env);
      } on FeedpulseException catch (e) {
        switch (e.code) {
          case FeedpulseErrorCode.invalidSession:
            _session = null;
            if (refreshed) rethrow;
            refreshed = true;
            forceNew = true;
          case FeedpulseErrorCode.appNotRegistered ||
              FeedpulseErrorCode.attestationFailed:
            _session = null;
            rethrow;
          default:
            rethrow;
        }
      }
    }
  }

  Future<FeedpulseResponse> _call(
    String method,
    String pathAndQuery,
    String? body,
    String? token,
    AppEnvironment env,
  ) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (token != null) {
      headers['X-FeedPulse-Platform'] = env.platform;
      headers['Authorization'] = 'Bearer $token';
    }
    final FeedpulseResponse res;
    try {
      res = await _transport.send(
        FeedpulseRequest(
          method,
          Uri.parse('$_base$pathAndQuery'),
          headers,
          body,
        ),
      );
    } on IOException catch (e) {
      throw FeedpulseException(
        FeedpulseErrorCode.network,
        message: '通信に失敗: $e',
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw FeedpulseException(
        FeedpulseErrorCode.network,
        message: '通信がタイムアウト',
        cause: e,
      );
    } on FormatException catch (e) {
      throw FeedpulseException(
        FeedpulseErrorCode.unexpectedResponse,
        message: '応答を UTF-8 として読めない',
        cause: e,
      );
    }
    if (res.status >= 200 && res.status < 300) return res;
    throw _toException(res);
  }

  FeedpulseException _toException(FeedpulseResponse res) {
    Map<String, Object?>? json;
    try {
      final d = jsonDecode(res.body);
      if (d is Map) json = d.cast<String, Object?>();
    } catch (_) {}
    final code =
        FeedpulseErrorCode.fromWire(json?['error']) ??
        (res.status >= 500
            ? FeedpulseErrorCode.internal
            : FeedpulseErrorCode.unexpectedResponse);
    final fields = <String, FieldErrorCode>{};
    final f = json?['fields'];
    if (f is Map) {
      for (final e in f.entries) {
        final c = FieldErrorCode.fromWire(e.value);
        if (c != null) fields['${e.key}'] = c;
      }
    }
    final retry = int.tryParse(res.headers['retry-after']?.trim() ?? '');
    final idCode = json?['code'];
    return FeedpulseException(
      code,
      httpStatus: res.status,
      fieldErrors: fields,
      identityCode: idCode is String && idCode.isNotEmpty ? idCode : null,
      retryAfterSeconds: retry != null && retry >= 0 ? retry : null,
    );
  }

  Map<String, Object?> _parseObject(String text) {
    try {
      final d = jsonDecode(text);
      if (d is Map) return d.cast<String, Object?>();
    } catch (_) {}
    throw const FeedpulseException(
      FeedpulseErrorCode.unexpectedResponse,
      message: 'JSON オブジェクトを解釈できない',
    );
  }
}

Map<String, String> _defaultDeviceContext(AppEnvironment env) => {
  'os': env.os,
  'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
  'timezone': env.timezone,
};
