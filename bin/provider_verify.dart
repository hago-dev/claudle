// P7 검증: 멀티 provider seam 이 end-to-end 로 동작하는가.
// Claude 코드를 건드리지 않는 stub provider 가, UsageProvider 인터페이스만으로
// **같은 DB→집계 경로**에 backfill·watch 로 도달함을 인메모리 DB 로 증명(실데이터 무오염).
// 실행: fvm dart run bin/provider_verify.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tokenbar/core/db/usage_database.dart';
import 'package:tokenbar/core/pricing/pricing_repository.dart';
import 'package:tokenbar/data/ingest/ingest_service.dart';
import 'package:tokenbar/data/providers/claude_code/claude_code_provider.dart';
import 'package:tokenbar/data/providers/stub/stub_provider.dart';
import 'package:tokenbar/domain/provider/usage_provider.dart';

Future<void> main() async {
  final db = UsageDatabase.memory();
  final bundled = json.decode(
    File('assets/pricing/litellm_claude.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final ingest =
      IngestService(db: db, pricing: PricingRepository.fromLiteLlm(bundled));

  final claude = ClaudeCodeUsageProvider(ingest);
  final stub = StubUsageProvider(db, enabled: true);
  final registry = ProviderRegistry([claude, stub]);

  print('등록된 provider: ${registry.providers.map((p) => p.id).toList()}');
  print('사용 가능: ${registry.available.map((p) => p.id).toList()}');
  print('claude-code available=${claude.isAvailable()} '
      '(실데이터 소스 존재 여부 — 이 머신에선 true 기대)');

  // 1) backfill: stub 이 인터페이스만으로 공유 DB 를 채우는가
  await stub.backfill();
  final t1 = db.totals();
  print('stub.backfill 후: records=${t1.records} '
      'tokens=${t1.totalTokens} cost=\$${t1.costUsd.toStringAsFixed(2)}');

  // 2) watch: 실시간 신호가 DB→집계에 반영되는가(~5s, 2s 주기 → ~2회)
  var signals = 0;
  final sub = stub.watch().listen((_) => signals++);
  await Future<void>.delayed(const Duration(milliseconds: 5200));
  await sub.cancel();
  final t2 = db.totals();
  print('stub.watch ~5s 후: signals=$signals '
      'records=${t2.records} tokens=${t2.totalTokens}');

  final pass = registry.available.any((p) => p.id == 'stub') &&
      t1.records >= 1 &&
      t2.records > t1.records &&
      signals >= 1;
  print('SEAM PASS: $pass  '
      '(stub 이 Claude 무관하게 인터페이스만으로 트레이까지의 DB→집계 경로에 도달)');

  stub.dispose();
  db.dispose();
  exit(pass ? 0 : 1);
}
