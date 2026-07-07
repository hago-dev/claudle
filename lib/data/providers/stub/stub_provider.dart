import 'dart:async';

import '../../../core/db/usage_database.dart';
import '../../../domain/models/usage_event.dart';
import '../../../domain/provider/usage_provider.dart';

/// seam 증명용 데모 provider. Claude 코드를 전혀 건드리지 않고
/// **같은 DB→집계→트레이 경로**로 가짜 이벤트를 흘려 확장 구조를 실증한다.
///
/// 기본 비활성([enabled]=false). `TOKENBAR_STUB=1` 일 때만 켜서 실데이터와 섞이지 않게.
/// 모든 행은 `provider_id='stub'` 이라 식별·삭제 가능.
class StubUsageProvider implements UsageProvider {
  final UsageDatabase db;
  final bool enabled;
  final int Function() _nowMs;

  Timer? _timer;
  StreamController<void>? _out;
  int _seq = 0;

  StubUsageProvider(
    this.db, {
    this.enabled = false,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  @override
  String get id => 'stub';

  @override
  String get displayName => '데모(가짜)';

  @override
  bool isAvailable() => enabled;

  @override
  Future<void> backfill({void Function()? onProgress}) async {
    _emitEvent();
    onProgress?.call();
  }

  /// 켜져 있으면 2초마다 가짜 이벤트 1건 추가 → 신호. (라이브 트레이 상승 실증)
  @override
  Stream<void> watch() {
    final out = _out = StreamController<void>.broadcast();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_emitEvent()) _out?.add(null);
    });
    return out.stream;
  }

  bool _emitEvent() {
    _seq++;
    final e = UsageEvent(
      providerId: id,
      timestampUtc:
          DateTime.fromMillisecondsSinceEpoch(_nowMs(), isUtc: true),
      model: 'stub-demo',
      project: 'stub',
      cwd: '/stub',
      sessionId: 'stub-session',
      inputTokens: 1000,
      outputTokens: 500,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      cacheCreation5mTokens: 0,
      cacheCreation1hTokens: 0,
      dedupKey: 'stub:$_seq',
      reportedCostUsd: 0.01,
      sourceRef: 'stub',
    );
    return db.upsertEvent(e, dedupKey: e.dedupKey!, cost: e.reportedCostUsd!);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _out?.close();
    _out = null;
  }
}
