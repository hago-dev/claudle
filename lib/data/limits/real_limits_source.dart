import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/limits/limits_source.dart';
import '../../domain/models/subscription_limits.dart';
import 'claude_credentials.dart';

/// 실제 구독 한도 소스: Claude Code OAuth 토큰(키체인)으로
/// `GET https://api.anthropic.com/api/oauth/usage` 를 호출해 `limits[]` 를 파싱.
///
/// 내부 엔드포인트라 방어적으로: 없는 필드는 null 취급, 형태가 바뀌면 조용히 스킵.
/// 토큰 만료(401)는 다음 폴링에서 키체인 재읽기로 자연 복구(Claude Code가 갱신).
class RealLimitsSource implements LimitsSource {
  static const _endpoint = 'https://api.anthropic.com/api/oauth/usage';
  // rate-limit 버킷을 정상으로 유지하려면 CLI 형태의 User-Agent 필요.
  static const _userAgent = 'claude-cli/2.1.202';
  static const _beta = 'oauth-2025-04-20';

  @override
  String get id => 'claude-oauth-usage';

  @override
  Future<bool> isAvailable() async => Platform.isMacOS;

  @override
  Future<SubscriptionLimits?> fetch() async {
    final creds = await ClaudeCredentials.read();
    if (creds == null) {
      throw const LimitsFetchException('Claude Code 자격증명 없음(로그인 필요)');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse(_endpoint));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${creds.accessToken}')
        ..set('anthropic-beta', _beta)
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, _userAgent);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw LimitsFetchException('HTTP ${resp.statusCode}');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return _parse(json, creds);
    } finally {
      client.close(force: true);
    }
  }

  SubscriptionLimits _parse(Map<String, dynamic> json, ClaudeCredentials creds) {
    final rawLimits = (json['limits'] as List?) ?? const [];
    final rows = rawLimits.whereType<Map<String, dynamic>>().toList();

    LimitBucket bucket(Map<String, dynamic> r, String label) => LimitBucket(
          label: label,
          usedFraction: ((r['percent'] as num?)?.toDouble() ?? 0) / 100.0,
          resetsAt: _parseTime(r['resets_at']),
        );

    // 세션: limits[kind==session], 없으면 flat five_hour 폴백.
    Map<String, dynamic>? sessionRow;
    for (final r in rows) {
      if (r['kind'] == 'session') {
        sessionRow = r;
        break;
      }
    }
    final session = sessionRow != null
        ? bucket(sessionRow, '현재 세션')
        : _flatBucket(json['five_hour'], '현재 세션');

    final weekly = <LimitBucket>[];
    for (final r in rows) {
      switch (r['kind']) {
        case 'weekly_all':
          weekly.add(bucket(r, '모든 모델'));
        case 'weekly_scoped':
          final model = (r['scope'] as Map?)?['model'] as Map?;
          final name = model?['display_name'] as String? ?? '(모델)';
          weekly.add(bucket(r, name));
      }
    }
    // limits[] 에 주간이 없으면 flat seven_day 폴백.
    if (weekly.isEmpty) {
      final w = _flatBucket(json['seven_day'], '모든 모델');
      if (w != null) weekly.add(w);
    }

    return SubscriptionLimits(
      planLabel: creds.planLabel,
      session: session ??
          const LimitBucket(label: '현재 세션', usedFraction: 0, resetsAt: null),
      weekly: weekly,
      fetchedAt: DateTime.now(),
    );
  }

  LimitBucket? _flatBucket(Object? node, String label) {
    if (node is! Map<String, dynamic>) return null;
    return LimitBucket(
      label: label,
      usedFraction: ((node['utilization'] as num?)?.toDouble() ?? 0) / 100.0,
      resetsAt: _parseTime(node['resets_at']),
    );
  }

  DateTime? _parseTime(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }
}

/// 한도 조회 실패(상태 표시용).
class LimitsFetchException implements Exception {
  final String message;
  const LimitsFetchException(this.message);
  @override
  String toString() => message;
}
