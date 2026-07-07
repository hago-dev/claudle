/// 모델 1개의 토큰 단가(LiteLLM `model_prices_and_context_window.json` 스키마 호환).
///
/// 200k 초과 tier 필드는 있을 때만 적용(대부분의 Claude 모델엔 없음 → null).
class ModelPricing {
  final double inputPerToken;
  final double outputPerToken;
  final double cacheWritePerToken; // cache_creation_input_token_cost (5m 기준)
  final double cacheReadPerToken; // cache_read_input_token_cost

  final double? inputAbove200k;
  final double? outputAbove200k;
  final double? cacheWriteAbove200k;
  final double? cacheReadAbove200k;

  /// accurate 모드용(1h 캐시 별도 단가). 없으면 5m 단가로 대체.
  final double? cacheWrite1hPerToken;

  const ModelPricing({
    required this.inputPerToken,
    required this.outputPerToken,
    required this.cacheWritePerToken,
    required this.cacheReadPerToken,
    this.inputAbove200k,
    this.outputAbove200k,
    this.cacheWriteAbove200k,
    this.cacheReadAbove200k,
    this.cacheWrite1hPerToken,
  });

  static double? _d(Object? v) => (v as num?)?.toDouble();

  /// LiteLLM 스키마 맵에서 파싱.
  factory ModelPricing.fromLiteLlm(Map<String, dynamic> j) {
    return ModelPricing(
      inputPerToken: _d(j['input_cost_per_token']) ?? 0,
      outputPerToken: _d(j['output_cost_per_token']) ?? 0,
      cacheWritePerToken: _d(j['cache_creation_input_token_cost']) ?? 0,
      cacheReadPerToken: _d(j['cache_read_input_token_cost']) ?? 0,
      inputAbove200k: _d(j['input_cost_per_token_above_200k_tokens']),
      outputAbove200k: _d(j['output_cost_per_token_above_200k_tokens']),
      cacheWriteAbove200k:
          _d(j['cache_creation_input_token_cost_above_200k_tokens']),
      cacheReadAbove200k:
          _d(j['cache_read_input_token_cost_above_200k_tokens']),
      cacheWrite1hPerToken: _d(j['cache_creation_input_token_cost_1h']),
    );
  }
}
