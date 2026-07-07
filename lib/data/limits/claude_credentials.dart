import 'dart:convert';
import 'dart:io';

/// Claude Code 가 저장한 OAuth 자격증명(macOS 키체인, generic-password
/// service = "Claude Code-credentials"). Claude Code 가 실행 중이면 스스로 토큰을
/// 갱신하므로 매 폴링마다 다시 읽으면 최신 토큰을 얻는다.
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

  /// 키체인에서 자격증명 읽기. 없거나 파싱 실패 시 null.
  static Future<ClaudeCredentials?> read() async {
    if (!Platform.isMacOS) return null;
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
    final raw = (r.stdout as String).trim();
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
