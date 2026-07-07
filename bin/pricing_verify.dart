import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:tokenbar/core/pricing/pricing_repository.dart';

/// 재백필 전 격리 검증: 편집한 번들 단가로 DB 모델별 버킷 합의 예상 비용을 계산.
/// (우리 DB 모델은 모두 flat 단가 → 합계에 선형 적용 = per-event 합과 동일)
void main() {
  final json = jsonDecode(
      File('assets/pricing/litellm_claude.json').readAsStringSync());
  final repo = PricingRepository.fromLiteLlm(json as Map<String, dynamic>);

  final home = Platform.environment['HOME']!;
  final src =
      '$home/Library/Application Support/dev.shimkijun.tokenbar/usage.db';
  final tmp =
      '${Directory.systemTemp.path}/tokenbar_pricing_${DateTime.now().microsecondsSinceEpoch}.db';
  for (final s in ['', '-wal', '-shm']) {
    final f = File('$src$s');
    if (f.existsSync()) f.copySync('$tmp$s');
  }
  final db = sqlite3.open(tmp);
  final rows = db.select('''
    SELECT model,
      COALESCE(SUM(input_tokens),0) i, COALESCE(SUM(output_tokens),0) o,
      COALESCE(SUM(cache_creation_tokens),0) cc, COALESCE(SUM(cache_read_tokens),0) cr,
      COALESCE(SUM(cost_usd),0.0) oldcost
    FROM usage_event GROUP BY model ORDER BY i DESC''');

  double newTotal = 0, oldTotal = 0;
  var allPriced = true;
  print('모델                        예상비용      (기존)    단가매칭');
  for (final row in rows) {
    final model = row['model'] as String;
    final i = (row['i'] as num).toInt();
    final o = (row['o'] as num).toInt();
    final cc = (row['cc'] as num).toInt();
    final cr = (row['cr'] as num).toInt();
    final old = (row['oldcost'] as num).toDouble();
    final p = repo.resolve(model);
    if (p == null) allPriced = false;
    final cost = p == null
        ? 0.0
        : i * p.inputPerToken +
            o * p.outputPerToken +
            cc * p.cacheWritePerToken +
            cr * p.cacheReadPerToken;
    newTotal += cost;
    oldTotal += old;
    print('${model.padRight(26)} '
        '\$${cost.toStringAsFixed(2).padLeft(9)}  '
        '\$${old.toStringAsFixed(2).padLeft(8)}  ${p == null ? "❌ 없음" : "✅"}');
  }
  print('─' * 60);
  print('신규 총계  \$${newTotal.toStringAsFixed(2)}   '
      '(기존 \$${oldTotal.toStringAsFixed(2)})  '
      '차이 \$${(newTotal - oldTotal).toStringAsFixed(2)}');
  print('모든 모델 단가 매칭: ${allPriced ? "OK" : "FAIL"}');

  db.dispose();
  for (final s in ['', '-wal', '-shm']) {
    final f = File('$tmp$s');
    if (f.existsSync()) f.deleteSync();
  }
}
