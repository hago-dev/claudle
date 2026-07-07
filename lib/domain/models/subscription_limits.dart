/// Claude 구독 사용량 한도 한 버킷(현재 세션 / 주간 모든모델 / 주간 Fable …).
class LimitBucket {
  final String label; // 표시명: '현재 세션' / '모든 모델' / 'Fable'
  final double usedFraction; // 0.0~1.0 (예: 0.55 = 55%)
  final DateTime? resetsAt; // 재설정 시각(UTC). null=미상

  const LimitBucket({
    required this.label,
    required this.usedFraction,
    required this.resetsAt,
  });

  int get usedPercent => (usedFraction * 100).round();
}

/// `/usage` 패널 전체를 정규화한 스냅샷.
///
/// 소스([LimitsSource])가 무엇이든(서버 엔드포인트/로컬 캐시/CLI) 이 형태로 환원한다.
class SubscriptionLimits {
  final String planLabel; // 'Max (5x)'
  final LimitBucket session; // 현재 세션(짧은 롤링 윈도우)
  final List<LimitBucket> weekly; // 주간 버킷들(모든 모델, Fable, …)
  final DateTime fetchedAt; // '마지막 업데이트'

  const SubscriptionLimits({
    required this.planLabel,
    required this.session,
    required this.weekly,
    required this.fetchedAt,
  });
}
