import 'dart:async';
import 'dart:convert';

import 'package:dart_dpop/dart_dpop.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _issuer = 'https://oidc.sonrisa.co.jp/oidc';
const _clientId = 'cibademo-rp';
// secret はビルド時に --dart-define=CIBA_SECRET=... で外から注入する。
// GitHub Actions では Secrets.CIBA_SECRET から渡し、git にはコミットしない。
const _clientSecret = String.fromEnvironment('CIBA_SECRET');

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cibademo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _username = TextEditingController(text: 'david3080@gmail.com');
  bool _busy = false;
  String _status = '';
  Map<String, dynamic>? _idTokenClaims;
  Map<String, dynamic>? _userInfo;

  // DPoP proof generator (ES256 / pointycastle 実装、起動時に key 生成)。
  // アプリ再起動で key は新規に変わるので進行中の access_token は無効化される。
  late final Future<DpopProofGenerator> _dpopGenFuture = _initDpop();

  Future<DpopProofGenerator> _initDpop() async {
    final key = await Es256DpopKey.generate();
    return DpopProofGenerator(key: key);
  }

  String get _basicAuth =>
      'Basic ${base64Encode(utf8.encode('$_clientId:$_clientSecret'))}';

  Future<void> _request() async {
    setState(() {
      _busy = true;
      _status = '認証要求送信中…';
      _idTokenClaims = null;
      _userInfo = null;
    });
    try {
      final bcRes = await http.post(
        Uri.parse('$_issuer/backchannel'),
        headers: {
          'Authorization': _basicAuth,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {
          'scope': 'openid profile email',
          'login_hint': _username.text.trim(),
          'binding_message':
              'cibademo (Mac) — ${DateTime.now().toLocal().toString().substring(0, 16)}',
        },
      );
      if (bcRes.statusCode != 200) {
        throw Exception('backchannel ${bcRes.statusCode}: ${bcRes.body}');
      }
      final bc = jsonDecode(bcRes.body) as Map<String, dynamic>;
      final authReqId = bc['auth_req_id'] as String;
      var interval = (bc['interval'] as num?)?.toInt() ?? 5;
      setState(() => _status = 'auth_req_id 取得。承認をポーリング中…');

      // token endpoint への各 POST に DPoP proof を付与 (RFC 9449)。
      // OP は access_token に cnf.jkt を埋め込んで sender-constrained にする。
      final dpopGen = await _dpopGenFuture;
      const tokenUrl = '$_issuer/token';

      Map<String, dynamic>? token;
      while (token == null) {
        await Future.delayed(Duration(seconds: interval));
        final dpopProof = await dpopGen.createProof(
          htm: 'POST',
          htu: tokenUrl,
        );
        final tokRes = await http.post(
          Uri.parse(tokenUrl),
          headers: {
            'Authorization': _basicAuth,
            'Content-Type': 'application/x-www-form-urlencoded',
            'DPoP': dpopProof,
          },
          body: {
            'grant_type': 'urn:openid:params:grant-type:ciba',
            'auth_req_id': authReqId,
          },
        );
        if (tokRes.statusCode == 200) {
          token = jsonDecode(tokRes.body) as Map<String, dynamic>;
          break;
        }
        final err = jsonDecode(tokRes.body) as Map<String, dynamic>;
        switch (err['error']) {
          case 'authorization_pending':
            break;
          case 'slow_down':
            interval = (interval * 1.5).ceil();
            break;
          default:
            throw Exception(
              'token ${tokRes.statusCode}: ${err['error']} — ${err['error_description'] ?? ''}',
            );
        }
      }

      // id_token claims を decode (検証は PoC のため省略)
      final parts = (token['id_token'] as String).split('.');
      String b64pad(String s) => s + '=' * ((4 - s.length % 4) % 4);
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(b64pad(parts[1]))),
      ) as Map<String, dynamic>;

      // userinfo (= /oidc/me) も DPoP-bound access_token なので proof + Authorization: DPoP が必須。
      // access_token を accessToken に渡すと ath (= SHA-256(access_token)) も自動付与される。
      const userinfoUrl = '$_issuer/me';
      final accessToken = token['access_token'] as String;
      final uiProof = await dpopGen.createProof(
        htm: 'GET',
        htu: userinfoUrl,
        accessToken: accessToken,
      );
      final uiRes = await http.get(
        Uri.parse(userinfoUrl),
        headers: {
          'Authorization': 'DPoP $accessToken',
          'DPoP': uiProof,
        },
      );
      final userInfo = uiRes.statusCode == 200
          ? jsonDecode(uiRes.body) as Map<String, dynamic>
          : <String, dynamic>{
              '_error': 'userinfo ${uiRes.statusCode}: ${uiRes.body}',
            };

      setState(() {
        _status = 'CIBA 認証成功';
        _idTokenClaims = claims;
        _userInfo = userInfo;
      });
    } catch (e) {
      setState(() => _status = '失敗: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return Scaffold(
      appBar: AppBar(title: const Text('cibademo — CIBA Consumption Device')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'login_hint (ユーザー名)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _request,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('認証要求 (CIBA)'),
          ),
          const SizedBox(height: 16),
          if (_status.isNotEmpty)
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
          if (_idTokenClaims != null) ...[
            const SizedBox(height: 16),
            _DataCard(
              title: 'ID Token Claims',
              body: encoder.convert(_idTokenClaims),
            ),
          ],
          if (_userInfo != null) ...[
            const SizedBox(height: 8),
            _DataCard(title: 'UserInfo', body: encoder.convert(_userInfo)),
          ],
        ],
      ),
    );
  }
}

class _DataCard extends StatelessWidget {
  const _DataCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(
              body,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
