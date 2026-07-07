import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/db/usage_database.dart';
import '../../core/pricing/cost_calculator.dart';
import '../../core/pricing/pricing_repository.dart';
import 'package:tokenbar/data/providers/claude_code/claude_jsonl_parser.dart';
import 'package:tokenbar/data/providers/claude_code/claude_path_resolver.dart';

class IngestStats {
  final int filesScanned;
  final int filesChanged;
  final int bytesRead;
  final int recordsUpserted;
  const IngestStats(this.filesScanned, this.filesChanged, this.bytesRead,
      this.recordsUpserted);
  @override
  String toString() =>
      'files=$filesScanned changed=$filesChanged bytes=$bytesRead upserted=$recordsUpserted';
}

/// Claude Code JSONL 을 증분으로 읽어 DB 에 upsert.
///
/// 파일별 커서(size/mtime/byte_offset)로 **추가된 바이트만** tail.
/// 완전한 라인(마지막 개행까지)만 처리하고, 부분 라인은 다음 읽기로 넘긴다.
class IngestService {
  final UsageDatabase db;
  final PricingRepository pricing;
  final ClaudePathResolver resolver;
  final ClaudeJsonlParser parser;
  final CostCalculator calc;
  final int Function() _nowMs;

  IngestService({
    required this.db,
    required this.pricing,
    ClaudePathResolver? resolver,
    ClaudeJsonlParser? parser,
    this.calc = const CostCalculator(),
    int Function()? nowMs,
  })  : resolver = resolver ?? ClaudePathResolver(),
        parser = parser ?? ClaudeJsonlParser(),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 전체 backfill(증분): 변경된 파일의 추가분만 반영.
  IngestStats backfill() {
    final files = resolver.jsonlFiles();
    int changed = 0, bytes = 0, upserts = 0;
    db.transaction(() {
      for (final f in files) {
        final r = _ingestFile(f);
        if (r.bytesRead > 0) changed++;
        bytes += r.bytesRead;
        upserts += r.recordsUpserted;
      }
    });
    return IngestStats(files.length, changed, bytes, upserts);
  }

  /// 반응형 배치 백필: 배치마다 이벤트 루프에 yield 해서 UI/트레이가 멈추지 않게.
  /// [onBatch] 로 진행 상황(누적)을 통보 → 부분 갱신 가능.
  Future<IngestStats> backfillAsync({
    int batchSize = 40,
    void Function(IngestStats cumulative)? onBatch,
  }) async {
    final files = resolver.jsonlFiles();
    int changed = 0, bytes = 0, upserts = 0;
    for (var start = 0; start < files.length; start += batchSize) {
      final end =
          (start + batchSize < files.length) ? start + batchSize : files.length;
      db.transaction(() {
        for (var i = start; i < end; i++) {
          final r = _ingestFile(files[i]);
          if (r.bytesRead > 0) changed++;
          bytes += r.bytesRead;
          upserts += r.recordsUpserted;
        }
      });
      onBatch?.call(IngestStats(end, changed, bytes, upserts));
      await Future<void>.delayed(Duration.zero); // yield
    }
    return IngestStats(files.length, changed, bytes, upserts);
  }

  /// 단일 파일 반영(watcher 의 modify/add 이벤트에서 재사용). 반환: (bytesRead, upserts).
  ({int bytesRead, int recordsUpserted}) ingestSingle(File f) {
    late ({int bytesRead, int recordsUpserted}) r;
    db.transaction(() => r = _ingestFile(f));
    return r;
  }

  ({int bytesRead, int recordsUpserted}) _ingestFile(File f) {
    final path = f.path;
    final FileStat stat;
    try {
      stat = f.statSync();
    } catch (_) {
      return (bytesRead: 0, recordsUpserted: 0);
    }
    final size = stat.size;
    final mtimeMs = stat.modified.millisecondsSinceEpoch;
    final cursor = db.getCursor(path);

    int startOffset;
    if (cursor == null) {
      startOffset = 0;
    } else if (cursor.sizeBytes == size && cursor.mtimeMs == mtimeMs) {
      return (bytesRead: 0, recordsUpserted: 0); // 변경 없음(빠른 skip)
    } else if (size < cursor.sizeBytes) {
      startOffset = 0; // 잘림/교체 → 전체 재파싱
    } else {
      startOffset = cursor.byteOffset; // 추가분만
    }

    if (startOffset >= size) {
      db.putCursor(path, size, mtimeMs, startOffset, _nowMs());
      return (bytesRead: 0, recordsUpserted: 0);
    }

    final Uint8List data;
    try {
      final raf = f.openSync(mode: FileMode.read);
      raf.setPositionSync(startOffset);
      data = raf.readSync(size - startOffset);
      raf.closeSync();
    } catch (_) {
      return (bytesRead: 0, recordsUpserted: 0);
    }

    final project = ClaudePathResolver.projectFromPath(path);
    int upserts = 0;
    int lineStart = 0; // data 내 상대 offset
    int lastNewline = -1;
    const nl = 0x0A;
    for (int i = 0; i < data.length; i++) {
      if (data[i] != nl) continue;
      final lineBytes = data.sublist(lineStart, i); // 개행 제외
      final byteOffsetInFile = startOffset + lineStart;
      upserts += _processLine(lineBytes, byteOffsetInFile, path, project);
      lastNewline = i;
      lineStart = i + 1;
    }

    // 커서는 마지막 완전한 라인(개행)까지만 전진. 부분 라인은 다음 읽기로.
    final newOffset =
        lastNewline >= 0 ? startOffset + lastNewline + 1 : startOffset;
    db.putCursor(path, size, mtimeMs, newOffset, _nowMs());
    return (bytesRead: data.length, recordsUpserted: upserts);
  }

  int _processLine(
      Uint8List lineBytes, int byteOffsetInFile, String path, String? project) {
    if (lineBytes.isEmpty) return 0;
    final line = utf8.decode(lineBytes, allowMalformed: true);
    final e = parser.parseLine(line, sourceRef: path, project: project);
    if (e == null) return 0;
    // dedupKey 없으면 (path,byteOffset) 합성키 — 재파싱에도 안정(idempotent).
    final key = e.dedupKey ?? 'nk:$path:$byteOffsetInFile';
    final cost = calc.cost(e, pricing.resolve(e.model));
    return db.upsertEvent(e, dedupKey: key, cost: cost) ? 1 : 0;
  }
}
