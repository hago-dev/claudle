import '../../domain/models/usage_event.dart';
import 'model_pricing.dart';

enum CostMode {
  /// ccusage 와 센트 단위 일치: 모든 cacheCreation 을 5m 단가로.
  ccusageCompatible,

  /// 1h 캐시를 별도 1h 단가로(더 정확, 단가에 1h 필드가 있을 때만 차이).
  accurate,
}

/// ccusage 와 동일한 4버킷·200k tier 비용 공식.
class CostCalculator {
  final CostMode mode;
  const CostCalculator({this.mode = CostMode.ccusageCompatible});

  /// tier(n, base, above): n<=0→0 · above 있고 n>200k → 200k*base+(n-200k)*above · 그 외 n*base.
  static double tier(int n, double base, double? above,
      {int threshold = 200000}) {
    if (n <= 0) return 0;
    if (above != null && n > threshold) {
      return threshold * base + (n - threshold) * above;
    }
    return n * base;
  }

  double cost(UsageEvent e, ModelPricing? p) {
    // 소스가 이미 가격을 매겼으면 그대로(REST usage provider 등).
    if (e.reportedCostUsd != null) return e.reportedCostUsd!;
    if (p == null) return 0; // 단가 미상 모델 → 0 (ccusage 동일).

    double c = tier(e.inputTokens, p.inputPerToken, p.inputAbove200k) +
        tier(e.outputTokens, p.outputPerToken, p.outputAbove200k) +
        tier(e.cacheReadTokens, p.cacheReadPerToken, p.cacheReadAbove200k);

    if (mode == CostMode.accurate && p.cacheWrite1hPerToken != null) {
      // 5m/1h 분리 과금.
      c += tier(e.cacheCreation5mTokens, p.cacheWritePerToken,
              p.cacheWriteAbove200k) +
          tier(e.cacheCreation1hTokens, p.cacheWrite1hPerToken!, null);
    } else {
      // ccusage 호환: 전체 cacheCreation 을 5m 단가로.
      c += tier(e.cacheCreationTokens, p.cacheWritePerToken,
          p.cacheWriteAbove200k);
    }
    return c;
  }
}
