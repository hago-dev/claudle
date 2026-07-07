import 'dart:convert';

import '../../../domain/models/usage_event.dart';

/// Claude Code JSONL 한 줄 → [UsageEvent]. ccusage 와 동일한 필터/디덤 규약.
///
/// 규약(ccusage data-loader 대조):
///  - `message.usage` 가 있는 레코드만 사용.
///  - `model == "<synthetic>"` 는 제외(토큰 총계에서도 빠짐).
///  - dedupKey = `message.id + ':' + requestId`(둘 중 하나라도 없으면 null).
///  - 토큰: `input_tokens / output_tokens / cache_creation_input_tokens / cache_read_input_tokens`.
class ClaudeJsonlParser {
  static const String providerId = 'claude_code';

  /// 파싱 불가/사용량 없음/synthetic 이면 null.
  /// [project] 는 호출자가 파일 경로에서 추출해 전달(없으면 레코드의 cwd 사용).
  UsageEvent? parseLine(
    String line, {
    required String sourceRef,
    String? project,
  }) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;

    final Object? decoded;
    try {
      decoded = json.decode(trimmed);
    } catch (_) {
      return null; // 부분/깨진 라인은 건너뜀(라이브 세션 중 flush 대비).
    }
    if (decoded is! Map) return null;
    final obj = decoded;

    final message = obj['message'];
    if (message is! Map) return null;
    final usage = message['usage'];
    if (usage is! Map) return null;

    final model = (message['model'] as String?) ?? 'unknown';
    if (model == '<synthetic>') return null;

    final id = message['id'];
    final requestId = obj['requestId'];
    final dedupKey =
        (id != null && requestId != null) ? '$id:$requestId' : null;

    int tok(Map usage, String key) => (usage[key] as num?)?.toInt() ?? 0;
    final cacheCreation = usage['cache_creation'];
    int ephemeral(String key) => cacheCreation is Map
        ? ((cacheCreation[key] as num?)?.toInt() ?? 0)
        : 0;

    final ts = DateTime.tryParse((obj['timestamp'] as String?) ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    return UsageEvent(
      providerId: providerId,
      timestampUtc: ts,
      model: model,
      project: project ?? (obj['cwd'] as String?),
      cwd: obj['cwd'] as String?,
      sessionId: obj['sessionId'] as String?,
      inputTokens: tok(usage, 'input_tokens'),
      outputTokens: tok(usage, 'output_tokens'),
      cacheCreationTokens: tok(usage, 'cache_creation_input_tokens'),
      cacheReadTokens: tok(usage, 'cache_read_input_tokens'),
      cacheCreation5mTokens: ephemeral('ephemeral_5m_input_tokens'),
      cacheCreation1hTokens: ephemeral('ephemeral_1h_input_tokens'),
      dedupKey: dedupKey,
      reportedCostUsd: (obj['costUSD'] as num?)?.toDouble(),
      sourceRef: sourceRef,
    );
  }
}
