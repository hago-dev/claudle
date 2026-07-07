import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../../../domain/provider/usage_provider.dart';
import '../../ingest/ingest_service.dart';
import 'claude_path_resolver.dart';

/// Claude Code (`~/.claude/projects/**/*.jsonl`) provider.
///
/// 파싱/커서/디덤은 [IngestService] 에 위임하고, 여기선 소스 발견 + 실시간 감시만.
class ClaudeCodeUsageProvider implements UsageProvider {
  final IngestService ingest;
  final ClaudePathResolver resolver;

  final _subs = <StreamSubscription<WatchEvent>>[];
  final _dirty = <String>{};
  StreamController<void>? _out;
  Timer? _debounce;

  ClaudeCodeUsageProvider(this.ingest, {ClaudePathResolver? resolver})
      : resolver = resolver ?? ClaudePathResolver();

  @override
  String get id => 'claude-code';

  @override
  String get displayName => 'Claude Code';

  @override
  bool isAvailable() => resolver.resolveClaudeDirs().isNotEmpty;

  @override
  Future<void> backfill({void Function()? onProgress}) async {
    await ingest.backfillAsync(onBatch: (_) => onProgress?.call());
  }

  @override
  Stream<void> watch() {
    final out = _out = StreamController<void>.broadcast(onCancel: dispose);
    for (final dir in resolver.resolveClaudeDirs()) {
      final projects = p.join(dir, 'projects');
      // FSEvents 기반 재귀 감시. 기존 파일은 이벤트 안 나오고 변경분만.
      final w = DirectoryWatcher(projects);
      _subs.add(w.events.listen(_onEvent, onError: (_) {}));
    }
    return out.stream;
  }

  void _onEvent(WatchEvent e) {
    if (!e.path.endsWith('.jsonl')) return;
    if (e.type == ChangeType.REMOVE) return; // 과거 사용량 보존
    _dirty.add(e.path);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _flush);
  }

  void _flush() {
    final paths = _dirty.toList();
    _dirty.clear();
    var any = false;
    for (final path in paths) {
      final f = File(path);
      if (!f.existsSync()) continue;
      if (ingest.ingestSingle(f).recordsUpserted > 0) any = true;
    }
    if (any) _out?.add(null); // 신규 반영 → 총계 재계산 신호
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }
}
