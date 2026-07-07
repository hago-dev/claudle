import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/util/user_home.dart';

/// Claude Code 가 저장한 OAuth 자격증명. Claude Code 가 실행 중이면 스스로 토큰을
/// 갱신하므로 매 폴링마다 다시 읽으면 최신 토큰을 얻는다.
///
/// 저장 위치는 OS 마다 다르다:
///  - **macOS**: 로그인 키체인 generic-password(service = "Claude Code-credentials").
///  - **Windows/Linux**: 평문 파일 `<claude 설정 디렉토리>/.credentials.json`.
///
/// 두 소스의 JSON 형태는 동일: `{"claudeAiOauth": {...}}`.
///
/// 보안: accessToken/refreshToken 은 절대 로그로 남기지 않는다.
class ClaudeCredentials {
  final String accessToken;
  final String? refreshToken;
  final int? expiresAtMs;
  final String? subscriptionType; // 'max' / 'pro' / 'team' / ...
  final String? rateLimitTier; // 'default_claude_max_5x' / '_20x' / ...

  const ClaudeCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtMs,
    required this.subscriptionType,
    required this.rateLimitTier,
  });

  /// "Max (5x)" 같은 플랜 라벨(usage 엔드포인트엔 없어 자격증명에서 유도).
  String get planLabel {
    final base = switch (subscriptionType) {
      'max' => 'Max',
      'pro' => 'Pro',
      'team' => 'Team',
      'enterprise' => 'Enterprise',
      final s? => s.isEmpty ? '—' : '${s[0].toUpperCase()}${s.substring(1)}',
      _ => '—',
    };
    final suffix = switch (rateLimitTier) {
      'default_claude_max_5x' => ' (5x)',
      'default_claude_max_20x' => ' (20x)',
      _ => '',
    };
    return '$base$suffix';
  }

  static ClaudeCredentials? _fromOauthMap(Map<String, dynamic> o) {
    final token = o['accessToken'];
    if (token is! String || token.isEmpty) return null; // mcpOAuth-only 등 → 없음
    return ClaudeCredentials(
      accessToken: token,
      refreshToken: o['refreshToken'] as String?,
      expiresAtMs: (o['expiresAt'] as num?)?.toInt(),
      subscriptionType: o['subscriptionType'] as String?,
      rateLimitTier: o['rateLimitTier'] as String?,
    );
  }

  /// 자격증명 읽기. 없거나 파싱 실패 시 null.
  ///
  /// macOS: 키체인 우선(Claude Code 가 실시간 갱신) → 실패 시 파일 폴백.
  /// Windows/Linux: `.credentials.json` 파일.
  static Future<ClaudeCredentials?> read({Map<String, String>? env}) async {
    if (Platform.isMacOS) {
      final fromKeychain = await _readKeychain();
      if (fromKeychain != null) return fromKeychain;
    }
    return _readCredentialsFile(env: env);
  }

  /// macOS 로그인 키체인의 generic-password(service="Claude Code-credentials").
  static Future<ClaudeCredentials?> _readKeychain() async {
    ProcessResult r;
    try {
      r = await Process.run('security', [
        'find-generic-password',
        '-s',
        'Claude Code-credentials',
        '-w',
      ]);
    } catch (_) {
      return null;
    }
    if (r.exitCode != 0) return null;
    return _parse((r.stdout as String).trim());
  }

  /// `<claude 설정 디렉토리>/.credentials.json` 파일에서 읽기.
  /// 후보 순서: CLAUDE_CONFIG_DIR 항목들 → ~/.claude → ~/.config/claude. 첫 성공 반환.
  static Future<ClaudeCredentials?> _readCredentialsFile({
    Map<String, String>? env,
  }) async {
    final e = env ?? Platform.environment;
    final candidates = <String>[];
    final configured = e['CLAUDE_CONFIG_DIR'];
    if (configured != null && configured.trim().isNotEmpty) {
      candidates.addAll(configured.split(',').map((s) => s.trim()));
    }
    final home = userHome(e);
    if (home != null) {
      candidates
        ..add(p.join(home, '.claude'))
        ..add(p.join(home, '.config', 'claude'));
    }
    for (final dir in candidates) {
      final f = File(p.join(dir, '.credentials.json'));
      String raw;
      try {
        if (!f.existsSync()) continue;
        raw = f.readAsStringSync().trim();
      } catch (_) {
        continue;
      }
      final creds = _parse(raw);
      if (creds != null) return creds;
    }
    return null;
  }

  /// `{"claudeAiOauth": {...}}` JSON 문자열 → 자격증명. 실패 시 null.
  static ClaudeCredentials? _parse(String raw) {
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final oauth = json['claudeAiOauth'];
      if (oauth is! Map<String, dynamic>) return null;
      return _fromOauthMap(oauth);
    } catch (_) {
      return null;
    }
  }
}
