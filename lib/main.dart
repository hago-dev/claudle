import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'application/app_controller.dart';
import 'core/util/format.dart';
import 'presentation/dashboard.dart';

/// Windows 는 우측 상단 항상-위 미니 패널(HUD)로 동작 — 트레이 아이콘이 오버플로에 숨는
/// 문제를 우회하고 사용량을 화면에 상시 표시. macOS 는 메뉴바 전용(창 숨김).
/// `TOKENBAR_FORCE_HUD=1` 로 macOS 에서도 패널을 미리볼 수 있다(개발/검증용).
bool get hudMode =>
    Platform.isWindows || Platform.environment['TOKENBAR_FORCE_HUD'] == '1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  if (hudMode) {
    // 항상-위 프레임리스 미니 패널을 우측 상단에 띄운 채 시작.
    const windowOptions = WindowOptions(
      size: Size(340, 360),
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
      title: 'Claudle',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setAlignment(Alignment.topRight);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setPreventClose(true); // 닫기 → 종료 대신 숨김
      await windowManager.show();
    });
  } else {
    // 메뉴바 전용 앱: 창은 숨긴 채로 시작(LSUIElement=1 → Dock 아이콘 없음).
    const windowOptions = WindowOptions(
      size: Size(460, 620),
      center: true,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.normal,
      title: 'Claudle',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true); // 닫기 → 종료 대신 숨김
      await windowManager.hide();
    });
  }

  runApp(const ClaudleApp());
}

/// 생기 있는 다크 테마(칙칙한 기본 회색 탈피): 선명한 바이올렛 시드에서
/// 파생한 컬러 스킴 + 둥근 카드.
ThemeData tokenBarTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF7C5CFF), // 선명한 바이올렛
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: EdgeInsets.zero,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
  );
}

class ClaudleApp extends StatefulWidget {
  const ClaudleApp({super.key});

  @override
  State<ClaudleApp> createState() => _ClaudleAppState();
}

class _ClaudleAppState extends State<ClaudleApp>
    with TrayListener, WindowListener {
  final AppController _controller = AppController();

  // 메뉴바 러닝 푸들 애니메이션: 프레임(6) 순환 + 사용량%만큼 바이올렛 채움.
  // 최적화: "달린다 = Claude 사용 중". 최근 인제스트 활동이 있을 때만 프레임을
  // 돌리고, 유휴 시엔 쉬는 포즈로 고정 + 동일 아이콘 재설정 생략(IPC 0).
  static const _dogFrames = 6;
  static const _idleAfter = Duration(seconds: 8);
  Timer? _dogTimer;
  int _dogFrame = 0;
  String? _lastIconPath; // 직전 setIcon 경로(중복 호출 차단)
  DateTime _lastActivity = DateTime.now(); // 마지막 사용 시각(부팅 직후엔 잠깐 달림)

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _controller.limits.addListener(_updateTrayTitle); // 헤드라인: 세션 한도
    _controller.limits.addListener(_updateTrayTooltip); // 툴팁: 리셋 예정 시각
    _controller.totalsToday.addListener(_onTotals); // 폴백 텍스트 + 활동 감지
    _controller.phase.addListener(_updateTrayTooltip);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _initTray();
    _startDogAnimation(); // 러닝 푸들 시작
    await _controller.start(); // DB·backfill·감시 시작(총계 → 트레이 라이브 갱신)
  }

  /// 현재 세션 사용량%를 10% 버킷으로(0,10,…,100) — 아이콘 바이올렛 채움 높이.
  int _fillBucket() {
    final s = _controller.limits.value?.session;
    if (s == null) return 0;
    final pct = s.usedPercent.clamp(0, 100);
    return (pct / 10).round() * 10;
  }

  /// 현재 (프레임 × 채움) 매트릭스 에셋으로 트레이 아이콘 갱신.
  /// 경로가 직전과 같으면 건너뜀 — 유휴 정지 상태에서 IPC 를 0 으로.
  /// Windows 트레이는 `LoadImage(IMAGE_ICON)` 이라 `.ico` 만 로드된다(PNG 실패) → 확장자 분기.
  Future<void> _setDogIcon() async {
    final ext = Platform.isWindows ? 'ico' : 'png';
    final path = 'assets/tray/run/run_${_dogFrame}_${_fillBucket()}.$ext';
    if (path == _lastIconPath) return;
    _lastIconPath = path;
    await trayManager.setIcon(path, isTemplate: false);
  }

  /// 활동(=사용) 감지: 최신 토큰이 들어오면 시각 도장 → 강아지가 달린다.
  void _onTotals() {
    _lastActivity = DateTime.now();
    _updateTrayTitle();
  }

  /// 프레임을 순환해 달리는 모션(≈8fps). 활동 없으면 쉬는 포즈(frame 0)로 고정.
  /// 채움은 매 틱 최신 사용량을 읽어 반영(유휴 중 %가 바뀌면 한 번만 다시 그림).
  void _startDogAnimation() {
    _dogTimer?.cancel();
    _dogTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final active = DateTime.now().difference(_lastActivity) < _idleAfter;
      _dogFrame = active ? (_dogFrame + 1) % _dogFrames : 0;
      _setDogIcon(); // 경로 동일하면 내부에서 무시(유휴 시 매 틱 no-op)
    });
  }

  /// 헤드라인(세션 %·리셋 카운트다운)을 트레이에 표시.
  /// macOS: NSStatusItem 아이콘 옆 텍스트 타이틀. Windows: 시스템 트레이는 텍스트
  /// 타이틀을 지원하지 않으므로(setTitle 미구현) 툴팁으로 라우팅.
  Future<void> _setHeadline(String text) async {
    if (Platform.isWindows) {
      await trayManager.setToolTip('Claudle · $text');
    } else {
      await trayManager.setTitle(text);
    }
  }

  Future<void> _initTray() async {
    try {
      // 아이콘이 있어야 NSStatusItem 이 표시됨. 러닝 푸들(컬러, 사용량 채움)이라
      // isTemplate=false — 회색 몸통이 라이트/다크 메뉴바 양쪽에서 보이게 그림.
      await _setDogIcon();
      await _setHeadline('…');
      await trayManager.setToolTip('Claudle — AI 사용량');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
                key: 'show_window',
                label: hudMode ? '패널 보이기' : '대시보드 열기'),
            MenuItem.separator(),
            MenuItem(key: 'exit_app', label: '종료'),
          ],
        ),
      );
    } catch (e, st) {
      debugPrint('[tray] ERROR: $e\n$st');
    }
  }

  /// 메뉴바 텍스트: 헤드라인=현재 세션 한도 "55% · 6m". 한도 미상 시 토큰으로 폴백.
  void _updateTrayTitle() {
    final lim = _controller.limits.value;
    if (lim != null) {
      final s = lim.session;
      final left = s.resetsAt == null
          ? ''
          : ' · ${compactDuration(s.resetsAt!.difference(DateTime.now()))}';
      _setHeadline('${s.usedPercent}%$left');
      return;
    }
    final t = _controller.totalsToday.value;
    _setHeadline((t == null || t.records == 0)
        ? '…'
        : '${compactTokens(t.totalTokens)} · ${money(t.costUsd)}');
  }

  /// 메뉴바 아이콘에 커서를 올리면 뜨는 툴팁.
  /// macOS: 세션 한도가 언제 초기화되는지 한국 시간(KST)으로. 한도 미상이면 상태로 폴백.
  /// Windows: 툴팁을 헤드라인 표시에 쓰므로(타이틀 미지원) 건드리지 않는다.
  void _updateTrayTooltip() {
    if (Platform.isWindows) return;
    final s = _controller.limits.value?.session;
    if (s?.resetsAt != null) {
      trayManager.setToolTip(
          'Claudle · 세션 초기화 예정 ${resetClockKst(s!.resetsAt!)} (KST)');
    } else {
      trayManager.setToolTip('Claudle — ${_controller.status.value}');
    }
  }

  @override
  void dispose() {
    _dogTimer?.cancel();
    _controller.limits.removeListener(_updateTrayTitle);
    _controller.limits.removeListener(_updateTrayTooltip);
    _controller.totalsToday.removeListener(_onTotals);
    _controller.phase.removeListener(_updateTrayTooltip);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    exit(0);
  }

  // ── Tray events ─────────────────────────────────────────────
  @override
  void onTrayIconMouseDown() {
    // 메뉴가 설정된 macOS에서는 좌클릭이 메뉴를 열지만, 일부 버전 대비 유지.
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        _showWindow();
        break;
      case 'exit_app':
        _quit();
        break;
    }
  }

  // ── Window events ───────────────────────────────────────────
  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Claudle',
      theme: tokenBarTheme(),
      home: hudMode
          ? WindowsHudScreen(controller: _controller)
          : DashboardScreen(controller: _controller),
    );
  }
}
