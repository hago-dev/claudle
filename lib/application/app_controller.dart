import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/db/usage_database.dart';
import '../core/pricing/pricing_repository.dart';
import '../data/ingest/ingest_service.dart';
import '../data/limits/real_limits_source.dart';
import '../data/providers/claude_code/claude_code_provider.dart';
import '../data/providers/claude_code/claude_path_resolver.dart';
import '../data/providers/claude_code/context_gauge_reader.dart';
import '../data/providers/stub/stub_provider.dart';
import '../data/statusline/statusline_installer.dart';
import '../domain/models/context_gauge.dart';
import '../domain/models/subscription_limits.dart';
import '../domain/provider/usage_provider.dart';
import 'context_gauge_controller.dart';
import 'limits_controller.dart';

/// 앱 상태 라벨(메뉴바 툴팁/대시보드용).
enum AppPhase { starting, scanning, watching, error }

/// DB + provider 레지스트리를 소유하는 단일 컨트롤러.
///
/// **Deep Module**: provider 가 "어떻게" 소스를 읽는지는 모른다 — 등록된
/// [UsageProvider] 들을 backfill/watch 하고, 신호가 오면 총계를 다시 읽을 뿐.
/// (riverpod 대신 plain ValueNotifier — §2 단순함.)
class AppController {
  final ClaudePathResolver resolver;
  AppController({ClaudePathResolver? resolver})
      : resolver = resolver ?? ClaudePathResolver();

  late final UsageDatabase _db;
  late final ProviderRegistry _registry;

  // 구독 한도(헤드라인): Claude OAuth usage 엔드포인트. 폴링 60s(내부 API 보호).
  final LimitsController limitsController = LimitsController(
    RealLimitsSource(),
    interval: const Duration(seconds: 60),
  );

  // 컨텍스트 게이지: statusline 이 덤프한 페이로드 폴링(로컬 파일 1개).
  // 훅 배선도 이 컨트롤러가 맡는다 — 사용자가 settings.json 을 손댈 일이 없게.
  late final ContextGaugeController contextGaugeController =
      ContextGaugeController(
    ContextGaugeReader(resolver: resolver),
    StatuslineInstaller(resolver: resolver),
  );

  final ValueNotifier<UsageTotals?> totalsAll = ValueNotifier(null);
  final ValueNotifier<UsageTotals?> totalsToday = ValueNotifier(null);
  final ValueNotifier<AppPhase> phase = ValueNotifier(AppPhase.starting);
  final ValueNotifier<String> status = ValueNotifier('시작 중…');
  // 총계 변화 없이 대시보드만 다시 그려야 할 때(예: 프로젝트 별칭 변경).
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// 별칭 등 표시용 변경 후 대시보드 리빌드 트리거.
  void bumpRevision() => revision.value++;

  ValueNotifier<SubscriptionLimits?> get limits => limitsController.limits;
  ValueNotifier<Map<String, ContextGauge>> get contextGauges =>
      contextGaugeController.gauges;

  final _subs = <StreamSubscription<void>>[];
  bool _started = false;

  UsageDatabase get db => _db;
  ProviderRegistry get registry => _registry;

  /// DB 오픈 → 단가 로드 → provider 등록 → backfill → 감시. 재진입 방지.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final dbPath = p.join(supportDir.path, 'usage.db');
      _db = UsageDatabase.open(dbPath);

      final pricingJson =
          await rootBundle.loadString('assets/pricing/litellm_claude.json');
      final pricing = PricingRepository.fromLiteLlm(
        json.decode(pricingJson) as Map<String, dynamic>,
      );
      final ingest =
          IngestService(db: _db, pricing: pricing, resolver: resolver);

      // provider 등록(확장점): 여기 한 줄 추가로 새 소스가 트레이까지 흐른다.
      _registry = ProviderRegistry([
        ClaudeCodeUsageProvider(ingest, resolver: resolver),
        StubUsageProvider(_db,
            enabled: Platform.environment['TOKENBAR_STUB'] == '1'),
      ]);

      // 구독 한도 폴링 시작(토큰 집계와 독립 — 헤드라인).
      unawaited(limitsController.start());
      contextGaugeController.start();

      phase.value = AppPhase.scanning;
      status.value = '로그 분석 중…';
      _refresh(); // 기존 DB가 있으면 즉시 이전 총계 표시

      final providers = _registry.available.toList();
      for (final provider in providers) {
        await provider.backfill(onProgress: _refresh);
      }

      for (final provider in providers) {
        _subs.add(provider.watch().listen((_) => _refresh()));
      }
      phase.value = AppPhase.watching;
      final names = providers.map((p) => p.displayName).join(', ');
      status.value = '실시간 감시 중 · $names';
      _refresh();
    } catch (e, st) {
      phase.value = AppPhase.error;
      status.value = '오류: $e';
      debugPrint('[app] start ERROR: $e\n$st');
    }
  }

  /// 로컬 자정 epoch ms(오늘 집계 경계).
  int get _todayStartMs {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  }

  void _refresh() {
    totalsAll.value = _db.totals();
    totalsToday.value = _db.totalsSince(_todayStartMs);
  }

  void dispose() {
    limitsController.dispose();
    contextGaugeController.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    if (_started) {
      for (final provider in _registry.providers) {
        provider.dispose();
      }
      _db.dispose();
    }
    totalsAll.dispose();
    totalsToday.dispose();
    phase.dispose();
    status.dispose();
    revision.dispose();
  }
}
