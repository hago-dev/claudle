/// Claude Code 세션 하나의 컨텍스트 소진도 — auto-compact 까지 얼마나 남았나.
///
/// **Deep Module**: 호출자는 `filledFraction`/`remainingPercent` 두 개만 알면 된다.
/// 임계값 규칙(고정 예약분·override·분모)은 전부 여기 숨는다.
///
/// 숫자는 CC 툴팁("N% of context remaining until auto-compact")과 같은 식으로 낸다.
/// 주의: statusline 페이로드의 `remaining_percentage` 는 **전체 윈도우**가 분모라
/// 이 값과 다르다. 그래서 그 필드는 쓰지 않고 여기서 다시 계산한다.
class ContextGauge {
  /// auto-compact 가 남겨두는 고정 예약분. 임계값 기본값은 퍼센트가 아니라 이것이다.
  static const int reserveTokens = 13000;

  final String sessionId;
  final int usedTokens;
  final int windowSize;

  /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1~100). null = 미설정(기본 예약분만 적용).
  final int? pctOverride;

  final DateTime updatedAt;

  const ContextGauge({
    required this.sessionId,
    required this.usedTokens,
    required this.windowSize,
    required this.pctOverride,
    required this.updatedAt,
  });

  /// 어시스턴트 한 턴의 `usage` → 그 시점 컨텍스트 토큰 수.
  ///
  /// 네 필드를 모두 더한다(output 포함). 캐시 필드는 없을 수 있다.
  static int tokensOf(Map<String, dynamic> usage) {
    int f(String k) => (usage[k] as num?)?.toInt() ?? 0;
    return f('input_tokens') +
        f('cache_creation_input_tokens') +
        f('cache_read_input_tokens') +
        f('output_tokens');
  }

  /// auto-compact 가 발동하는 토큰 수.
  int get compactThreshold {
    final byReserve = windowSize - reserveTokens;
    final pct = pctOverride;
    if (pct != null && pct > 0 && pct <= 100) {
      final byPct = (windowSize * pct / 100).floor();
      return byPct < byReserve ? byPct : byReserve;
    }
    return byReserve;
  }

  /// 게이지 채움(0.0~1.0). 임계값이 분모다.
  double get filledFraction {
    final t = compactThreshold;
    if (t <= 0) return 1.0;
    return (usedTokens / t).clamp(0.0, 1.0);
  }

  /// 남은 %. CC 툴팁과 같은 반올림.
  int get remainingPercent {
    final t = compactThreshold;
    if (t <= 0) return 0;
    final r = ((t - usedTokens) / t * 100).round();
    return r < 0 ? 0 : r;
  }
}
