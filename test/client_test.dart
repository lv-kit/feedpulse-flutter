import 'dart:convert';
import 'dart:io';

import 'package:feedpulse/feedpulse.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// web の契約 fixture（packages/shared/src/native/fixtures/contract.json）を読む。
final Map<String, Map<String, Object?>> fixtures = {
  for (final f
      in (jsonDecode(File('test/fixtures/contract.json').readAsStringSync())
              as Map)['fixtures']
          as List)
    (f as Map)['name'] as String: f.cast<String, Object?>(),
};

Map<String, Object?> req(String n) =>
    (fixtures[n]!['request']! as Map).cast<String, Object?>();
Map<String, Object?> res(String n) =>
    (fixtures[n]!['response']! as Map).cast<String, Object?>();

/// fixture の期待 body と実際の body を比べる。`{{...}}` は任意の文字列に一致。
void expectBodyMatches(Object? expected, Object? actual, [String path = r'$']) {
  if (expected is String && expected.startsWith('{{')) {
    expect(actual, isA<String>(), reason: path);
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final a = actual! as Map;
    for (final e in expected.entries) {
      expect(a.containsKey(e.key), isTrue, reason: '$path.${e.key}');
      expectBodyMatches(e.value, a[e.key], '$path.${e.key}');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

FeedpulseResponse fxResponse(String name) {
  final r = res(name);
  final headers = {
    for (final e in ((r['headers'] as Map?) ?? {}).entries)
      '${e.key}'.toLowerCase(): '${e.value}',
  };
  return FeedpulseResponse(r['status']! as int, headers, jsonEncode(r['body']));
}

class FakeAttestor implements AppAttestor {
  FakeAttestor(this.platform, this.attestation);
  final String platform;
  Map<String, Object?> attestation;
  int attests = 0;
  int resets = 0;
  int commits = 0;
  final List<String> challenges = [];

  @override
  Future<AppEnvironment> environment() async => AppEnvironment(
    platform: platform,
    appId: 'com.example.app',
    os: platform == 'ios' ? 'iOS 18.1' : 'Android 15',
    timezone: 'Asia/Tokyo',
  );

  @override
  Future<Map<String, Object?>> attest(String challenge) async {
    attests++;
    challenges.add(challenge);
    return attestation;
  }

  @override
  Future<void> commit() async => commits++;

  @override
  Future<void> reset() async => resets++;
}

class Call {
  Call(this.request);
  final FeedpulseRequest request;
  Map<String, Object?> get json =>
      (jsonDecode(request.body!) as Map).cast<String, Object?>();
}

/// (method, path) ごとに応答を順番に返す偽サーバー。応答が尽きたら最後の値を繰り返す。
class FakeServer implements FeedpulseTransport {
  final Map<String, List<Object>> routes = {};
  final List<Call> calls = [];

  void on(String route, Object response) =>
      (routes[route] ??= []).add(response);

  List<Call> to(String route) => [
    for (final c in calls)
      if ('${c.request.method} ${c.request.url.path}' == route) c,
  ];

  @override
  Future<FeedpulseResponse> send(FeedpulseRequest request) async {
    calls.add(Call(request));
    final key = '${request.method} ${request.url.path}';
    final q = routes[key];
    if (q == null) fail('想定外のリクエスト: $key');
    final r = q.length > 1 ? q.removeAt(0) : q.first;
    if (r is Exception) throw r;
    return r as FeedpulseResponse;
  }
}

const sessionRoute = 'POST /v1/native/session';
const challengeRoute = 'POST /v1/native/challenge';
const configRoute = 'GET /v1/config';
const submitRoute = 'POST /v1/submit';
const formId = '6f1d2c3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f';

FakeServer happyServer({String session = 'session-ok-play-integrity'}) =>
    FakeServer()
      ..on(challengeRoute, fxResponse('challenge-ok'))
      ..on(sessionRoute, fxResponse(session))
      ..on(configRoute, fxResponse('config-ok'))
      ..on(submitRoute, fxResponse('submit-ok'));

({
  FeedpulseClient client,
  FakeServer server,
  FakeAttestor attestor,
  List<Duration> sleeps,
  MemoryConfigStore store,
  DateTime Function() clock,
  void Function(Duration) advance,
})
make({
  String platform = 'android',
  FakeServer? server,
  FakeAttestor? attestor,
  MemoryConfigStore? store,
  String? Function()? keys,
}) {
  final s = server ?? happyServer();
  final a =
      attestor ??
      FakeAttestor(platform, {
        'type': 'play_integrity',
        'token': 'integrity-token',
      });
  final st = store ?? MemoryConfigStore();
  final sleeps = <Duration>[];
  var t = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
  var n = 0;
  final c = FeedpulseClient(
    publicKey: 'pk_example',
    baseUrl: 'https://ingest.example.test/',
    attestor: a,
    transport: s,
    store: st,
    now: () => t,
    sleep: (d) async => sleeps.add(d),
    newIdempotencyKey: () => 'k3FvQ2mT9xLw8Rz${n++}',
  );
  return (
    client: c,
    server: s,
    attestor: a,
    sleeps: sleeps,
    store: st,
    clock: () => t,
    advance: (d) => t = t.add(d),
  );
}

void main() {
  cacheRecoveryTests();
  group('contract: session', () {
    test(
      'android: challenge → play_integrity → session、リクエストが fixture に適合',
      () async {
        final h = make();
        await h.client.refreshConfig();
        final ch = h.server.to(challengeRoute).single;
        expectBodyMatches(req('challenge-ok')['body'], ch.json);
        expect(ch.request.headers.containsKey('Origin'), isFalse);
        expect(ch.request.headers.containsKey('X-FeedPulse-Platform'), isFalse);

        final se = h.server.to(sessionRoute).single;
        expectBodyMatches(req('session-ok-play-integrity')['body'], se.json);
        expect(h.attestor.challenges.single, se.json['challenge']);
        expect(h.attestor.commits, 1);

        final cfg = h.server.to(configRoute).single.request;
        expect(
          cfg.url.toString(),
          'https://ingest.example.test/v1/config?pk=pk_example',
        );
        expect(cfg.headers['X-FeedPulse-Platform'], 'android');
        expect(cfg.headers['Authorization'], startsWith('Bearer eyJ'));
        expect(
          cfg.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('origin')),
        );
      },
    );

    test(
      'ios: attestation / assertion をそのまま session に送り、platform=ios',
      () async {
        for (final fx in [
          'session-ok-app-attest-attestation',
          'session-ok-app-attest-assertion',
        ]) {
          final att = ((req(fx)['body']! as Map)['attestation'] as Map)
              .cast<String, Object?>();
          final h = make(
            platform: 'ios',
            attestor: FakeAttestor('ios', att),
            server: happyServer(session: fx),
          );
          await h.client.refreshConfig();
          expectBodyMatches(
            req(fx)['body'],
            h.server.to(sessionRoute).single.json,
          );
          expect(
            h.server
                .to(configRoute)
                .single
                .request
                .headers['X-FeedPulse-Platform'],
            'ios',
          );
        }
      },
    );

    test('セッションは 900 秒キャッシュし、期限の 60 秒前に更新', () async {
      final h = make();
      await h.client.refreshConfig();
      await h.client.refreshConfig();
      expect(h.server.to(sessionRoute), hasLength(1));
      // expiresAt=1700000900。1700000839 はまだ有効、1700000840 で更新。
      h.advance(const Duration(seconds: 839));
      await h.client.refreshConfig();
      expect(h.server.to(sessionRoute), hasLength(1));
      h.advance(const Duration(seconds: 1));
      await h.client.refreshConfig();
      expect(h.server.to(sessionRoute), hasLength(2));
      expect(h.server.to(challengeRoute), hasLength(2));
    });

    test('端末時計が進んでいてもサーバー時刻で期限を判定する', () async {
      final base = fxResponse('session-ok-play-integrity');
      final server = happyServer()
        ..routes[sessionRoute] = [
          FeedpulseResponse(base.status, {
            'date': HttpDate.format(
              DateTime.fromMillisecondsSinceEpoch(
                1700000000 * 1000,
                isUtc: true,
              ),
            ),
          }, base.body),
        ];
      final h = make(server: server);
      h.advance(const Duration(days: 1));
      await h.client.refreshConfig();
      await h.client.refreshConfig();
      expect(h.server.to(sessionRoute), hasLength(1));
      h.advance(const Duration(seconds: 840));
      await h.client.refreshConfig();
      expect(h.server.to(sessionRoute), hasLength(2));
    });

    test('同時呼び出しでも session は 1 回だけ取る', () async {
      final h = make();
      await Future.wait([h.client.refreshConfig(), h.client.refreshConfig()]);
      expect(h.server.to(sessionRoute), hasLength(1));
    });

    test('invalid_session → 取り直して 1 回だけやり直す', () async {
      final server = FakeServer()
        ..on(challengeRoute, fxResponse('challenge-ok'))
        ..on(sessionRoute, fxResponse('session-ok-play-integrity'))
        ..on(configRoute, fxResponse('config-session-expired'))
        ..on(configRoute, fxResponse('config-ok'));
      final h = make(server: server);
      final cfg = await h.client.refreshConfig();
      expect(cfg.isStale, isFalse);
      expect(server.to(sessionRoute), hasLength(2));
    });

    test('challenge_expired → challenge を取り直して 1 回やり直す', () async {
      final server = FakeServer()
        ..on(challengeRoute, fxResponse('challenge-ok'))
        ..on(sessionRoute, fxResponse('session-challenge-expired'))
        ..on(sessionRoute, fxResponse('session-ok-play-integrity'))
        ..on(configRoute, fxResponse('config-ok'));
      final h = make(server: server);
      await h.client.refreshConfig();
      expect(server.to(challengeRoute), hasLength(2));
      expect(h.attestor.attests, 2);
    });

    test('attestation_failed → リトライせず例外、attestor.reset を呼ぶ', () async {
      final server = FakeServer()
        ..on(challengeRoute, fxResponse('challenge-ok'))
        ..on(sessionRoute, fxResponse('session-attestation-failed'));
      final h = make(server: server);
      await expectLater(
        h.client.refreshConfig(),
        throwsA(
          isA<FeedpulseException>()
              .having(
                (e) => e.code,
                'code',
                FeedpulseErrorCode.attestationFailed,
              )
              .having((e) => e.httpStatus, 'status', 403),
        ),
      );
      expect(h.attestor.attests, 1);
      expect(h.attestor.resets, 1);
      expect(h.attestor.commits, 0);
    });

    test(
      'ios: 保存済み鍵の assertion が attestation_failed なら鍵を捨てて 1 回だけ作り直す',
      () async {
        final server = FakeServer()
          ..on(challengeRoute, fxResponse('challenge-ok'))
          ..on(sessionRoute, fxResponse('session-attestation-failed'))
          ..on(sessionRoute, fxResponse('session-ok-app-attest-attestation'))
          ..on(configRoute, fxResponse('config-ok'));
        final h = make(
          platform: 'ios',
          server: server,
          attestor: FakeAttestor('ios', {
            'type': 'app_attest_assertion',
            'keyId': 'a2V5SWQ=',
            'assertion': 'YXNzZXJ0aW9u',
          }),
        );
        await h.client.refreshConfig();
        expect(h.attestor.resets, 1);
        expect(server.to(sessionRoute), hasLength(2));
      },
    );

    test('app_not_registered は例外、取得済みセッションを捨てる', () async {
      final server = happyServer()
        ..routes[submitRoute] = [fxResponse('submit-app-not-registered')];
      final h = make(server: server);
      await h.client.refreshConfig();
      await expectLater(
        h.client.submit(
          formId: formId,
          fields: {'title': 't', 'severity': 'low'},
        ),
        throwsA(
          isA<FeedpulseException>().having(
            (e) => e.code,
            'code',
            FeedpulseErrorCode.appNotRegistered,
          ),
        ),
      );
      await h.client.refreshConfig();
      expect(server.to(sessionRoute), hasLength(2));
    });
  });

  group('contract: config', () {
    test('forms をパースして保存、失敗時は前回値（isStale）', () async {
      final h = make();
      final cfg = await h.client.refreshConfig();
      expect(cfg.isStale, isFalse);
      expect(cfg.form('bug')!.version, 3);
      expect(cfg.form('bug')!.allowTarget, isTrue);
      expect(cfg.formById(formId)!.blocks.map((b) => b.id), [
        'title',
        'body',
        'severity',
      ]);
      expect(cfg.formById(formId)!.blocks.last.options.map((o) => o.value), [
        'low',
        'high',
      ]);

      h.server.routes[configRoute] = [fxResponse('config-rate-limited')];
      final stale = await h.client.refreshConfig();
      expect(stale.isStale, isTrue);
      expect(stale.form('bug'), isNotNull);
      expect(h.client.lastError!.code, FeedpulseErrorCode.rateLimited);
      expect(h.client.lastError!.retryAfterSeconds, 30);
    });

    test('新しい client でも保存値から復元（isStale）、通信不能でも返る', () async {
      final h = make();
      await h.client.refreshConfig();
      final server = FakeServer()
        ..on(challengeRoute, const SocketException('offline'));
      final h2 = make(server: server, store: h.store);
      final cfg = await h2.client.refreshConfig();
      expect(cfg.isStale, isTrue);
      expect(cfg.form('bug'), isNotNull);
      expect(h2.client.lastError!.code, FeedpulseErrorCode.network);
    });

    test('前回値も無く失敗したら例外', () async {
      final server = FakeServer()
        ..on(challengeRoute, const SocketException('offline'));
      final h = make(server: server);
      await expectLater(
        h.client.refreshConfig(),
        throwsA(
          isA<FeedpulseException>().having(
            (e) => e.code,
            'code',
            FeedpulseErrorCode.network,
          ),
        ),
      );
    });
  });

  group('contract: submit', () {
    final fields = {'title': 'ログインできない', 'severity': 'high'};

    test('submit-ok: body が fixture に適合、冪等キー・auto・custom', () async {
      final h = make();
      final r = await h.client.submit(
        formId: formId,
        fields: fields,
        custom: {'plan': 'pro'},
        idempotencyKey: 'k3FvQ2mT9xLw8RzB',
      );
      expect(r.id, '0b9f1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d');
      final c = h.server.to(submitRoute).single;
      final body = c.json;
      final expected = Map<String, Object?>.from(
        req('submit-ok')['body']! as Map,
      );
      // os / locale は端末依存なので別に検証する。
      (expected['context'] as Map)['auto'] = {'os': 'Android 15'};
      expectBodyMatches(expected, body);
      final auto = (body['context'] as Map)['auto'] as Map;
      expect(auto['timezone'], 'Asia/Tokyo');
      expect(auto['locale'], isA<String>());
      expect(c.request.headers['Content-Type'], 'application/json');
      expect(c.request.headers['X-FeedPulse-Platform'], 'android');
    });

    test('冪等キーは自動生成され契約の形式、不正な指定は送らず例外', () async {
      final h = make();
      await h.client.submit(formId: formId, fields: fields);
      final key =
          h.server.to(submitRoute).single.json['idempotencyKey']! as String;
      expect(RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(key), isTrue);
      await expectLater(
        h.client.submit(
          formId: formId,
          fields: fields,
          idempotencyKey: 'short',
        ),
        throwsA(
          isA<FeedpulseException>().having(
            (e) => e.code,
            'code',
            FeedpulseErrorCode.invalidIdempotencyKey,
          ),
        ),
      );
    });

    test('identify → context.identity（submit-ok-with-identity）', () async {
      final h = make(
        platform: 'ios',
        attestor: FakeAttestor('ios', {'type': 'dev_insecure'}),
      );
      h.client.identify('jwt.token.value');
      await h.client.submit(formId: formId, fields: fields);
      expectBodyMatches({
        'context': {'identity': '{{identity}}'},
      }, h.server.to(submitRoute).single.json);
      expect(
        ((h.server.to(submitRoute).single.json['context'] as Map)['identity']),
        'jwt.token.value',
      );
      expect(
        h.server.to(submitRoute).single.request.headers['X-FeedPulse-Platform'],
        'ios',
      );

      h.client.identify(null);
      await h.client.submit(formId: formId, fields: fields);
      expect(
        (h.server.to(submitRoute).last.json['context'] as Map).containsKey(
          'identity',
        ),
        isFalse,
      );
    });

    test('identity_invalid: code を保持、再送しない', () async {
      final server = happyServer()
        ..routes[submitRoute] = [fxResponse('submit-identity-invalid')];
      final h = make(server: server);
      h.client.identify('expired.jwt.x');
      await expectLater(
        h.client.submit(
          formId: formId,
          fields: {'title': 't', 'severity': 'low'},
        ),
        throwsA(
          isA<FeedpulseException>()
              .having((e) => e.code, 'code', FeedpulseErrorCode.identityInvalid)
              .having((e) => e.identityCode, 'identityCode', 'expired'),
        ),
      );
      expect(server.to(submitRoute), hasLength(1));
    });

    test('target は allowTarget のフォームにだけ context.auto.target として載る', () async {
      final h = make();
      const t = FeedpulseTargetData(
        screen: 'Checkout',
        id: 'checkout_button',
        label: '購入する',
      );
      await h.client.submit(formId: formId, fields: fields, target: t);
      final auto =
          (h.server.to(submitRoute).single.json['context'] as Map)['auto']
              as Map;
      expect(auto['target'], t.toJson());
      expect((auto['target'] as Map)['platform'], 'flutter');

      // allowTarget=false のフォーム
      final cfg = jsonDecode(jsonEncode(res('config-ok')['body'])) as Map;
      ((cfg['forms'] as List).first as Map)['definition']['allowTarget'] =
          false;
      final server = happyServer()
        ..routes[configRoute] = [FeedpulseResponse(200, {}, jsonEncode(cfg))];
      final h2 = make(server: server);
      await h2.client.submit(formId: formId, fields: fields, target: t);
      final auto2 =
          (server.to(submitRoute).single.json['context'] as Map)['auto'] as Map;
      expect(auto2.containsKey('target'), isFalse);
    });

    test('クライアント検証: 不正なら送らず invalid_fields（サーバーと同じコード）', () async {
      final h = make();
      await expectLater(
        h.client.submit(formId: formId, fields: {'severity': 'urgent'}),
        throwsA(
          isA<FeedpulseException>()
              .having((e) => e.code, 'code', FeedpulseErrorCode.invalidFields)
              .having((e) => e.fieldErrors, 'fieldErrors', {
                'title': FieldErrorCode.required,
                'severity': FieldErrorCode.invalidOption,
              }),
        ),
      );
      expect(h.server.to(submitRoute), isEmpty);
    });

    test('サーバーの invalid_fields を型付きで返す（submit-invalid-fields）', () async {
      // 古い保存値などでクライアント検証を通ったがサーバーが拒否したケース。
      final server = happyServer()
        ..routes[submitRoute] = [fxResponse('submit-invalid-fields')];
      final h = make(server: server);
      await expectLater(
        h.client.submit(
          formId: formId,
          fields: {'title': 't', 'severity': 'low'},
        ),
        throwsA(
          isA<FeedpulseException>()
              .having((e) => e.httpStatus, 'status', 422)
              .having(
                (e) => e.fieldErrors['title'],
                'title',
                FieldErrorCode.required,
              )
              .having(
                (e) => e.fieldErrors['severity'],
                'severity',
                FieldErrorCode.invalidOption,
              ),
        ),
      );
    });

    test('古い保存値で弾かれる場合は最新の定義を取り直して検証し直す', () async {
      final h = make();
      await h.client.refreshConfig();
      // 保存値は title/body/severity。新しい定義では severity が free text。
      final cfg = jsonDecode(jsonEncode(res('config-ok')['body'])) as Map;
      final blocks =
          ((cfg['forms'] as List).first as Map)['definition']['blocks'] as List;
      (blocks[2] as Map)
        ..['type'] = 'short_text'
        ..remove('options');
      final server = happyServer()
        ..routes[configRoute] = [FeedpulseResponse(200, {}, jsonEncode(cfg))];
      final h2 = make(store: h.store, server: server);
      await h2.client.submit(
        formId: formId,
        fields: {'title': 't', 'severity': 'urgent'},
      );
      expect(server.to(submitRoute), hasLength(1));
    });

    test('429 は Retry-After を尊重して同じ冪等キーで再送', () async {
      final server = happyServer()
        ..routes[submitRoute] = [
          fxResponse('submit-rate-limited'),
          fxResponse('submit-ok'),
        ];
      final h = make(server: server);
      final r = await h.client.submit(
        formId: formId,
        fields: {'title': 't', 'severity': 'low'},
      );
      expect(r.id, isNotEmpty);
      expect(h.sleeps, [const Duration(seconds: 30)]);
      final calls = server.to(submitRoute);
      expect(calls, hasLength(2));
      expect(calls[0].json['idempotencyKey'], calls[1].json['idempotencyKey']);
    });

    test('通信失敗・5xx は指数バックオフで再送、上限で例外', () async {
      final server = happyServer()
        ..routes[submitRoute] = [
          const SocketException('x'),
          FeedpulseResponse(503, {}, '{"error":"internal"}'),
          fxResponse('submit-ok'),
        ];
      final h = make(server: server);
      await h.client.submit(
        formId: formId,
        fields: {'title': 't', 'severity': 'low'},
      );
      expect(h.sleeps, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);

      final always = happyServer()
        ..routes[submitRoute] = [FeedpulseResponse(503, {}, 'bad gateway')];
      final h2 = make(server: always);
      await expectLater(
        h2.client.submit(
          formId: formId,
          fields: {'title': 't', 'severity': 'low'},
        ),
        throwsA(
          isA<FeedpulseException>().having(
            (e) => e.code,
            'code',
            FeedpulseErrorCode.internal,
          ),
        ),
      );
      expect(always.to(submitRoute), hasLength(4)); // 初回 + 3 回
    });

    test('再送しないエラー（4xx）は 1 回で例外', () async {
      for (final fx in [
        'submit-identity-invalid',
        'submit-app-not-registered',
      ]) {
        final server = happyServer()..routes[submitRoute] = [fxResponse(fx)];
        final h = make(server: server);
        await expectLater(
          h.client.submit(
            formId: formId,
            fields: {'title': 't', 'severity': 'low'},
          ),
          throwsA(isA<FeedpulseException>()),
        );
        expect(server.to(submitRoute), hasLength(1));
      }
    });

    test('未知の formId は unknown_form', () async {
      final h = make();
      await expectLater(
        h.client.submit(formId: 'nope', fields: {}),
        throwsA(
          isA<FeedpulseException>().having(
            (e) => e.code,
            'code',
            FeedpulseErrorCode.unknownForm,
          ),
        ),
      );
    });
  });

  group('契約 fixture の網羅', () {
    test('error fixture の error 値はすべて FeedpulseErrorCode に対応', () {
      for (final f in fixtures.values) {
        final body = (f['response']! as Map)['body'];
        if (body is Map && body['error'] != null) {
          expect(
            FeedpulseErrorCode.fromWire(body['error']),
            isNotNull,
            reason: '${f['name']}',
          );
        }
      }
    });

    test('request の body / response の body が全 fixture で読める', () {
      expect(fixtures.length, greaterThanOrEqualTo(15));
    });
  });

  group('Feedpulse.configure', () {
    test('publicKey 空・http の本番 URL は拒否、localhost の http は許可', () {
      expect(
        () => Feedpulse.configure(publicKey: ' '),
        throwsA(isA<FeedpulseException>()),
      );
      expect(
        () => Feedpulse.configure(
          publicKey: 'pk_x',
          baseUrl: 'http://example.com',
        ),
        throwsA(isA<FeedpulseException>()),
      );
      expect(
        Feedpulse.configure(
          publicKey: 'pk_x',
          baseUrl: 'http://localhost:8787',
        ),
        isA<FeedpulseClient>(),
      );
      expect(
        Feedpulse.configure(publicKey: 'pk_x').baseUrl,
        Feedpulse.defaultBaseUrl,
      );
    });
  });

  group('NativeAppAttestor（MethodChannel）', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const ch = MethodChannel('dev.feedpulse/native');
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null),
    );

    test(
      'attest / environment / reset を channel に橋渡し、失敗は attestationUnavailable',
      () async {
        final log = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ch, (c) async {
              log.add(c);
              switch (c.method) {
                case 'environment':
                  return {
                    'platform': 'ios',
                    'appId': 'com.example.app',
                    'os': 'iOS 18',
                    'timezone': 'Asia/Tokyo',
                  };
                case 'attest':
                  if (c.arguments['challenge'] == 'bad') {
                    throw PlatformException(
                      code: 'app_attest_unsupported',
                      message: 'no',
                    );
                  }
                  return {'type': 'play_integrity', 'token': 't'};
              }
              return null;
            });
        final a = NativeAppAttestor();
        expect((await a.environment()).appId, 'com.example.app');
        expect(await a.attest('c'), {'type': 'play_integrity', 'token': 't'});
        await a.reset();
        expect(log.map((c) => c.method), [
          'environment',
          'attest',
          'resetAttestation',
        ]);
        await expectLater(
          a.attest('bad'),
          throwsA(
            isA<FeedpulseException>().having(
              (e) => e.code,
              'code',
              FeedpulseErrorCode.attestationUnavailable,
            ),
          ),
        );
      },
    );

    test('プラグイン未登録（デスクトップ等）でも environment は FeedpulseException', () async {
      await expectLater(
        NativeAppAttestor().environment(),
        throwsA(isA<FeedpulseException>()),
      );
    });
  });

  group('validateFields', () {
    const form = FeedpulseForm(
      id: 'f',
      slug: 's',
      name: 'n',
      type: 'bug',
      version: 1,
      allowTarget: false,
      blocks: [
        FeedpulseBlock(
          id: 'e',
          type: 'email',
          label: 'e',
          required: false,
          maxLength: 20,
        ),
        FeedpulseBlock(
          id: 'n',
          type: 'number',
          label: 'n',
          required: false,
          min: 1,
          max: 5,
        ),
        FeedpulseBlock(
          id: 'r',
          type: 'rating',
          label: 'r',
          required: false,
          min: 2,
          max: 5,
        ),
        FeedpulseBlock(
          id: 'c',
          type: 'checkbox',
          label: 'c',
          required: false,
          options: [FeedpulseOption('a', 'A'), FeedpulseOption('b', 'B')],
        ),
        FeedpulseBlock(
          id: 't',
          type: 'short_text',
          label: 't',
          required: true,
          maxLength: 3,
        ),
      ],
    );

    test('各種別のエラー', () {
      expect(validateFields(form, {'t': 'abcd'}), {
        't': FieldErrorCode.tooLong,
      });
      expect(validateFields(form, {'t': 'ab', 'e': 'x'}), {
        'e': FieldErrorCode.invalidEmail,
      });
      expect(validateFields(form, {'t': 'ab', 'e': 'user@example-long.com'}), {
        'e': FieldErrorCode.tooLong,
      });
      expect(
        validateFields(form, {'t': 'ab', 'e': ' user@example.com '}),
        isEmpty,
      );
      expect(validateFields(form, {'t': 'ab', 'r': 2.5}), {
        'r': FieldErrorCode.type,
      });
      expect(validateFields(form, {'t': 'ab', 'r': 0}), {
        'r': FieldErrorCode.outOfRange,
      });
      expect(validateFields(form, {'t': 'ab', 'r': 1}), {
        'r': FieldErrorCode.outOfRange,
      });
      expect(validateFields(form, {'t': 'ab', 'r': 5}), isEmpty);
      expect(validateFields(form, {'t': 'ab', 'n': 9}), {
        'n': FieldErrorCode.outOfRange,
      });
      expect(validateFields(form, {'t': 'ab', 'n': double.nan}), {
        'n': FieldErrorCode.type,
      });
      expect(validateFields(form, {'t': 'ab', 'n': '3'}), {
        'n': FieldErrorCode.type,
      });
      expect(
        validateFields(form, {
          't': 'ab',
          'c': ['a', 'z'],
        }),
        {'c': FieldErrorCode.invalidOption},
      );
      expect(validateFields(form, {'t': 'ab', 'c': 'a'}), {
        'c': FieldErrorCode.type,
      });
      expect(validateFields(form, {'t': 'ab', 'zzz': 1}), {
        'zzz': FieldErrorCode.type,
      });
      expect(
        validateFields(form, {
          't': 'ab',
          'n': 3,
          'c': ['a'],
          'e': 'a@b.co',
        }),
        isEmpty,
      );
      expect(validateFields(form, {}), {'t': FieldErrorCode.required});
    });
  });
}

/// 読み書きを失敗させられるストア（キャッシュの一時障害の再現用）。
class FlakyConfigStore extends MemoryConfigStore {
  int failReads = 0;
  int failWrites = 0;

  @override
  Future<String?> read(String key) async {
    if (failReads > 0) {
      failReads--;
      throw StateError('read failed');
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites > 0) {
      failWrites--;
      throw StateError('write failed');
    }
    return super.write(key, value);
  }
}

void cacheRecoveryTests() {
  group('cache: 保存値の読み書き失敗から復旧する', () {
    test('最初の read だけ失敗しても、2回目の refreshConfig が成功する', () async {
      final store = FlakyConfigStore()..failReads = 1;
      final h = make(store: store);
      final first = await h.client.refreshConfig();
      expect(first.form('bug'), isNotNull);
      final second = await h.client.refreshConfig();
      expect(second.form('bug'), isNotNull);
    });

    test('read が一度失敗しても、次の loadCachedConfig で保存値を読める', () async {
      final seed = make();
      await seed.client.refreshConfig();
      final store = FlakyConfigStore()..failReads = 1;
      final h = make(store: store, server: FakeServer());
      await store.write(
        'config|https://ingest.example.test|pk_example',
        (await seed.store.read(
          'config|https://ingest.example.test|pk_example',
        ))!,
      );
      expect(await h.client.loadCachedConfig(), isNull);
      final cached = await h.client.loadCachedConfig();
      expect(cached?.isStale, isTrue);
      expect(cached?.form('bug'), isNotNull);
    });

    test('write が失敗しても refreshConfig は取得した config を返す', () async {
      final store = FlakyConfigStore()..failWrites = 1;
      final h = make(store: store);
      final cfg = await h.client.refreshConfig();
      expect(cfg.form('bug'), isNotNull);
      expect(h.client.lastError, isNull);
    });
  });
}
