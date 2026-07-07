// P2 검증: 실제 Claude 로그 전체를 파싱→디덤→집계하고 ccusage 오라클과 대조.
// 실행: fvm dart run bin/verify.dart
import 'dart:convert';
import 'dart:io';

import 'package:tokenbar/core/pricing/cost_calculator.dart';
import 'package:tokenbar/core/pricing/pricing_repository.dart';
import 'package:tokenbar/domain/models/usage_event.dart';
import 'package:tokenbar/data/providers/claude_code/claude_jsonl_parser.dart';
import 'package:tokenbar/data/providers/claude_code/claude_path_resolver.dart';

void main(List<String> args) {
  final resolver = ClaudePathResolver();
  final parser = ClaudeJsonlParser();

  final bundled = json.decode(
    File('assets/pricing/litellm_claude.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final pricing = PricingRepository.fromLiteLlm(bundled);
  const calc = CostCalculator(mode: CostMode.ccusageCompatible);

  final files = resolver.jsonlFiles();
  // dedup 정책: (message.id, requestId) 그룹당 output 최대(=최종 완성) 레코드 채택.
  // 순서 무관·결정적. ccusage keep-first 와 달리 스트리밍 중간 부분값을 버림.
  final byKey = <String, UsageEvent>{};
  final noKey = <UsageEvent>[];

  for (final f in files) {
    final project = ClaudePathResolver.projectFromPath(f.path);
    final List<String> lines;
    try {
      lines = f.readAsLinesSync();
    } catch (_) {
      continue;
    }
    for (final line in lines) {
      final e = parser.parseLine(line, sourceRef: f.path, project: project);
      if (e == null) continue;
      final key = e.dedupKey;
      if (key == null) {
        noKey.add(e);
      } else {
        final ex = byKey[key];
        if (ex == null || e.outputTokens > ex.outputTokens) byKey[key] = e;
      }
    }
  }

  int inT = 0, outT = 0, ccT = 0, crT = 0;
  double cost = 0;
  final models = <String>{};
  for (final e in [...byKey.values, ...noKey]) {
    inT += e.inputTokens;
    outT += e.outputTokens;
    ccT += e.cacheCreationTokens;
    crT += e.cacheReadTokens;
    cost += calc.cost(e, pricing.resolve(e.model));
    models.add(e.model);
  }
  final records = byKey.length + noKey.length;

  final out = {
    'files': files.length,
    'records': records,
    'inputTokens': inT,
    'outputTokens': outT,
    'cacheCreationTokens': ccT,
    'cacheReadTokens': crT,
    'totalTokens': inT + outT + ccT + crT,
    'totalCost': cost,
    'models': models.toList()..sort(),
  };
  print(const JsonEncoder.withIndent('  ').convert(out));
}
