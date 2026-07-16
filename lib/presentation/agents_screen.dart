import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart'; // material.dart 는 Ticker 를 export 하지 않는다
import 'package:intl/intl.dart';
import 'package:window_manager/window_manager.dart';

import '../core/util/format.dart';
import '../data/providers/claude_code/agent_run_reader.dart';
import '../domain/models/agent_run.dart';
import 'forest_scene.dart';

/// 아이솔레이트 진입점 — [AgentRunReader.readAll] 은 1400+ 파일을 동기로 읽어(실측 2.3초)
/// UI 스레드에서 부르면 그동안 프레임이 통째로 멈춘다. [AgentRun] 은 평범한 값 객체라
/// 아이솔레이트 경계를 복사로 넘어온다.
List<AgentRun> _readAllRuns() => AgentRunReader().readAll();

/// 라이브 폴링 진입점 — mtime 이 최근인 파일만 읽어(수십 ms) 매 초 돌려도 싸다.
List<AgentRun> _readLiveRuns() => AgentRunReader().readLive();

/// 상세 로그는 클릭한 1마리 것만 그때 읽는다 — 파일 하나라 [_readAllRuns] 보다 훨씬 싸다.
List<AgentStep> _readSteps(String filePath) =>
    AgentRunReader().readSteps(filePath);

/// 메인 세션(사람) 클릭 상세 — 서브와 달리 지시=최신 last-prompt, 활동=최근순([readMainSteps]).
List<AgentStep> _readMainSteps(String filePath) =>
    AgentRunReader().readMainSteps(filePath);

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
  List<_RunGroup> _groups = const [];
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
      final groups = _groupRuns(runs);
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
    return _HistoryView(groups: _groups);
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
/// 앞마당에서 논다([_ForestSceneView]). 상위(_AgentsScreenState)가 이 탭이 열려 보이는
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
    return _ForestSceneView(runs: runs);
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

// ── 기록 ────────────────────────────────────────────────────

/// 좌: 실행 목록(최근 것부터, 가상화) / 우: 선택한 실행의 재생.
class _HistoryView extends StatefulWidget {
  final List<_RunGroup> groups;
  const _HistoryView({required this.groups});

  @override
  State<_HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<_HistoryView> {
  _RunGroup? _selected;

  @override
  Widget build(BuildContext context) {
    if (widget.groups.isEmpty) {
      return const Center(
        child: Text('에이전트 실행 기록이 없습니다.', style: TextStyle(fontSize: 12)),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 292,
          // 1421마리 → 그룹 수백 개. 보이는 것만 만든다.
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: widget.groups.length,
            itemBuilder: (context, i) {
              final g = widget.groups[i];
              return _GroupTile(
                group: g,
                selected: identical(g, _selected),
                onTap: () => setState(() => _selected = g),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _selected == null
              ? const Center(
                  child: Text('왼쪽에서 실행을 고르면 재생합니다.',
                      style: TextStyle(fontSize: 12)),
                )
              : _PlaybackView(
                  key: ValueKey(_selected!.key), // 선택 바뀌면 재생 상태 리셋
                  group: _selected!,
                ),
        ),
      ],
    );
  }
}

class _GroupTile extends StatelessWidget {
  final _RunGroup group;
  final bool selected;
  final VoidCallback onTap;
  const _GroupTile({
    required this.group,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? scheme.primary.withValues(alpha: 0.16) : null,
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 이 서브들을 스폰한 메인(부모) = 사람. 세션/워크플로우 구분은 title 텍스트에 있다.
                _Critter(
                  sprite: personSprite(group.runs.first.sessionId),
                  phase: 0,
                  running: false,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    group.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  DateFormat('M/d HH:mm').format(group.startedAt.toLocal()),
                  style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurface.withValues(alpha: 0.45)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_projectLabel(group.runs.first.project)} · '
              '${group.runs.length}마리 · ${_elapsed(group.span)} · '
              '${compactTokens(group.tokens)}',
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 5),
            // 구성 타입 미리보기 — 색점만 보고도 어떤 조합인지 감이 오게.
            Row(
              children: [
                for (final r in group.runs.take(18))
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: agentColor(r.agentType),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 선택한 실행 재생 — 타임라인 스크럽 + ▶/⏸.
///
/// 실제 소요시간(수 초~수십 분)을 [_playbackSpan] 으로 압축해 돌린다. 재생 위치 t 에서
/// 각 마리의 상태(대기/작업중/완료)를 시작·종료 시각으로 판정 → 작업 중이면 달린다.
class _PlaybackView extends StatefulWidget {
  final _RunGroup group;
  const _PlaybackView({super.key, required this.group});

  @override
  State<_PlaybackView> createState() => _PlaybackViewState();
}

class _PlaybackViewState extends State<_PlaybackView>
    with TickerProviderStateMixin {
  static const _playbackSpan = Duration(seconds: 8);

  late final AnimationController _legs = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat();

  /// 0..1 = 그룹 시작~끝.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: _playbackSpan,
  )..forward();

  @override
  void dispose() {
    _legs.dispose();
    _clock.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_clock.isAnimating) {
      _clock.stop();
    } else {
      _clock.forward(from: _clock.value >= 1 ? 0 : _clock.value);
    }
    setState(() {}); // ▶/⏸ 아이콘 갱신
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 이 서브들을 스폰한 메인(부모) = 사람.
              _Critter(
                sprite: personSprite(g.runs.first.sessionId),
                phase: 0,
                running: false,
                size: 40,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.title,
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(
                      '${_projectLabel(g.runs.first.project)} · 에이전트 ${g.runs.length}마리 · '
                      '${_elapsed(g.span)} · ${compactTokens(g.tokens)} tokens',
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: 0.55)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: Listenable.merge([_clock, _legs]),
            builder: (context, _) {
              final t = g.startedAt.add(g.span * _clock.value);
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                itemCount: g.runs.length,
                itemBuilder: (context, i) {
                  final r = g.runs[i];
                  final (state, progress) = _stateAt(r, t);
                  return _AgentCard(
                    run: r,
                    phase: _legs.value,
                    state: state,
                    toolsDone: (r.toolCalls.length * progress).floor(),
                  );
                },
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 16, 6),
          child: AnimatedBuilder(
            animation: _clock,
            builder: (context, _) => Row(
              children: [
                IconButton(
                  icon: Icon(
                    _clock.isAnimating ? Icons.pause : Icons.play_arrow,
                    size: 20,
                  ),
                  tooltip: _clock.isAnimating ? '일시정지' : '재생',
                  onPressed: _toggle,
                ),
                Expanded(
                  child: Slider(
                    value: _clock.value,
                    onChanged: (v) {
                      _clock.stop();
                      _clock.value = v;
                      setState(() {}); // 스크럽 중엔 ▶ 로
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_elapsed(g.span * _clock.value)} / ${_elapsed(g.span)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 재생 위치 [t] 에서 이 마리의 상태 + 진행률(0..1).
(_RunState, double) _stateAt(AgentRun r, DateTime t) {
  if (t.isBefore(r.startedAt)) return (_RunState.waiting, 0);
  if (!t.isBefore(r.endedAt)) return (_RunState.done, 1);
  final total = r.endedAt.difference(r.startedAt).inMilliseconds;
  if (total <= 0) return (_RunState.done, 1); // 순간 실행(시작=끝)
  return (
    _RunState.running,
    (t.difference(r.startedAt).inMilliseconds / total).clamp(0.0, 1.0),
  );
}

enum _RunState { waiting, running, done }

// ── 캐릭터 한 마리 ────────────────────────────────────────────

/// 캐릭터 + 라벨(타입·지시·토큰·소요) + 지금 만지는 것 + 도구 시퀀스.
/// 누르면 이 마리의 전체 작업 로그([_AgentLogSheet]).
class _AgentCard extends StatelessWidget {
  final AgentRun run;
  final double phase;
  final _RunState state;
  final int toolsDone;

  const _AgentCard({
    required this.run,
    required this.phase,
    required this.state,
    required this.toolsDone,
  });

  /// 재생 위치에서 만지고 있는 도구 — 끝난 마리는 마지막으로 만진 것. 대기 중이면 없음.
  ToolCall? get _current {
    if (state == _RunState.waiting || run.toolCalls.isEmpty) return null;
    return run.toolCalls[toolsDone.clamp(0, run.toolCalls.length - 1)];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = agentColor(run.agentType);
    final waiting = state == _RunState.waiting;
    return Opacity(
      opacity: waiting ? 0.28 : 1, // 아직 안 뜬 마리는 흐리게
      child: InkWell(
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true, // 기본 높이(화면 절반)로는 로그가 몇 줄 안 보인다
          builder: (_) => _AgentLogSheet(run: run),
        ),
        child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 72,
              height: 60,
              child: Align(
                alignment: Alignment.bottomCenter, // 바닥에서 콩콩 뛰게
                child: _Critter(
                  sprite: agentSprite(run),
                  phase: phase,
                  running: state == _RunState.running,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _TypeBadge(agentType: run.agentType),
                      const SizedBox(width: 8),
                      Text(
                        '${_elapsed(run.endedAt.difference(run.startedAt))} · '
                        '${compactTokens(run.inputTokens + run.outputTokens)} tokens',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                      if (state == _RunState.running) ...[
                        const SizedBox(width: 8),
                        Text('작업 중',
                            style: TextStyle(fontSize: 10, color: color)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    run.description.isEmpty ? '(지시 없음)' : run.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: scheme.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 재생 위치에 따라 바뀐다 — 높이는 고정(내용이 없다고 카드가 들썩이지 않게).
                  SizedBox(
                    height: 16,
                    child: _current == null
                        ? null
                        : _ToolLine(tool: _current!, color: color),
                  ),
                  const SizedBox(height: 5),
                  _ToolStrip(tools: run.toolCalls, done: toolsDone, color: color),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 타입 이름표 — 카드와 상세 로그 머리말이 같이 쓴다.
class _TypeBadge extends StatelessWidget {
  final String agentType;

  /// 배지 색 강제 — 라이브 시트가 클릭한 마리의 랜덤 색을 시트 전체와 맞출 때.
  /// null = 타입색([agentColor], 기록 쪽 기본).
  final Color? color;
  const _TypeBadge({required this.agentType, this.color});

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? agentColor(agentType);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        // 메인은 카테고리가 아니라 '그 세션(사람)' 이다 — 'main' 원문 대신 사람 말로.
        agentType == mainAgentType ? '세션' : agentType,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 도구 한 줄 — 아이콘 + 이름 + 무엇을 만졌는지. 카드의 "지금 하는 일" 과 상세 로그가 같이 쓴다.
class _ToolLine extends StatelessWidget {
  final ToolCall tool;
  final Color color;

  const _ToolLine({required this.tool, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(_toolIcon(tool.name), size: 12, color: color),
        const SizedBox(width: 5),
        Text(
          tool.name,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color),
        ),
        if (tool.detail.isNotEmpty) ...[
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              tool.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis, // 긴 인자(명령줄 등)는 말줄임
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 도구 호출 순서 — 진행된 만큼 진하게. 개별 시각은 기록에 없어 재생 진행률로 근사한다.
class _ToolStrip extends StatelessWidget {
  final List<ToolCall> tools;
  final int done;
  final Color color;
  static const _max = 16;

  const _ToolStrip({required this.tools, required this.done, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (tools.isEmpty) {
      return Text('도구 호출 없음',
          style: TextStyle(
              fontSize: 10, color: scheme.onSurface.withValues(alpha: 0.3)));
    }
    final shown = tools.take(_max).toList();
    return Row(
      children: [
        for (int i = 0; i < shown.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Tooltip(
              message: shown[i].detail.isEmpty
                  ? shown[i].name
                  : '${shown[i].name}  ${shown[i].detail}',
              child: Icon(
                _toolIcon(shown[i].name),
                size: 13,
                color: color.withValues(alpha: i < done ? 1 : 0.22),
              ),
            ),
          ),
        if (tools.length > _max)
          Text('+${tools.length - _max}',
              style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurface.withValues(alpha: 0.45))),
      ],
    );
  }
}

/// 도구 → 아이콘. 실측 분포(Bash·Read·StructuredOutput·Edit·Write·Grep…) 기준.
IconData _toolIcon(String tool) {
  if (tool.startsWith('mcp__')) return Icons.extension;
  switch (tool) {
    case 'Bash':
    case 'bash':
    case 'BashOutput':
      return Icons.terminal;
    case 'Read':
      return Icons.description_outlined;
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
      return Icons.edit_outlined;
    case 'Grep':
    case 'Glob':
    case 'ToolSearch':
      return Icons.search;
    case 'Task':
      return Icons.hub_outlined;
    case 'WebFetch':
    case 'WebSearch':
      return Icons.language;
    case 'TodoWrite':
      return Icons.checklist;
    case 'StructuredOutput':
      return Icons.data_object;
    default:
      return Icons.circle;
  }
}

// ── 상세 로그 ───────────────────────────────────────────────

/// 이 마리가 실제로 한 일 전부 — 도구 호출(무엇을 만졌는지)과 쓴 글을 순서대로.
/// 카드의 아이콘 줄로는 "Read 를 12번 했다" 까지고, **뭘** 읽었는지는 여기서 본다.
class _AgentLogSheet extends StatefulWidget {
  final AgentRun run;

  /// 메인 세션(사람)인가 — 서브(동물)면 false. 상세를 [_readMainSteps](지시=최신
  /// last-prompt·활동 최근순)로 읽고 머리말을 동물이 아니라 사람 스프라이트로 그린다.
  final bool live;

  /// 씬에서 클릭한 그 마리의 스프라이트 — 라이브 종은 등장마다 섞여서 run 만으론 복원이
  /// 안 된다(안 넘기면 클릭한 펭귄의 시트에 다른 동물이 뜬다). null = 기록에서 열림 →
  /// [agentSprite] 폴백(재생 카드와 같은 결정론 배정이라 어긋날 일이 없다).
  final String? sprite;

  /// 씬에서 클릭한 그 마리의 색 — [sprite] 와 같은 이유(라이브 색도 등장마다 섞인다).
  /// null = 기록에서 열림 → [agentColor] 폴백.
  final Color? color;
  const _AgentLogSheet({
    required this.run,
    this.live = false,
    this.sprite,
    this.color,
  });

  @override
  State<_AgentLogSheet> createState() => _AgentLogSheetState();
}

class _AgentLogSheetState extends State<_AgentLogSheet> {
  late final Future<List<AgentStep>> _steps;

  @override
  void initState() {
    super.initState();
    // 경로만 아이솔레이트로 넘긴다 — 클로저가 State 를 잡으면 넘어가지 못한다.
    final path = widget.run.filePath;
    final live = widget.live;
    _steps = Isolate.run(() => live ? _readMainSteps(path) : _readSteps(path));
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final color = widget.color ?? agentColor(run.agentType);
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: _Critter(
                    // 사람(메인)은 사람 스프라이트, 동물(서브)은 종. 씬의 배정과 같게.
                    sprite: widget.live
                        ? personSprite(run.sessionId)
                        : widget.sprite ?? agentSprite(run),
                    phase: 0,
                    running: false, // 머리말은 정지
                    size: 44,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 시트 악센트(도구줄·지시판)와 배지가 한 색이어야 읽힌다.
                          _TypeBadge(agentType: run.agentType, color: color),
                          const SizedBox(width: 8),
                          Text(
                            '${_projectLabel(run.project)} · '
                            '${_elapsed(run.endedAt.difference(run.startedAt))} · '
                            '${compactTokens(run.inputTokens + run.outputTokens)} tokens · '
                            '도구 ${run.toolCalls.length}회',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        run.description.isEmpty ? '(지시 없음)' : run.description,
                        style: const TextStyle(fontSize: 11, height: 1.3),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '닫기',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<AgentStep>>(
              future: _steps,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Text('로그 읽기 실패: ${snap.error}',
                        style: const TextStyle(fontSize: 12)),
                  );
                }
                final steps = snap.data;
                if (steps == null) {
                  return const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (steps.isEmpty) {
                  return const Center(
                    child: Text('남긴 기록이 없습니다.', style: TextStyle(fontSize: 12)),
                  );
                }
                // 한 마리가 수백 줄까지 간다 → 보이는 것만 만든다.
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: steps.length,
                  itemBuilder: (context, i) =>
                      _StepRow(step: steps[i], color: color),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 로그 한 줄 — 받은 지시([AgentStep.isPrompt])거나, 도구 호출이거나, 에이전트가 쓴 글이거나.
class _StepRow extends StatelessWidget {
  final AgentStep step;
  final Color color;
  const _StepRow({required this.step, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (step.isPrompt) return _prompt(scheme);
    final tool = step.tool;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: tool != null
          ? _ToolLine(tool: tool, color: color)
          : Text(
              step.text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
    );
  }

  /// 받은 지시 전문 — 로그 맨 앞. "Write path" 한 줄이 아니라 뭘 하라고 시켰는지 통째로.
  /// 타입색 왼쪽 띠 + 옅은 판으로 도구/글 줄과 구분한다. 길면(워크플로우 공유 프롬프트는
  /// 수천 자) 시트 안에서 접었다 펼 수 있게 [_ExpandableText] 로 감싼다.
  Widget _prompt(ColorScheme scheme) => Container(
        margin: const EdgeInsets.only(top: 2, bottom: 10),
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('받은 지시',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: color)),
            const SizedBox(height: 5),
            _ExpandableText(
              text: step.text,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: scheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      );
}

/// 긴 지시 프롬프트 — 처음엔 8줄까지, 넘치면 "더 보기" 로 전문을 편다.
/// 워크플로우 팬아웃 프롬프트는 공유 접두사가 수천 자라 처음부터 다 펴면 로그가 안 보인다.
class _ExpandableText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _ExpandableText({required this.text, required this.style});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const _collapsedLines = 8;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // 접힘 상태에서 실제로 잘리는지 본 뒤에만 "더 보기" 를 단다 — 짧은 지시엔 버튼이 없다.
    return LayoutBuilder(
      builder: (context, box) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: _collapsedLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: box.maxWidth);
        final overflows = tp.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              maxLines: _expanded ? null : _collapsedLines,
              overflow:
                  _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
              style: widget.style,
            ),
            if (overflows)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? '접기' : '더 보기',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ── 그룹 ────────────────────────────────────────────────────

/// 재생 단위 — 같은 워크플로우(있으면), 없으면 같은 세션에서 뜬 에이전트 묶음.
class _RunGroup {
  final String key;
  final bool isWorkflow;
  final List<AgentRun> runs; // 시작 시각 오름차순
  final DateTime startedAt;
  final DateTime endedAt;

  /// 사람이 읽는 제목 — 워크플로우 `workflowName` / 세션 최신 `ai-title`.
  /// null = 못 찾음 → [title] 이 예전처럼 ID 로 폴백한다.
  final String? name;

  _RunGroup(this.key, this.isWorkflow, this.runs, {this.name})
      : startedAt = runs.first.startedAt,
        endedAt = runs
            .map((r) => r.endedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);

  /// 제목만 채운 사본 — 제목은 그룹이 정해진 뒤에야 그 파일을 읽을 수 있어서([_load])
  /// [AgentRun.withDescription] 과 같은 순서 문제를 같은 방식으로 푼다.
  _RunGroup withName(String? name) => _RunGroup(key, isWorkflow, runs, name: name);

  Duration get span => endedAt.difference(startedAt);
  int get tokens =>
      runs.fold(0, (s, r) => s + r.inputTokens + r.outputTokens);
  String get title =>
      name ??
      (isWorkflow
          ? '워크플로우 $key'
          : '세션 ${key.length > 8 ? key.substring(0, 8) : key}');
}

/// workflowId(있으면) / sessionId 로 묶고 최근 끝난 것부터.
List<_RunGroup> _groupRuns(List<AgentRun> runs) {
  final byKey = <String, List<AgentRun>>{};
  for (final r in runs) {
    byKey.putIfAbsent(r.workflowId ?? r.sessionId, () => <AgentRun>[]).add(r);
  }
  final groups = <_RunGroup>[];
  for (final e in byKey.entries) {
    final rs = e.value..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    groups.add(_RunGroup(e.key, rs.first.workflowId != null, rs));
  }
  groups.sort((a, b) => b.endedAt.compareTo(a.endedAt));
  return groups;
}

/// 씬 발밑 이름표 — 이 마리가 받은 지시를 짧게. 없으면(워크플로우 라이브는 description 이
/// 프롬프트 꼬리라 대개 있다) 타입으로 폴백. 셀이 104px 라 [labelMaxChars] 자에서 자른다.
String _actionLabel(AgentRun run) {
  final desc = run.description.trim();
  final base = desc.isEmpty ? run.agentType : desc;
  return base.characters.length > labelMaxChars
      ? '${base.characters.take(labelMaxChars)}…'
      : base;
}

/// 에이전트 소요시간은 대부분 분 미만이라 [compactDuration] 은 죄다 '0m' 이 된다 → 초까지.
String _elapsed(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return compactDuration(d);
}

/// `-Users-me-Desktop-project-tokenbar` → `tokenbar`.
/// 단순화: 인코딩 경로의 마지막 세그먼트만 — 이름에 '-' 가 든 프로젝트는 잘려 보인다.
/// 필요 시 대시보드의 별칭(usage DB `setAlias`)과 연결.
String _projectLabel(String encoded) {
  final parts = encoded.split('-').where((s) => s.isNotEmpty);
  return parts.isEmpty ? encoded : parts.last;
}

// ── 캐릭터(큐브펫) ────────────────────────────────────────────
// 종·색 배정 규약(agentSprite/personSprite/randomAnimalSprite/randomAgentColor)은
// forest_scene.dart 로 — 씬 모델(sync)이 쓰는 쪽에 산다.

/// 스프라이트 한 마리 — 정지 PNG(64x64)를 [phase] 로 통통 튀게. 걷기 프레임이 없으니
/// 작업 중([running])일 때만 바닥에서 콩콩 뛰고(Y −4~0px), 살짝 기운다. 끝나면 정지.
/// 저폴리라 [FilterQuality.none](nearest) 이 확대해도 뭉개지지 않고 각지게 유지된다.
/// [sprite] 는 `assets/agents/<sprite>.png` 의 basename — 동물(`animal-fox`)이든
/// 사람(`character-male-a`)이든 같은 위젯이 그린다. 사람(부모)은 호출부에서 `running:false` 로 정지.
class _Critter extends StatelessWidget {
  final String sprite;
  final double phase; // 0..1 — 애니메이션 위상
  final bool running;
  final double size;

  const _Critter({
    required this.sprite,
    required this.phase,
    required this.running,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    final t = phase * 2 * math.pi;
    // -abs(sin) → 위로만 튄다(바닥이 0). 한 바퀴에 콩콩 두 번.
    final bob = running ? -hopWave(phase) * 4 : 0.0;
    final tilt = running ? math.sin(t) * 0.05 : 0.0; // 뛸 때 좌우로 살짝
    return Transform.translate(
      offset: Offset(0, bob),
      child: Transform.rotate(
        angle: tilt,
        // fit 필수 — 기본값 BoxFit.scaleDown 은 확대를 안 해서 64px 원본이 그보다 큰
        // 박스에서 64px 로 박힌다. 지금은 48~64px 라 티가 안 나지만, 크기를 키우는 순간
        // 조용히 상한에 걸린다(소품에서 실제로 터졌던 버그).
        child: Image.asset(
          'assets/agents/$sprite.png',
          width: size,
          height: size,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.none,
        ),
      ),
    );
  }
}

// ── 숲 씬(라이브) 뷰 ──────────────────────────────────────────
//
// 모델(ForestScene·Beast·Clearing·SceneProp)과 셀 기하·배정 규약은 forest_scene.dart 에.
// 여기는 그리기(위젯)만 — 팔레트는 뷰 관심사라 잔류한다.

// 팔레트 — 앱은 dark 단일(main.dart). 숲은 초록이라 시드(바이올렛)를 안 따른다(의도).
const _skyTop = Color(0xFF16281C), _skyBottom = Color(0xFF2A4A31);
// 밤 하늘 — 낮보다 파랗고 어둡게. 새벽 팬아웃이 낮과 같은 하늘이면 시간 감각이 없다.
const _skyTopNight = Color(0xFF0A1020), _skyBottomNight = Color(0xFF152A2E);
const _plateBg = Color(0xB3101A14);

/// 숲 씬 — [Ticker] 1개로 모델을 굴리고 위젯 트리로 그린다.
///
/// [AnimationController] 를 안 쓰는 이유: dt 를 안 준다(value 는 위상일 뿐이라 프레임이
/// 밀리면 계산이 틀린다). 콩콩이 개체별 누적 위상이 된 순간 전역 위상 자체가 불필요해졌다.
/// 가시성 배선도 없다 — 엔진이 hidden·paused·detached 에서 프레임을 끊으므로 그게 곧 정지다.
class _ForestSceneView extends StatefulWidget {
  final List<AgentRun> runs;
  const _ForestSceneView({required this.runs});

  @override
  State<_ForestSceneView> createState() => _ForestSceneState();
}

class _ForestSceneState extends State<_ForestSceneView>
    with SingleTickerProviderStateMixin {
  final ForestScene _scene = ForestScene();
  late final Ticker _ticker = createTicker(_scene.tick);

  @override
  void initState() {
    super.initState();
    _scene.sync(widget.runs);
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 소품만 미리 디코딩 — 배경은 첫 프레임에 통째로 깔려 팝인이 눈에 띈다. 동물은 2초 폴링
    // 경계에 하나씩 등장해 1프레임 팝인이 안 보인다.
    for (final sprite in propSize.keys) {
      precacheImage(AssetImage('assets/agents/$sprite.png'), context);
    }
  }

  @override
  void didUpdateWidget(covariant _ForestSceneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scene.sync(widget.runs);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        // 이보다 작으면 play 가 뒤집혀 NaN 이 된다.
        if (size.width < 260 || size.height < 220) return const SizedBox.shrink();
        _scene.resize(size);
        final scene = SizedBox(
          width: _scene.sceneW,
          height: size.height,
          // RepaintBoundary 2개 — 배경은 리사이즈 때만 다시 그리고, 60fps 더티가 AppBar·탭 행까지 안 번지게.
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: _Backdrop(
                  floor: _scene.floor,
                  back: _scene.back,
                  colW: _scene.colW,
                  cols: _scene.clearings.length,
                  // bool 하나만 — clock 같은 프레임 단위 입력을 넘기면 배경이 60fps 로
                  // 리페인트돼 RepaintBoundary 로 격리한 의미가 사라진다.
                  night: isNightAt(DateTime.now()),
                ),
              ),
              RepaintBoundary(
                // Positioned 는 Stack 직계여야 해서 마리별 AnimatedBuilder 가 불가능 →
                // 캐릭터 층 전체를 하나로 묶는다.
                child: AnimatedBuilder(
                  animation: _scene,
                  builder: (context, _) => _characters(),
                ),
              ),
            ],
          ),
        );
        return _scene.sceneW > size.width
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: scene)
            : scene;
      },
    );
  }

  /// 캐릭터 층 — 사람(y 가 늘 최소라 맨 뒤) 다음 동물을 pos.dy 오름차순으로.
  Widget _characters() {
    // 빈터 없는 마리(= 포커스로 가려진 열)는 여기서 걸러야 [labelMax] 판정이 정직해진다 —
    // 안 그리는 마리까지 세면 세 마리만 보이는 포커스 뷰에서 이름표가 꺼진다.
    final ws = _scene.beasts
        .where((b) => b.fade > 0 && _scene.clearingOf(b.sessionId) != null)
        .toList()
      ..sort((a, b) {
        final c = a.pos.dy.compareTo(b.pos.dy);
        return c != 0 ? c : a.agentId.compareTo(b.agentId); // List.sort 는 불안정 — 동률 깜빡임 방지
      });
    final label = ws.length <= labelMax; // 넘으면 글자 수프 — 칩·호버·탭은 그대로 남는다
    return Stack(
      children: [
        for (int i = 0; i < _scene.clearings.length; i++)
          _PersonStand(
            c: _scene.clearings[i],
            clock: _scene.clock,
            index: i,
            main: _scene.mainOf(_scene.clearings[i].sessionId),
            mainRun: _scene.mainRunOf(_scene.clearings[i].sessionId),
            title: _scene.titleOf(_scene.clearings[i].sessionId),
            // 이름표 클릭 = 이 세션만 크게. 사람 클릭은 이미 상세 로그라 슬롯이 갈린다.
            // 열이 하나뿐이면 누를 이유가 없다(포커스 중엔 나가는 길이라 늘 살아 있다).
            onFocus: _scene.canFocus || _scene.focus != null
                ? () => _scene.setFocus(_scene.focus == null
                    ? _scene.clearings[i].sessionId
                    : null)
                : null,
            focused: _scene.focus != null,
          ),
        for (final b in ws) _cell(b, label),
        if (_scene.hidden > 0)
          Positioned(
            top: 8,
            right: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _plateBg,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text('+${_scene.hidden}마리',
                    style: const TextStyle(fontSize: 11)),
              ),
            ),
          ),
        // 나가는 길 — 포커스 중엔 다른 열이 아예 없어서 이름표 말고 여기로도 돌아온다.
        if (_scene.focus != null)
          Positioned(
            top: 8,
            left: 8,
            child: _PlateButton(
              label: '← 전체 보기',
              onTap: () => _scene.setFocus(null),
            ),
          ),
      ],
    );
  }

  /// 마리 1개 = Stack 직계 [Positioned]. **key 필수** — 없으면 정렬이 바뀔 때 Stack 이
  /// 인덱스로 매칭해 다른 마리의 Element(호버·툴팁 상태)를 물려받는다.
  Widget _cell(Beast b, bool label) {
    final c = _scene.clearingOf(b.sessionId);
    if (c == null) return const SizedBox.shrink(); // sync 가 마리마다 빈터를 보장한다
    final t = ((b.pos.dy - c.play.top) / c.play.height).clamp(0.0, 1.0);
    // 48..59(원근) × 성장(1.0~growthCap) — 많이 뱉은 마리가 눈에 띄게 크다.
    // 포커스 중엔 한 열이 화면을 다 쓰니 마리도 그만큼 키운다(그게 "키워 보기" 의 본체).
    final base = _scene.focus == null ? animalSize : animalSize * 1.3;
    final size =
        base * (depthMin + depthSpan * t) * growthScale(b.run.outputTokens);
    return Positioned(
      key: ValueKey(b.agentId),
      left: b.pos.dx - cellW / 2,
      top: b.pos.dy - groundY,
      width: cellW,
      height: cellH,
      child: _SceneCritter(
        b: b,
        clock: _scene.clock,
        thinking: _scene.thinking(b),
        crowned: _scene.crownId == b.agentId,
        size: size,
        label: label,
        onHover: (v) => b.hovered = v, // 다음 tick 이 읽는다 — setState 불필요
      ),
    );
  }
}

/// 정적 배경 — 땅 + 열 명암 + 바닥 얼룩 + 뒷숲/캠프. 세로 소품은 전부 놀이터 밖이라
/// 동물과 y-sort 할 일이 없다 → 리사이즈 때만 다시 그린다.
class _Backdrop extends StatelessWidget {
  final List<SceneProp> floor, back;
  final double colW;
  final int cols;

  /// 밤이면 하늘이 어두워지고 별이 뜬다. **bool 하나뿐인 게 중요하다** — 프레임 단위 값을
  /// 받는 순간 이 정적 레이어가 60fps 로 리페인트된다.
  final bool night;

  const _Backdrop({
    required this.floor,
    required this.back,
    required this.colW,
    required this.cols,
    required this.night,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: night
              ? const [_skyTopNight, _skyBottomNight]
              : const [_skyTop, _skyBottom],
        ),
      ),
      child: Stack(
        children: [
          if (night) const Positioned.fill(child: CustomPaint(painter: _Stars())),
          // 열 구분선 대신 명암만 — 소속의 본체는 공간 격리 + 열 머리의 캠프다.
          for (int i = 1; i < cols; i += 2)
            Positioned(
              left: colW * i,
              top: 0,
              bottom: 0,
              width: colW,
              child: const ColoredBox(color: Color(0x0DFFFFFF)),
            ),
          for (final p in floor) _prop(p),
          for (final p in back) _prop(p),
        ],
      ),
    );
  }

  Widget _prop(SceneProp p) => Positioned(
        left: p.at.dx - p.size / 2,
        top: p.flat
            ? p.at.dy - p.size / 2
            : p.at.dy - footInset(p.sprite) * p.size,
        width: p.size,
        height: p.size,
        // fit 필수 — Image 기본값은 BoxFit.scaleDown(축소만, 확대 안 함)이라 64px 원본이
        // 132px 박스 안에서 64px 로 박힌다(= 나무가 여우보다 작아진다). 원본·박스 둘 다
        // 정사각이라 fill 이어도 왜곡은 없다.
        child: Image.asset(
          'assets/agents/${p.sprite}.png',
          width: p.size,
          height: p.size,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.none,
        ),
      );
}

/// 밤하늘 별 — 위젯 수십 개가 아니라 [CustomPaint] 하나. 좌표는 고정 시드라 리사이즈해도
/// 별자리가 그대로다(리페인트마다 새로 뿌리면 별이 반짝이는 게 아니라 춤춘다).
class _Stars extends CustomPainter {
  const _Stars();

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7); // 고정 시드 = 늘 같은 밤하늘
    final n = (size.width / 14).round().clamp(30, 120); // 넓은 씬(여러 세션)일수록 많이
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height * 0.45; // 하늘 = 위쪽만(땅에 별이 박히지 않게)
      paint.color =
          Colors.white.withValues(alpha: 0.25 + rnd.nextDouble() * 0.5);
      canvas.drawCircle(Offset(x, y), 0.6 + rnd.nextDouble() * 0.9, paint);
    }
  }

  @override
  bool shouldRepaint(_Stars oldDelegate) => false; // 입력이 없다 = 다시 그릴 이유가 없다
}

/// 사람 1명 — 제 빈터 **위**에 고정. 동물은 빈터 안에서만 노니까 사람도 이름표도 안 가린다.
///
/// [main] 이 있으면 = 메인 세션이 지금 일하는 중 → 이름표 옆에 지금 만지는 도구 칩을 단다
/// (동물 머리 위 칩과 같은 기호). 동물이 0마리여도 이 사람은 선다.
class _PersonStand extends StatelessWidget {
  final Clearing c;
  final double clock;
  final int index;

  /// 지금 도는 메인(60초 이내 갱신). null = 조용함 → 머리 위 도구 칩을 안 단다.
  final AgentRun? main;

  /// 클릭 시 상세를 읽을 메인 실행 — [main] 이 조용해도 마지막 본 것을 붙잡고 있어([_mainRunOf])
  /// 여기로 온다. null 이면 이 열이 사는 동안 메인을 한 번도 못 봐서 열 자체가 안 눌린다.
  final AgentRun? mainRun;
  final String? title;

  /// 이름표를 누르면 이 세션만 크게 본다(포커스 중이면 전체로 복귀). null = 열이 하나뿐이라
  /// 누를 이유가 없다.
  final VoidCallback? onFocus;

  /// 지금 포커스 모드인가 — 이름표가 "들어가기" 인지 "나가기" 인지 알려준다.
  final bool focused;

  const _PersonStand({
    required this.c,
    required this.clock,
    required this.index,
    required this.main,
    required this.mainRun,
    required this.title,
    required this.onFocus,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) {
    // 서 있되 죽어 있진 않게 — 아주 느린 숨(±1.5px). [index] 로 사람마다 위상을 어긋내
    // 여럿이 한 박자로 들썩이는 걸 막는다.
    final breathe = math.sin(clock * 0.9 + index * 1.7) * 1.5;
    final spriteTop = groundY - footInset(c.sprite) * personSize;
    final tool = (main == null || main!.toolCalls.isEmpty) ? null : main!.toolCalls.last;
    return Positioned(
      left: c.play.left, // 열 폭 = 이름표가 잘리지 않을 만큼 넓다(personFeet 가 그 중앙)
      top: c.personFeet.dy - groundY,
      width: c.play.width,
      height: cellH,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: spriteTop + breathe,
            child: Center(child: _person(context)),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: cellH - spriteTop + 2, // 스프라이트 박스 바로 위(숨쉬어도 이름표는 안 흔들리게)
            // 칩은 이름표와 한 줄 — 이름표가 이미 머리 위다. 따로 한 줄을 더 얹으면 열 머리가
            // 씬 밖으로 나가 잘린다(사람 셀 top = feetY-groundY 라 짧은 창에선 음수).
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tool != null) ...[
                    _ToolChip(tool: tool, color: agentColor(mainAgentType)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: _SessionPlate(
                      sessionId: c.sessionId,
                      title: title,
                      onFocus: onFocus,
                      focused: focused,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 사람 스프라이트 — [mainRun] 이 있으면 눌러서 그 세션이 **지금 하는 일**을 연다(동물의
  /// 탭과 같은 [_AgentLogSheet], `live` 로 지시=최신 last-prompt·활동 최근순). 없으면 그냥 스프라이트.
  Widget _person(BuildContext context) {
    final sprite = _Critter(
      sprite: c.sprite,
      phase: 0,
      running: false, // 사람은 서 있는다 — 뛰는 건 동물뿐
      size: personSize,
    );
    final run = mainRun;
    if (run == null) return sprite; // 아직 메인을 못 봤다 → 열 자체가 안 눌린다
    final tool = main == null || main!.toolCalls.isEmpty ? null : main!.toolCalls.last;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        waitDuration: const Duration(milliseconds: 250),
        message: '${title ?? '세션'}\n'
            '${_projectLabel(run.project)} · '
            '${compactTokens(run.inputTokens + run.outputTokens)} tokens · '
            '도구 ${run.toolCalls.length}회'
            '${tool == null ? '' : '\n▸ ${tool.name} ${tool.detail}'}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, // Image 는 hitTestSelf=false
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _AgentLogSheet(run: run, live: true),
          ),
          child: sprite,
        ),
      ),
    );
  }
}

/// 씬 안의 동물 한 마리 = 셀(104×106) 1개. 위에서부터 도구 칩 · 스프라이트 · 발밑 라벨,
/// 그리고 지면선([groundY])에 발밑 그림자. 셀 기하가 고정이라 원근 스케일이 변해도
/// 지면선이 안 흔들린다.
class _SceneCritter extends StatelessWidget {
  final Beast b;
  final double clock; // 씬 시계 — 이모트 팝 진행도를 유도한다(위젯엔 타이머가 없다)
  final bool thinking; // 💭 — 도구 소식이 한동안 없다(LLM 생각 중)
  final bool crowned; // 👑 — 지금 output 토큰 최다
  final double size;
  final bool label;
  final ValueChanged<bool> onHover;

  const _SceneCritter({
    required this.b,
    required this.clock,
    required this.thinking,
    required this.crowned,
    required this.size,
    required this.label,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final run = b.run;
    final cur = run.toolCalls.isEmpty ? null : run.toolCalls.last;
    final spriteTop = groundY - footInset(b.sprite) * size;
    final lift = b.moving ? hopWave(b.phase) : 0.0;
    final rw = size * 0.30 * (1 - 0.35 * lift); // 뛰어오르면 그림자가 작아져 '높이' 가 보인다
    // 축하 진행도(0..1) — 일을 끝낸 마리만. 모델이 fade 를 이만큼 미뤄 준다.
    final party = b.celebrateUntil > clock
        ? 1 - (b.celebrateUntil - clock) / celebrateFor
        : null;
    return Opacity(
      opacity: b.fade,
      child: Stack(
        children: [
          // ⓪ 축하 별 — 스프라이트 중심에서 6방향으로 퍼지며 옅어진다. 마리당 6개 ×
          //    celebrateFor(1.1초) 한정이라 상시구동에도 상한이 저절로 잡힌다.
          if (party != null)
            for (int i = 0; i < 6; i++)
              Positioned(
                left: cellW / 2 - 5 +
                    math.cos(i * math.pi / 3) * party * 24,
                top: spriteTop + size / 2 - 5 +
                    math.sin(i * math.pi / 3) * party * 24,
                child: Opacity(
                  opacity: math.max(0.0, 1 - party),
                  child: const Text('✦',
                      style: TextStyle(fontSize: 10, height: 1, color: Color(0xFFFDE047))),
                ),
              ),
          // ① 발밑 그림자 — 타입색을 섞어 정체성을 땅에도 남긴다.
          Positioned(
            left: cellW / 2 - rw,
            top: groundY - rw * 0.35,
            width: rw * 2,
            height: rw * 0.7,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.lerp(Colors.black, b.color, 0.5)!
                    .withValues(alpha: 0.22 * b.fade),
                borderRadius: BorderRadius.all(Radius.elliptical(rw, rw * 0.35)),
              ),
            ),
          ),
          // ② 머리 위 슬롯 — 이모트(새 도구 호출 순간, [emoteFor] 수명) > 💭(생각 중) >
          //    상시 도구 칩. 한 슬롯을 나눠 쓴다: 따로 얹으면 chipH(16px) 밖으로 나가
          //    셀 기하가 깨진다.
          if (b.emote != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: chipH,
              child: Center(
                child: Transform.scale(
                  scale: _emotePop(clock - b.emoteAt),
                  child: Text(b.emote!,
                      style: const TextStyle(fontSize: 12, height: 1)),
                ),
              ),
            )
          else if (thinking)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: chipH,
              child: const Center(
                child: Text('💭', style: TextStyle(fontSize: 12, height: 1)),
              ),
            )
          else if (cur != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: chipH,
              child: Center(child: _ToolChip(tool: cur, color: b.color)),
            ),
          // ③ 스프라이트 — 제스처는 여기에만. 셀 전체에 걸면 투명 여백이 이웃의 클릭을 가로챈다.
          Positioned(
            left: 0,
            right: 0,
            top: spriteTop,
            child: Center(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                // 호버하면 멈춘다 — 움직이는 타깃은 툴팁으로 읽을 수 없다.
                onEnter: (_) => onHover(true),
                onExit: (_) => onHover(false),
                child: Tooltip(
                  waitDuration: const Duration(milliseconds: 250),
                  message: '${run.agentType}\n'
                      '${run.description.isEmpty ? '(지시 없음)' : run.description}\n'
                      '${_elapsed(run.endedAt.difference(run.startedAt))} · '
                      '${compactTokens(run.inputTokens + run.outputTokens)} tokens · '
                      '도구 ${run.toolCalls.length}회'
                      '${cur == null ? '' : '\n▸ ${cur.name} ${cur.detail}'}',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque, // Image 는 hitTestSelf=false
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      // 씬의 종·색을 그대로 — 라이브 배정은 등장마다 섞여 run 으로 복원 불가.
                      builder: (_) => _AgentLogSheet(
                          run: b.run, sprite: b.sprite, color: b.color),
                    ),
                    // 😵(dizzy) 는 이모트 수명 동안 한 바퀴 — 각도는 clock 유도라 타이머가 없다.
                    child: Transform.rotate(
                      angle: b.dizzy
                          ? (clock - b.emoteAt) / emoteFor * 2 * math.pi
                          : 0,
                      child: _Critter(
                        sprite: b.sprite,
                        phase: b.phase,
                        running: b.moving,
                        size: size,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // ④ 왕관 — 지금 제일 많이 뱉은 마리. 스프라이트 머리에 얹고 [lift] 로 같이 뛴다
          //    (안 그러면 콩콩 뛸 때 왕관만 공중에 남는다).
          if (crowned)
            Positioned(
              left: 0,
              right: 0,
              top: spriteTop + size * 0.04 - lift * 4,
              child: const Center(
                child: Text('👑', style: TextStyle(fontSize: 11, height: 1)),
              ),
            ),
          // ⑤ 동작 이름표 — 타입(workflow-subagent)이 아니라 **지금 무슨 일을 하는지**(지시)를
          //    labelMaxChars 자로 잘라 건다. 타입은 동물 종·발밑 그림자색이 이미 말하고,
          //    사람이 궁금한 건 "이 마리가 뭘 하나" 다. 전문은 탭하면 상세 로그 맨 앞에.
          //    슬롯이 지면선~셀 바닥 딱 labelH — 여기서 내리면 셀 밖이라 Stack 이 말없이 자른다.
          if (label)
            Positioned(
              left: 0,
              right: 0,
              top: groundY,
              height: labelH,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _plateBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      _actionLabel(run),
                      maxLines: 1,
                      softWrap: false, // 폭 넓은 ASCII 가 104px 셀에서 줄바꿈돼 잘리지 않게
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: b.color,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 이모트 팝 스케일 — 0.15s 에 0→1.25 로 튀고 1.0 으로 가라앉다 끝 0.2s 에 줄며 사라진다.
/// 입력은 발화 후 경과(초). 수명([emoteFor])은 모델(tick)이 끊으므로 여기는 모양만.
double _emotePop(double t) {
  if (t < 0.15) return 1.25 * t / 0.15;
  if (t < 0.3) return 1.25 - 0.25 * (t - 0.15) / 0.15;
  final left = emoteFor - t;
  return left < 0.2 ? math.max(0.0, left / 0.2) : 1.0;
}

/// 사람 이름표 — 이 메인(부모)이 무슨 일을 하는지/어디서인지.
///
/// [title] 은 그 세션의 최신 `ai-title`(사람이 읽는 제목). 없는 세션도 있어서(실측)
/// 그땐 예전처럼 세션ID 앞 8자로 폴백한다.
class _SessionPlate extends StatelessWidget {
  final String sessionId;
  final String? title;

  /// 누르면 이 세션만 크게 / 전체로 복귀. null = 열이 하나뿐 → 그냥 이름표.
  final VoidCallback? onFocus;
  final bool focused;

  const _SessionPlate({
    required this.sessionId,
    required this.title,
    this.onFocus,
    this.focused = false,
  });

  @override
  Widget build(BuildContext context) {
    final shortId = sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    final plate = DecoratedBox(
      decoration: BoxDecoration(
        color: _plateBg,
        borderRadius: BorderRadius.circular(5),
        // 누를 수 있다는 유일한 힌트 — 아이콘을 얹으면 좁은 열에서 제목을 먹는다.
        border: onFocus == null
            ? null
            : Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          title ?? '세션 $shortId',
          maxLines: 1,
          overflow: TextOverflow.ellipsis, // ai-title 은 열 폭보다 길 수 있다
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
    final tap = onFocus;
    if (tap == null) return plate;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        waitDuration: const Duration(milliseconds: 250),
        message: focused ? '전체 숲으로 돌아가기' : '이 세션만 크게 보기',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap,
          child: plate,
        ),
      ),
    );
  }
}

/// 씬 위에 뜨는 작은 버튼 — 이름표와 같은 판때기 톤(숲 위에 UI 를 덜 얹는다).
class _PlateButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PlateButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _plateBg,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

/// 머리 위 도구 칩 — 아이콘만. 이름까지 얹으면 104px 셀에서 글자 수프가 된다.
class _ToolChip extends StatelessWidget {
  final ToolCall tool;
  final Color color;
  const _ToolChip({required this.tool, required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _plateBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Icon(_toolIcon(tool.name), size: 11, color: color),
      ),
    );
  }
}
