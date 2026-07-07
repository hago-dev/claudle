import '../models/subscription_limits.dart';

/// 구독 한도 스냅샷을 조달하는 소스(서버 엔드포인트/로컬 캐시/CLI 등).
///
/// **seam**: 표시 경로([LimitsController]→트레이/대시보드)는 소스 구현을 모른다.
/// 현재 구현은 `RealLimitsSource`(Claude OAuth usage 엔드포인트).
abstract class LimitsSource {
  String get id;

  /// 이 환경에서 조달 가능한가(토큰/파일 존재 등).
  Future<bool> isAvailable();

  /// 현재 한도 스냅샷. 실패 시 null.
  Future<SubscriptionLimits?> fetch();
}
