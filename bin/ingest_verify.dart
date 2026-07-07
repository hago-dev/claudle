// P3 검증: DB 백필을 2회 돌려 증분성(2회차 신규≈0)·총계 안정성 확인.
// 실행: fvm dart run bin/ingest_verify.dart [dbPath]
import 'dart:convert';
import 'dart:io';

import 'package:tokenbar/core/db/usage_database.dart';
import 'package:tokenbar/core/pricing/pricing_repository.dart';
import 'package:tokenbar/data/ingest/ingest_service.dart';

void main(List<String> args) {
  final dbPath = args.isNotEmpty
      ? args.first
      : '${Directory.systemTemp.path}/tokenbar_verify_${DateTime.now().microsecondsSinceEpoch}.db';
  // 깨끗한 상태에서 시작
  for (final ext in ['', '-wal', '-shm']) {
    final ff = File('$dbPath$ext');
    if (ff.existsSync()) ff.deleteSync();
  }

  final bundled = json.decode(
    File('assets/pricing/litellm_claude.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final pricing = PricingRepository.fromLiteLlm(bundled);

  final db = UsageDatabase.open(dbPath);
  final ingest = IngestService(db: db, pricing: pricing);

  final r1 = ingest.backfill();
  final t1 = db.totals();
  final r2 = ingest.backfill();
  final t2 = db.totals();

  void printTotals(String label, UsageTotals t) {
    print('$label: records=${t.records} in=${t.inputTokens} out=${t.outputTokens} '
        'cc=${t.cacheCreationTokens} cr=${t.cacheReadTokens} '
        'total=${t.totalTokens} cost=\$${t.costUsd.toStringAsFixed(2)}');
  }

  print('run1 $r1');
  printTotals('totals1', t1);
  print('run2 $r2  <-- 2회차: bytes/upserted ≈ 0 이어야 증분 정상');
  printTotals('totals2', t2);
  print('STABLE: ${t1.totalTokens == t2.totalTokens && t1.records == t2.records}');

  db.dispose();
}
