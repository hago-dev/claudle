import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../data/providers/claude_code/agent_run_reader.dart';
import '../domain/models/agent_run.dart';
import 'agent_history_view.dart';
import 'forest_scene_view.dart';

/// 아이솔레이트 진입점 — [AgentRunReader.readAll] 은 1400+ 파일을 동기로 읽어(실측 2.3초)
/// UI 스레드에서 부르면 그동안 프레임이 통째로 멈춘다. [AgentRun] 은 평범한 값 객체라
/// 아이솔레이트 경계를 복사로 넘어온다.
List<AgentRun> _readAllRuns() => AgentRunReader().readAll();

/// 라이브 폴링 진입점 — mtime 이 최근인 파일만 읽어(수십 ms) 매 초 돌려도 싸다.
List<AgentRun> _readLiveRuns() => AgentRunReader().readLive();

/// 그룹 제목 진입점 — 그룹 확정 뒤 대표 1건씩만 넘긴다(실측 134개). 세션 파일이 커서
/// 실측 ~0.95초 — UI 스레드에서 부르면 그동안 프레임이 통째로 멈춘다.
Map<String, String> _readTitles(List<AgentRun> representatives) =>
    AgentRunReader().readTitles(representatives);

/// 제목 읽기의 아이솔레이트 스폰 — **반드시 이 톱레벨의 깨끗한 스코프에서 클로저를 만든다.**
///
/// Dart 는 같은 스코프의 클로저들이 캡처 Context 를 공유한다 — `_load` 안에서
/// `Isolate.run(() => _readTitles(reps))` 를 만들면 이웃 setState 클로저가 캡처한
/// State(→ Element·Ticker, unsendable)까지 스폰 메시지에 통째로 끌려가
/// "object is unsendable - _AsyncCompleter" 로 터진다(실기기 크래시).
@visibleForTesting
Future<Map<String, String>> titlesInIsolate(List<AgentRun> representatives) =>
    Isolate.run(() => _readTitles(representatives));

/// 에이전트 시각화 화면 — 서브에이전트 1개 = 캐릭터 1마리.
///
/// [라이브] 지금 도는 에이전트 / [기록] 지난 실행을 세션·워크플로우 단위로 재생.
/// 과금 집계(대시보드)와 별개 축이라 DB 를 안 거치고 파일에서 바로 읽는다.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen>
    with WidgetsBindingObserver {
  /// 캐릭터를 여러 마리 늘어놓으려면 대시보드(460x620)·HUD(340x360)로는 좁다.
  static const _expandedSize = Size(900, 640);

  /// 라이브 폴링 주기. readLive 가 수십 ms 라 이 간격이면 코어를 갉지 않는다.
  static const _livePoll = Duration(seconds: 2);

  Size? _restoreSize;
  List<AgentRun>? _runs; // 기록(전체). null = 아직 안 읽음(기록 탭 첫 진입 때 읽는다)
  List<RunGroup> _groups = const [];
  String? _error;
  bool _live = true;

  List<AgentRun>? _liveRuns; // 라이브(가벼운 mtime 스캔). null = 첫 폴링 전
  Timer? _liveTimer;
  bool _pollBusy = false; // 앞 폴링이 아직 진행 중 → 겹치지 않게
  bool _appVisible = true; // 창이 보이는 동안만(숨기면 멈춤)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resize();
    _syncLivePolling(); // 라이브가 기본 탭 → 바로 폴링 시작(기록은 lazy)
  }

  /// 앱 창을 숨기거나 비활성이 되면 resumed 가 아니다 → 라이브 폴링을 멈춘다.
  /// 다시 보이면 재개. (라우트를 벗어나 닫는 경우는 [dispose] 가 멈춘다.)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible == _appVisible) return;
    _appVisible = visible;
    _syncLivePolling();
  }

  /// 라이브 탭이 열려 보이는 동안에만 주기 폴링. 그 외(기록 탭·창 숨김·화면 닫힘)엔
  /// 타이머를 없앤다 — 상시 스캔으로 코어를 갉지 않게(사용자 요청).
  void _syncLivePolling() {
    if (_live && _appVisible && mounted) {
      if (_liveTimer != null) return; // 이미 돎
      _pollLive(); // 기다리지 말고 즉시 한 번
      _liveTimer = Timer.periodic(_livePoll, (_) => _pollLive());
    } else {
      _liveTimer?.cancel();
      _liveTimer = null;
    }
  }

  /// 최근 수정된 파일만 읽어 라이브 목록 갱신. 겹침 방지 + 실패는 조용히(다음 틱 재시도).
  Future<void> _pollLive() async {
    if (_pollBusy) return;
    _pollBusy = true;
    try {
      final runs = await Isolate.run(_readLiveRuns);
      if (!mounted) return;
      setState(() => _liveRuns = runs);
    } catch (_) {
      if (mounted && _liveRuns == null) setState(() => _liveRuns = const []);
    } finally {
      _pollBusy = false;
    }
  }

  /// 들어올 때 창을 넓히고, 나갈 때 원래대로. 복원 크기는 상수로 박지 않고 **현재
  /// 값을 그대로 기억**한다 — 대시보드/HUD 어느 쪽에서 들어와도 맞고, main.dart 의
  /// 창 크기 상수와 이 파일이 따로 놀 일이 없다.
  Future<void> _resize() async {
    _restoreSize = await windowManager.getSize();
    await windowManager.setSize(_expandedSize);
  }

  @override
  void dispose() {
    _liveTimer?.cancel(); // 화면을 닫으면 폴링 멈춤
    WidgetsBinding.instance.removeObserver(this);
    final restore = _restoreSize;
    if (restore != null) windowManager.setSize(restore); // dispose 는 await 불가
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _runs = null;
      _error = null;
    });
    try {
      final runs = await Isolate.run(_readAllRuns);
      if (!mounted) return;
      final groups = groupRuns(runs);
      // 제목은 그룹을 확정한 **뒤에** — 제목 파일은 그룹마다 하나뿐이라 readAll 이 읽은
      // 1400 파일을 다시 읽을 일이 아니다. 스폰은 [titlesInIsolate] 에서 — 여기서
      // 클로저를 만들면 이웃 setState 클로저가 캡처한 State 가 끌려가 스폰이 터진다.
      final reps = [for (final g in groups) g.runs.first];
      final titles = await titlesInIsolate(reps);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _groups = [for (final g in groups) g.withName(titles[g.key])];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runs = const [];
        _error = '$e';
      });
    }
  }

  /// 라이브 ↔ 기록 전환. 기록 첫 진입에서만 전체를 읽고(그전엔 안 읽음), 폴링을 동기화한다.
  void _switchTab(bool live) {
    setState(() => _live = live);
    if (!live && _runs == null) _load();
    _syncLivePolling();
  }

  /// 현재 탭을 즉시 다시 읽기 — 라이브는 가벼운 폴링, 기록은 전체 재읽기.
  void _refresh() => _live ? _pollLive() : _load();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('에이전트'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '다시 읽기',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle:
                        WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: true,
                      label: Text('라이브'),
                      icon: Icon(Icons.circle, size: 9),
                    ),
                    ButtonSegment(value: false, label: Text('기록')),
                  ],
                  selected: {_live},
                  onSelectionChanged: (s) => _switchTab(s.first),
                ),
                const Spacer(),
                _headerCount(context),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 우측 카운트 — 탭마다 세는 대상이 다르다(라이브=도는 마리, 기록=그룹·전체).
  Widget _headerCount(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    if (_live) {
      if (_liveRuns == null) return const SizedBox.shrink();
      // 화면에 보이는 것과 숫자가 맞아야 한다 — 사람(세션)과 동물(서브)은 세는 단위가 다르다.
      // 세션은 **sessionId 집합**으로 센다: 씬의 열(=사람)은 메인이 돌 때뿐 아니라 그 세션의
      // 동물이 있을 때도 서기 때문에(메인이 서브를 기다리는 동안 메인 파일은 안 쓰인다),
      // '도는 메인' 만 세면 사람이 서 있는데 "세션 0개" 가 된다.
      final live = _liveRuns!.where((r) => r.isRunning);
      final sessions = live.map((r) => r.sessionId).toSet().length;
      final beasts = live.where((r) => r.agentType != mainAgentType).length;
      return Text(
        beasts == 0 ? '세션 $sessions개' : '세션 $sessions개 · 에이전트 $beasts마리',
        style: style,
      );
    }
    if (_runs == null) return const SizedBox.shrink();
    return Text('${_groups.length}개 실행 · 에이전트 ${_runs!.length}마리',
        style: style);
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Text('읽기 실패: $_error', style: const TextStyle(fontSize: 12)),
      );
    }
    if (_live) {
      if (_liveRuns == null) return _loading('실행 중인 에이전트 확인 중…');
      return _LiveView(
        runs: _liveRuns!.where((r) => r.isRunning).toList(),
        onShowHistory: () => _switchTab(false),
      );
    }
    if (_runs == null) return _loading('에이전트 기록 읽는 중…');
    return HistoryView(groups: _groups);
  }

  Widget _loading(String label) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 14),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}

// ── 라이브 ───────────────────────────────────────────────────

/// 지금 도는 에이전트만 — 세션(부모)=사람은 빈터 위에 서 있고, 그 세션이 띄운 서브(동물)들이
/// 앞마당에서 논다([ForestSceneView]). 상위(_AgentsScreenState)가 이 탭이 열려 보이는
/// 동안에만 가벼운 mtime 스캔(readLive)으로 주기 갱신하고, 탭을 벗어나거나 창을 닫으면 멈춘다.
///
/// [runs] 엔 메인 세션(사람)도 섞여 온다 → 서브가 0마리여도(= 프롬프트만 도는 중) 씬이
/// 뜬다. 빈 화면은 이제 **메인도 서브도 없을 때**뿐이다.
class _LiveView extends StatelessWidget {
  final List<AgentRun> runs;
  final VoidCallback onShowHistory;
  const _LiveView({required this.runs, required this.onShowHistory});

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) return _empty(context);
    // key 금지 — 붙이면 2초 폴링마다 숲이 통째로 리셋된다.
    return ForestSceneView(runs: runs);
  }

  Widget _empty(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: 0.45, // 쉬는 마스코트 — 흐리게
              child: Image.asset(
                'assets/agents/animal-dog.png',
                width: 72,
                height: 72,
                filterQuality: FilterQuality.none,
              ),
            ),
            const SizedBox(height: 16),
            Text('실행 중인 에이전트 없음',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              '지금 도는 서브에이전트가 없습니다. 지난 실행은 기록 탭에서 재생할 수 있어요.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: onShowHistory,
              child: const Text('기록 보기'),
            ),
          ],
        ),
      );
}

