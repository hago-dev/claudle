import 'model_pricing.dart';

/// 모델 id → [ModelPricing] 조회. 단가는 LiteLLM 스키마 맵에서 로드하고
/// 사용자 override 를 위에 merge 한다.
///
/// 매칭(ccusage 동일): 정확 id 먼저, 없으면 대소문자 무시 substring 양방향.
class PricingRepository {
  final Map<String, ModelPricing> _byModel;
  final Map<String, ModelPricing> _cache = {};

  PricingRepository(this._byModel);

  /// [bundled] 위에 [override] 를 덮어써 생성. 두 맵 모두 LiteLLM 스키마.
  factory PricingRepository.fromLiteLlm(
    Map<String, dynamic> bundled, {
    Map<String, dynamic> override = const {},
  }) {
    final merged = <String, ModelPricing>{};
    void add(Map<String, dynamic> src) {
      src.forEach((model, v) {
        if (v is Map<String, dynamic> &&
            v.containsKey('input_cost_per_token')) {
          merged[model] = ModelPricing.fromLiteLlm(v);
        }
      });
    }

    add(bundled);
    add(override); // override 가 이김
    return PricingRepository(merged);
  }

  ModelPricing? resolve(String model) {
    final cached = _cache[model];
    if (cached != null) return cached;

    // 1) 정확 일치
    var found = _byModel[model];
    // 2) 대소문자 무시 substring 양방향
    if (found == null) {
      final lower = model.toLowerCase();
      for (final entry in _byModel.entries) {
        final k = entry.key.toLowerCase();
        if (lower.contains(k) || k.contains(lower)) {
          found = entry.value;
          break;
        }
      }
    }
    if (found != null) _cache[model] = found;
    return found;
  }
}
