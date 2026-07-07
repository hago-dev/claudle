import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/limits/limits_source.dart';
import '../domain/models/subscription_limits.dart';

/// 구독 한도를 주기적으로 조달해 [limits] 로 노출. 트레이/대시보드가 구독.
///
/// 소스 구현은 모른다([LimitsSource] seam). 카운트다운은 resetsAt 로 표시 시 계산하므로
/// 폴링 간격보다 촘촘히 틱하지 않아도 된다(기본 30s).
class LimitsController {
  final LimitsSource source;
  final Duration interval;

  final ValueNotifier<SubscriptionLimits?> limits = ValueNotifier(null);
  final ValueNotifier<String> status = ValueNotifier('한도 조회 대기');

  Timer? _timer;

  LimitsController(this.source,
      {this.interval = const Duration(seconds: 30)});

  Future<void> start() async {
    if (!await source.isAvailable()) {
      status.value = '한도 소스 없음';
      return;
    }
    await _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    try {
      final v = await source.fetch();
      if (v != null) {
        limits.value = v;
        status.value = '한도 갱신됨';
      }
    } catch (e) {
      // 실패 사유를 상태로 노출(예: '로그인 필요', 'HTTP 401'). 토큰은 로그에 안 남음.
      status.value = '한도 조회 실패: $e';
      debugPrint('[limits] fetch error: $e');
    }
  }

  void dispose() {
    _timer?.cancel();
    limits.dispose();
    status.dispose();
  }
}
