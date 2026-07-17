import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/providers/claude_code/context_gauge_reader.dart';
import '../data/statusline/statusline_installer.dart';
import '../domain/models/context_gauge.dart';

/// 컨텍스트 게이지를 주기적으로 읽어 [gauge] 로 노출하고, 소스(statusline 훅)의
/// 배선까지 책임진다. 대시보드가 구독.
///
/// **Deep Module**: 화면은 `gauge`/`hint`/`canEnable`/[enable] 만 안다 — statusline·
/// settings.json·플랫폼 분기는 [StatuslineInstaller] 뒤에 숨는다.
///
/// 값이 실제로 변했을 때만 통지한다 — 폴링 틱마다 리빌드하지 않게.
/// (읽는 건 1KB 짜리 파일 하나라 보이는 동안만 돌릴 필요는 없다.)
class ContextGaugeController {
  final ContextGaugeReader reader;
  final StatuslineInstaller installer;
  final Duration interval;

  /// 세션id → 게이지. 화면은 제가 그리는 캐릭터의 sessionId 로 조회한다.
  final ValueNotifier<Map<String, ContextGauge>> gauges = ValueNotifier(
    const {},
  );

  /// 게이지가 하나도 없을 때 보여줄 안내. 흐르고 있으면 null.
  final ValueNotifier<String?> hint = ValueNotifier(null);

  /// 훅을 깔 수 있는 상태인가(=켜기 버튼을 줄지).
  final ValueNotifier<bool> canEnable = ValueNotifier(false);

  Timer? _timer;

  ContextGaugeController(
    this.reader,
    this.installer, {
    this.interval = const Duration(seconds: 2),
  });

  void start() {
    // 앱이 업데이트되면 깔린 스크립트도 따라와야 한다 — 사본 드리프트 방지.
    try {
      installer.syncScript();
    } on Object catch (e) {
      debugPrint('[gauge] syncScript 실패(무시): $e');
    }
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// statusline 훅을 배선한다. 실패 사유는 [hint] 로 노출.
  void enable() {
    try {
      installer.install();
      hint.value = '켰습니다 — Claude Code 를 새로 띄우면 게이지가 채워집니다.';
    } on Object catch (e) {
      hint.value = '켜지 못했습니다: $e';
    }
    canEnable.value = false;
  }

  void _tick() {
    final next = reader.readAll();
    if (!_same(gauges.value, next)) gauges.value = next;
    if (next.isNotEmpty) {
      hint.value = null;
      canEnable.value = false;
      return;
    }
    // 게이지가 없다 — 왜인지 배선 상태로 설명한다.
    switch (installer.check()) {
      case StatuslineState.notInstalled:
        hint.value = '컨텍스트 게이지가 꺼져 있습니다 — 켜면 auto-compact 까지 남은 양이 보입니다.';
        canEnable.value = true;
      case StatuslineState.foreign:
        hint.value = '이미 다른 statusLine 이 설정돼 있어 건드리지 않았습니다.';
        canEnable.value = false;
      case StatuslineState.installed:
        // 배선은 됐는데 덤프가 없다 = CC 가 훅을 아직 안 돌렸다. 실행 중인 세션은
        // 설정을 다시 읽지 않으므로 "열리면"이 아니라 "새로 띄우면"이라고 해야 한다.
        hint.value = '게이지 대기 중 — Claude Code 를 새로 띄우면 채워집니다.';
        canEnable.value = false;
      case StatuslineState.unavailable:
        hint.value = 'Claude Code 설정을 찾지 못했습니다.';
        canEnable.value = false;
    }
  }

  /// 값이 같은가 — 틱마다 새 객체가 나오므로 필드로 비교해야 리빌드를 막을 수 있다.
  static bool _same(Map<String, ContextGauge> a, Map<String, ContextGauge> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final o = b[e.key];
      if (o == null ||
          o.usedTokens != e.value.usedTokens ||
          o.windowSize != e.value.windowSize ||
          o.pctOverride != e.value.pctOverride) {
        return false;
      }
    }
    return true;
  }

  void dispose() {
    _timer?.cancel();
    gauges.dispose();
    hint.dispose();
    canEnable.dispose();
  }
}
