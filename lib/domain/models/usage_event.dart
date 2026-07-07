/// 모든 provider(Claude Code, 향후 Codex/Cursor/REST…)가 산출하는 정규화된 사용량 이벤트.
///
/// 원칙(멀티 provider seam): provider 는 토큰만 정규화해 내보내고,
/// 비용은 [CostCalculator] 가 단가표로 중앙에서 일괄 계산한다.
/// 소스가 이미 가격을 매긴 경우에만 [reportedCostUsd] 를 채운다.
class UsageEvent {
  final String providerId; // 'claude_code', 'codex', ...
  final DateTime timestampUtc;
  final String model; // 원본 id, 예: 'claude-opus-4-8'
  final String? project; // projects/ 하위 인코딩된 디렉토리명(그룹 키)
  final String? cwd; // 레코드의 실제 작업 경로(표시용 디렉토리명 추출 소스)
  final String? sessionId;

  final int inputTokens;
  final int outputTokens;
  final int cacheCreationTokens; // 5m + 1h 합계
  final int cacheReadTokens;
  final int cacheCreation5mTokens;
  final int cacheCreation1hTokens;

  /// 'messageId:requestId' — 둘 중 하나라도 없으면 null(디덤 안 함). ccusage 규약과 동일.
  final String? dedupKey;

  /// 소스가 직접 계산한 비용(있을 때만). 없으면 단가표로 계산.
  final double? reportedCostUsd;

  /// 출처(파일 경로 / rowid 등).
  final String sourceRef;

  const UsageEvent({
    required this.providerId,
    required this.timestampUtc,
    required this.model,
    required this.project,
    required this.cwd,
    required this.sessionId,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheCreationTokens,
    required this.cacheReadTokens,
    required this.cacheCreation5mTokens,
    required this.cacheCreation1hTokens,
    required this.dedupKey,
    required this.reportedCostUsd,
    required this.sourceRef,
  });

  int get totalTokens =>
      inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens;
}
