import 'dart:async';

/// 사용량 소스 한 종류(Claude Code / 향후 Codex·Cursor·REST …).
///
/// **Deep Module**: 호출자([AppController])는 "어떻게 파싱/감시하는지"를 몰라도 된다.
/// provider 는 공유 DB 를 스스로 채우고([backfill]), 변경을 신호로만 알린다([watch]).
/// 정규화·비용·집계는 DB 아래에서 일괄 처리되므로 인터페이스가 얇다.
abstract class UsageProvider {
  /// 안정적 식별자(예 'claude-code'). DB `provider_id` 와 일치.
  String get id;

  /// 사람이 읽는 이름(설정/대시보드 라벨).
  String get displayName;

  /// 이 환경에서 소스가 존재/접근 가능한가(예: `~/.claude/projects` 존재).
  bool isAvailable();

  /// 미수집분 전량을 DB 에 증분 반영. [onProgress] 로 부분 진행 통보(부분 갱신용).
  Future<void> backfill({void Function()? onProgress});

  /// 실시간 변경 스트림. **DB 에 신규 반영이 생길 때마다 1회 emit**(값은 의미 없음 —
  /// 호출자는 신호로만 쓰고 총계를 다시 읽는다). 구독 해제 = 감시 종료.
  Stream<void> watch();

  /// 리소스 정리(watcher 구독·타이머 등).
  void dispose() {}
}

/// 등록된 provider 목록. 사용 가능한 것만 걸러서 노출.
class ProviderRegistry {
  final List<UsageProvider> providers;
  const ProviderRegistry(this.providers);

  Iterable<UsageProvider> get available =>
      providers.where((p) => p.isAvailable());
}
