import 'dart:io';

import 'package:tokenbar/core/db/usage_database.dart';
import 'package:tokenbar/core/util/project_root.dart';

/// 실행 중인 앱의 usage.db 스냅샷을 복사해 열고:
///  1) cwd → 프로젝트 루트 접힘(하위 폴더가 프로젝트 단위로 합쳐지는지)
///  2) 병합 무결성 불변식: Σ byProject.records == totals.records (유실/중복 0)
///  3) 기간별 조회 단조성(오늘 ≤ 7일 ≤ 30일 ≤ 전체)
/// 을 검증한다. (WAL 스냅샷을 복사해 라이브 라이터와 분리)
void main() {
  final home = Platform.environment['HOME']!;
  final src =
      '$home/Library/Application Support/dev.shimkijun.tokenbar/usage.db';
  final tmp =
      '${Directory.systemTemp.path}/tokenbar_verify_${DateTime.now().microsecondsSinceEpoch}.db';
  for (final suffix in ['', '-wal', '-shm']) {
    final f = File('$src$suffix');
    if (f.existsSync()) f.copySync('$tmp$suffix');
  }
  final db = UsageDatabase.open(tmp);

  final total = db.totals();
  print('=== TOTALS(전체) ===');
  print('records=${total.records}  '
      'cost=\$${total.costUsd.toStringAsFixed(2)}  tokens=${total.totalTokens}');

  // (2) 병합 무결성: 무제한 byProject 의 records/tokens 합 == 전체.
  final allProjects = db.byProject(limit: 1000000);
  final sumRec = allProjects.fold<int>(0, (a, r) => a + r.records);
  final sumTok = allProjects.fold<int>(0, (a, r) => a + r.tokens);
  print('\n=== 불변식 byProject (병합 무결성) ===');
  print('projects=${allProjects.length}  Σrecords=$sumRec '
      '(기대 ${total.records}) ${sumRec == total.records ? "OK" : "MISMATCH"}');
  print('Σtokens=$sumTok '
      '(기대 ${total.totalTokens}) ${sumTok == total.totalTokens ? "OK" : "MISMATCH"}');

  final allModels = db.byModel(limit: 1000000);
  final sumMrec = allModels.fold<int>(0, (a, r) => a + r.records);
  print('\n=== 불변식 byModel ===');
  print('models=${allModels.length}  Σrecords=$sumMrec '
      '(기대 ${total.records}) ${sumMrec == total.records ? "OK" : "MISMATCH"}');

  // (1) cwd → 프로젝트 루트 접힘.
  print('\n=== cwd → projectRoot (상위 프로젝트로 접힘) ===');
  final cwds = db.db.select(
      "SELECT DISTINCT cwd FROM usage_event WHERE cwd IS NOT NULL ORDER BY cwd");
  final roots = <String>{};
  for (final row in cwds) {
    final cwd = row['cwd'] as String;
    final root = projectRootOf(cwd);
    roots.add(root);
    if (cwd != root) print('  $cwd\n      → $root');
  }
  print('distinct cwd=${cwds.length}  distinct root=${roots.length}  '
      '(접힌 하위폴더 ${cwds.length - roots.length}건)');

  print('\n=== 프로젝트별 TOP (전체) ===');
  for (final r in db.byProject(limit: 12)) {
    print('  ${r.label.padRight(22)} '
        '\$${r.cost.toStringAsFixed(2).padLeft(9)}  ${r.records} rec');
  }

  // (3) 기간별 단조성.
  final now = DateTime.now();
  final todayMs = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final wMs = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
  final mMs = now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
  final t = db.totalsSince(todayMs);
  final w = db.totalsSince(wMs);
  final m = db.totalsSince(mMs);
  print('\n=== 기간별 조회 ===');
  print('오늘  \$${t.costUsd.toStringAsFixed(2).padLeft(9)}  ${t.records} rec');
  print('7일   \$${w.costUsd.toStringAsFixed(2).padLeft(9)}  ${w.records} rec');
  print('30일  \$${m.costUsd.toStringAsFixed(2).padLeft(9)}  ${m.records} rec');
  print('전체  \$${total.costUsd.toStringAsFixed(2).padLeft(9)}  ${total.records} rec');
  final mono = t.records <= w.records &&
      w.records <= m.records &&
      m.records <= total.records;
  print('단조 증가(오늘≤7일≤30일≤전체): ${mono ? "OK" : "FAIL"}');

  // byProject(기간) 합 == 그 기간 totals (기간 필터 정합성).
  final projToday = db.byProject(limit: 1000000, fromMs: todayMs);
  final sumProjToday = projToday.fold<int>(0, (a, r) => a + r.records);
  print('byProject(오늘) Σrec=$sumProjToday == totalsSince(오늘).rec=${t.records} '
      ': ${sumProjToday == t.records ? "OK" : "MISMATCH"}');

  db.dispose();
  for (final suffix in ['', '-wal', '-shm']) {
    final f = File('$tmp$suffix');
    if (f.existsSync()) f.deleteSync();
  }
  print('\nDONE');
}
