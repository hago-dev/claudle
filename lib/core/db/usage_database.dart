import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/usage_event.dart';
import '../util/project_root.dart';

/// 파일 증분 파싱 커서.
class FileCursor {
  final String path;
  final int sizeBytes;
  final int mtimeMs;
  final int byteOffset;
  const FileCursor(this.path, this.sizeBytes, this.mtimeMs, this.byteOffset);
}

/// 집계 결과 한 줄.
class UsageTotals {
  final int inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens;
  final double costUsd;
  final int records;
  const UsageTotals({
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheCreationTokens,
    required this.cacheReadTokens,
    required this.costUsd,
    required this.records,
  });
  int get totalTokens =>
      inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens;
}

/// 일자별 집계 한 칸(로컬 날짜).
class DayBucket {
  final String day; // 'YYYY-MM-DD' (로컬)
  final int tokens;
  final double cost;
  const DayBucket(this.day, this.tokens, this.cost);
}

/// 그룹(모델/프로젝트)별 집계 한 줄.
class GroupRow {
  final String key; // 그룹 키(모델명 / 프로젝트 루트 경로) — alias·rename 식별용
  final String label; // 표시명(프로젝트: alias > 디렉토리명 > 원본)
  final int tokens;
  final double cost;
  final int records;
  const GroupRow(this.key, this.label, this.tokens, this.cost, this.records);
}

/// 사용량 이벤트 + 증분 커서 영속화(sqlite3). codegen 없음.
class UsageDatabase {
  final Database db;

  UsageDatabase(this.db) {
    _migrate();
  }

  factory UsageDatabase.open(String path) => UsageDatabase(sqlite3.open(path));
  factory UsageDatabase.memory() => UsageDatabase(sqlite3.openInMemory());

  void _migrate() {
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS file_cursor(
        path TEXT PRIMARY KEY,
        size_bytes INTEGER NOT NULL,
        mtime_ms INTEGER NOT NULL,
        byte_offset INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS usage_event(
        dedup_key TEXT PRIMARY KEY,
        provider_id TEXT NOT NULL,
        ts_utc_ms INTEGER NOT NULL,
        model TEXT NOT NULL,
        project TEXT,
        session_id TEXT,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL,
        cache_read_tokens INTEGER NOT NULL,
        cache_creation_5m INTEGER NOT NULL,
        cache_creation_1h INTEGER NOT NULL,
        cost_usd REAL NOT NULL,
        source_ref TEXT NOT NULL,
        cwd TEXT,
        project_root TEXT
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_event(ts_utc_ms);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_event(model);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_usage_project ON usage_event(project);');
    // 사용자 지정 프로젝트 별칭(내장 저장소). project(인코딩 키) → alias.
    db.execute('''
      CREATE TABLE IF NOT EXISTS project_alias(
        project TEXT PRIMARY KEY,
        alias TEXT NOT NULL
      );
    ''');
    _migrateCwd();
    _migrateProjectRoot();
  }

  /// 기존 설치엔 usage_event.cwd 컬럼이 없을 수 있음 → 추가하고 재수집을 위해
  /// 이벤트/커서를 비운다(로그에서 재파생 가능, ~1-2s). keep-max WHERE 때문에
  /// 재백필로는 기존 행의 cwd 가 안 채워지므로 깨끗이 비우는 게 정답.
  void _migrateCwd() {
    final cols = db.select('PRAGMA table_info(usage_event)');
    final hasCwd = cols.any((r) => r['name'] == 'cwd');
    if (hasCwd) return;
    db.execute('ALTER TABLE usage_event ADD COLUMN cwd TEXT');
    db.execute('DELETE FROM usage_event');
    db.execute('DELETE FROM file_cursor');
  }

  /// project_root 컬럼(프로젝트 루트를 ingest 시 미리 계산·저장 → 대시보드 표시
  /// 경로의 파일시스템 I/O 제거). 없으면 추가 후 재수집을 위해 비운다(~1-2s).
  /// 단가표가 갱신됐을 때도 이 재백필로 비용이 함께 재계산된다.
  void _migrateProjectRoot() {
    final cols = db.select('PRAGMA table_info(usage_event)');
    final has = cols.any((r) => r['name'] == 'project_root');
    if (has) return;
    db.execute('ALTER TABLE usage_event ADD COLUMN project_root TEXT');
    db.execute('DELETE FROM usage_event');
    db.execute('DELETE FROM file_cursor');
  }

  // ── cursor ──────────────────────────────────────────────
  FileCursor? getCursor(String path) {
    final r = db.select(
        'SELECT size_bytes,mtime_ms,byte_offset FROM file_cursor WHERE path=?',
        [path]);
    if (r.isEmpty) return null;
    final row = r.first;
    return FileCursor(path, row['size_bytes'] as int, row['mtime_ms'] as int,
        row['byte_offset'] as int);
  }

  void putCursor(String path, int size, int mtimeMs, int byteOffset, int nowMs) {
    db.execute(
      '''INSERT INTO file_cursor(path,size_bytes,mtime_ms,byte_offset,updated_at_ms)
         VALUES(?,?,?,?,?)
         ON CONFLICT(path) DO UPDATE SET
           size_bytes=excluded.size_bytes, mtime_ms=excluded.mtime_ms,
           byte_offset=excluded.byte_offset, updated_at_ms=excluded.updated_at_ms''',
      [path, size, mtimeMs, byteOffset, nowMs],
    );
  }

  // ── upsert (keep-max output) ────────────────────────────
  /// dedup 정책: 같은 [dedupKey] 는 output 이 더 큰(=최종) 레코드만 채택.
  /// 반환: 실제로 삽입/갱신됐으면 true.
  bool upsertEvent(UsageEvent e,
      {required String dedupKey, required double cost}) {
    // 프로젝트 루트는 ingest 시 1회 계산·저장(표시 경로에서 FS I/O 하지 않기 위함).
    final projectRoot = e.cwd == null ? null : projectRootOf(e.cwd!);
    db.execute(
      '''INSERT INTO usage_event(dedup_key,provider_id,ts_utc_ms,model,project,session_id,
           input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,
           cache_creation_5m,cache_creation_1h,cost_usd,source_ref,cwd,project_root)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
         ON CONFLICT(dedup_key) DO UPDATE SET
           provider_id=excluded.provider_id, ts_utc_ms=excluded.ts_utc_ms,
           model=excluded.model, project=excluded.project, session_id=excluded.session_id,
           input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
           cache_creation_tokens=excluded.cache_creation_tokens,
           cache_read_tokens=excluded.cache_read_tokens,
           cache_creation_5m=excluded.cache_creation_5m,
           cache_creation_1h=excluded.cache_creation_1h,
           cost_usd=excluded.cost_usd, source_ref=excluded.source_ref,
           cwd=excluded.cwd, project_root=excluded.project_root
         WHERE excluded.output_tokens > usage_event.output_tokens''',
      [
        dedupKey,
        e.providerId,
        e.timestampUtc.millisecondsSinceEpoch,
        e.model,
        e.project,
        e.sessionId,
        e.inputTokens,
        e.outputTokens,
        e.cacheCreationTokens,
        e.cacheReadTokens,
        e.cacheCreation5mTokens,
        e.cacheCreation1hTokens,
        cost,
        e.sourceRef,
        e.cwd,
        projectRoot,
      ],
    );
    // sqlite3_changes(): 이 upsert 가 실제로 삽입/갱신한 행 수.
    // 신규 삽입·갱신=1, keep-max WHERE 로 무시된 중복=0. (문장당 값이라 누적 비교 금물)
    return db.updatedRows > 0;
  }

  void transaction(void Function() body) {
    db.execute('BEGIN');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── aggregation ─────────────────────────────────────────
  /// 기간 WHERE 절: [fromMs] 이상(포함) ~ [toMs] 미만. 둘 다 epoch ms.
  static String _periodWhere(int? fromMs, int? toMs) {
    final c = <String>[];
    if (fromMs != null) c.add('ts_utc_ms >= $fromMs');
    if (toMs != null) c.add('ts_utc_ms < $toMs');
    return c.isEmpty ? '' : 'WHERE ${c.join(' AND ')}';
  }

  UsageTotals totals() => totalsBetween();

  /// [fromMsEpoch] 이후(포함) 이벤트만. 오늘 집계 = 로컬 자정의 epoch ms.
  UsageTotals totalsSince(int fromMsEpoch) => totalsBetween(fromMs: fromMsEpoch);

  /// [fromMs] 이상 ~ [toMs] 미만(둘 다 옵션). 커스텀 기간 조회용.
  UsageTotals totalsBetween({int? fromMs, int? toMs}) =>
      _totalsWhere(_periodWhere(fromMs, toMs));

  UsageTotals _totalsWhere(String where) {
    final r = db.select('''
      SELECT
        COALESCE(SUM(input_tokens),0) i, COALESCE(SUM(output_tokens),0) o,
        COALESCE(SUM(cache_creation_tokens),0) cc, COALESCE(SUM(cache_read_tokens),0) cr,
        COALESCE(SUM(cost_usd),0.0) cost, COUNT(*) n
      FROM usage_event $where''');
    final row = r.first;
    return UsageTotals(
      inputTokens: row['i'] as int,
      outputTokens: row['o'] as int,
      cacheCreationTokens: row['cc'] as int,
      cacheReadTokens: row['cr'] as int,
      costUsd: (row['cost'] as num).toDouble(),
      records: row['n'] as int,
    );
  }

  // ── grouped aggregation (대시보드) ──────────────────────
  static const _tokSum =
      'input_tokens+output_tokens+cache_creation_tokens+cache_read_tokens';

  /// 최근 [days] 일(로컬 날짜) 버킷. 오래→최신 순으로 반환(차트 x축용).
  List<DayBucket> dailyBuckets({int days = 30}) {
    final r = db.select('''
      SELECT date(ts_utc_ms/1000,'unixepoch','localtime') d,
             SUM($_tokSum) toks, SUM(cost_usd) cost
      FROM usage_event
      GROUP BY d ORDER BY d DESC LIMIT ?''', [days]);
    final out = r
        .map((row) => DayBucket(row['d'] as String,
            (row['toks'] as num).toInt(), (row['cost'] as num).toDouble()))
        .toList();
    return out.reversed.toList();
  }

  List<GroupRow> byModel({int limit = 20, int? fromMs, int? toMs}) {
    final where = _periodWhere(fromMs, toMs);
    final r = db.select('''
      SELECT COALESCE(model,'') g, SUM($_tokSum) toks,
             SUM(cost_usd) cost, COUNT(*) n
      FROM usage_event $where
      GROUP BY g ORDER BY cost DESC LIMIT ?''', [limit]);
    return r.map((row) {
      final g = row['g'] as String;
      final label = g.isEmpty ? '(모델 미상)' : g;
      return GroupRow(g, label, (row['toks'] as num).toInt(),
          (row['cost'] as num).toDouble(), row['n'] as int);
    }).toList();
  }

  /// 프로젝트별 — ingest 시 저장된 **project_root**(git 저장소 루트)로 SQL 그룹핑.
  /// 하위 폴더에서 실행한 cwd 들이 한 프로젝트로 합산된다(표시 경로엔 FS I/O 없음).
  /// 표시명 = alias > 루트 디렉토리명 > (미상). [fromMs]~[toMs] 기간 필터.
  List<GroupRow> byProject({int limit = 20, int? fromMs, int? toMs}) {
    final aliases = aliasMap();
    final where = _periodWhere(fromMs, toMs);
    final r = db.select('''
      SELECT COALESCE(project_root, project, '') g, SUM($_tokSum) toks,
             SUM(cost_usd) cost, COUNT(*) n
      FROM usage_event $where
      GROUP BY g ORDER BY cost DESC LIMIT ?''', [limit]);
    return r.map((row) {
      final key = row['g'] as String;
      final label = aliases[key] ??
          _dirName(key) ??
          (key.isEmpty ? '(프로젝트 미상)' : key);
      return GroupRow(key, label, (row['toks'] as num).toInt(),
          (row['cost'] as num).toDouble(), row['n'] as int);
    }).toList();
  }

  /// 경로에서 마지막 디렉토리명. 예: '/Users/me/Desktop/project/sso-api' → 'sso-api'.
  /// 구분자는 `/`(POSIX)·`\`(Windows) 모두 허용.
  static String? _dirName(String? cwd) {
    if (cwd == null || cwd.isEmpty) return null;
    final parts =
        cwd.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.last;
  }

  // ── project alias (내장 저장소) ─────────────────────────
  Map<String, String> aliasMap() {
    final r = db.select('SELECT project,alias FROM project_alias');
    return {
      for (final row in r) row['project'] as String: row['alias'] as String,
    };
  }

  /// 별칭 지정. 빈 문자열이면 별칭 제거(원래 디렉토리명으로 복귀).
  void setAlias(String project, String alias) {
    final a = alias.trim();
    if (a.isEmpty) {
      db.execute('DELETE FROM project_alias WHERE project=?', [project]);
      return;
    }
    db.execute(
      '''INSERT INTO project_alias(project,alias) VALUES(?,?)
         ON CONFLICT(project) DO UPDATE SET alias=excluded.alias''',
      [project, a],
    );
  }

  void dispose() => db.dispose();
}
