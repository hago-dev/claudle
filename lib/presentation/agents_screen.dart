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

/// 아이솔레이트 진입점 — [AgentRunReader.readAll] 은 1400+ 파일을 동기로 읽어(실측 2.3초)
/// UI 스레드에서 부르면 그동안 프레임이 통째로 멈춘다. [AgentRun] 은 평범한 값 객체라
/// 아이솔레이트 경계를 복사로 넘어온다.
List<AgentRun> _readAllRuns() => AgentRunReader().readAll();

/// 라이브 폴링 진입점 — mtime 이 최근인 파일만 읽어(수십 ms) 매 초 돌려도 싸다.
List<AgentRun> _readLiveRuns() => AgentRunReader().readLive();

/// 상세 로그는 클릭한 1마리 것만 그때 읽는다 — 파일 하나라 [_readAllRuns] 보다 훨씬 싸다.
List<AgentStep> _readSteps(String filePath) =>
    AgentRunReader().readSteps(filePath);

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
      setState(() {
        _runs = runs;
        _groups = _groupRuns(runs);
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
      final n = _liveRuns!.where((r) => r.isRunning).length;
      return Text('실행 중 $n마리', style: style);
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
                  sprite: 'animal-${agentAnimal(run.agentType)}',
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
  const _TypeBadge({required this.agentType});

  @override
  Widget build(BuildContext context) {
    final color = agentColor(agentType);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        agentType,
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
  const _AgentLogSheet({required this.run});

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
    _steps = Isolate.run(() => _readSteps(path));
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final color = agentColor(run.agentType);
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
                    sprite: 'animal-${agentAnimal(run.agentType)}',
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
                          _TypeBadge(agentType: run.agentType),
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

/// 로그 한 줄 — 도구 호출이거나, 에이전트가 쓴 글이거나.
class _StepRow extends StatelessWidget {
  final AgentStep step;
  final Color color;
  const _StepRow({required this.step, required this.color});

  @override
  Widget build(BuildContext context) {
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
                color:
                    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
    );
  }
}

// ── 색 ─────────────────────────────────────────────────────

/// 자주 보이는 타입은 고정 색(눈에 익게), 나머지 롱테일(총 23종)은 이름 해시 → 팔레트.
const Map<String, Color> _fixedColors = {
  'workflow-subagent': Color(0xFF7C5CFF), // 앱 시드 바이올렛
  'delegate': Color(0xFF4ADE80),
  'general-purpose': Color(0xFF38BDF8),
  'Explore': Color(0xFFFBBF24),
  'red-team': Color(0xFFF87171),
  'researcher': Color(0xFFA78BFA),
  'security-auditor': Color(0xFFFB923C),
  'code-reviewer': Color(0xFF34D399),
  'test-writer': Color(0xFF22D3EE),
  'Plan': Color(0xFFE879F9),
  'mentor': Color(0xFFFDE047),
};

const List<Color> _palette = [
  Color(0xFF60A5FA),
  Color(0xFFF472B6),
  Color(0xFF2DD4BF),
  Color(0xFFC084FC),
  Color(0xFFFACC15),
  Color(0xFF94A3B8),
];

/// 타입별 색. 해시는 직접 계산한다 — `String.hashCode` 는 런타임이 바꿀 수 있어
/// 실행할 때마다 색이 달라질 수 있다(같은 에이전트는 늘 같은 색이어야 함).
Color agentColor(String agentType) {
  final fixed = _fixedColors[agentType];
  if (fixed != null) return fixed;
  var h = 0;
  for (final c in agentType.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _palette[h % _palette.length];
}

// ── 그룹 ────────────────────────────────────────────────────

/// 재생 단위 — 같은 워크플로우(있으면), 없으면 같은 세션에서 뜬 에이전트 묶음.
class _RunGroup {
  final String key;
  final bool isWorkflow;
  final List<AgentRun> runs; // 시작 시각 오름차순
  final DateTime startedAt;
  final DateTime endedAt;

  _RunGroup(this.key, this.isWorkflow, this.runs)
      : startedAt = runs.first.startedAt,
        endedAt = runs
            .map((r) => r.endedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);

  Duration get span => endedAt.difference(startedAt);
  int get tokens =>
      runs.fold(0, (s, r) => s + r.inputTokens + r.outputTokens);
  String get title => isWorkflow
      ? '워크플로우 $key'
      : '세션 ${key.length > 8 ? key.substring(0, 8) : key}';
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

/// 의미가 맞는 타입은 고정 배정(눈에 익게), 나머지는 아래 해시로 24종 중 결정론적 선택.
const Map<String, String> _fixedAnimals = {
  'delegate': 'dog',
  'Explore': 'fox',
  'red-team': 'tiger',
  'security-auditor': 'polar', // 북극곰
  'researcher': 'monkey',
  'code-reviewer': 'cat',
  'test-writer': 'beaver',
  'workflow-subagent': 'bee',
  'mentor': 'elephant',
  'Plan': 'giraffe',
  'doc-generator': 'parrot',
  'general-purpose': 'bunny',
  'first-principles': 'lion',
  'db-specialist': 'crab',
  'claude-code-guide': 'koala',
};

/// `assets/agents/animal-<name>.png` 24종. 해시 배정 풀이자 declared asset 목록과 1:1.
const List<String> _animalPool = [
  'beaver', 'bee', 'bunny', 'cat', 'caterpillar', 'chick', 'cow', 'crab',
  'deer', 'dog', 'elephant', 'fish', 'fox', 'giraffe', 'hog', 'koala',
  'lion', 'monkey', 'panda', 'parrot', 'penguin', 'pig', 'polar', 'tiger',
];

/// 타입 → 큐브펫 이름. 해시는 [agentColor] 와 같은 방식으로 직접 계산한다 —
/// `String.hashCode` 는 실행마다 바뀔 수 있어(같은 에이전트는 늘 같은 동물이어야 함).
String agentAnimal(String agentType) {
  final fixed = _fixedAnimals[agentType];
  if (fixed != null) return fixed;
  if (agentType.startsWith('qa-')) return 'chick'; // qa-triage 등
  var h = 0;
  for (final c in agentType.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _animalPool[h % _animalPool.length];
}

/// `assets/agents/character-<...>.png` 12종 — 서브를 스폰한 메인(부모)을 상징하는 사람.
/// 동물이 서브에이전트라면 이쪽은 그 위의 감독자(세션).
const List<String> _personPool = [
  'character-male-a', 'character-male-b', 'character-male-c',
  'character-male-d', 'character-male-e', 'character-male-f',
  'character-female-a', 'character-female-b', 'character-female-c',
  'character-female-d', 'character-female-e', 'character-female-f',
];

/// 세션 → 사람 스프라이트. 같은 세션(그 세션이 스폰한 서브들의 부모)은 늘 같은 사람이 되게
/// [agentColor]·[agentAnimal] 과 같은 h*31+c 로 직접 계산한다(실행마다 안 바뀌게).
String personSprite(String sessionId) {
  var h = 0;
  for (final c in sessionId.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _personPool[h % _personPool.length];
}

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

// ── 숲 씬(라이브) ────────────────────────────────────────────
//
// 세션(부모) = 사람 1명이 제 빈터 **위**에 서 있고, 그 세션이 띄운 서브 = 동물들이 그
// 앞마당(빈터)에서 논다. 세션 1개 = 세로 열 1개.
//
// 단순화: 인파일 섹션 — 원래 lib/presentation/forest_scene.dart 로 뺄 서브시스템이다.
// 필요 시 이 섹션 전체를 그대로 옮기면 된다(위쪽 카드 UI 와 공유하는 건 _Critter·
// _TypeBadge·_AgentLogSheet·_toolIcon·agentColor/agentAnimal/personSprite 뿐).

// 씬 구획
const _padX = 24.0, _playTopGap = 30.0, _playPadBottom = 20.0, _minColW = 300.0;
// 크기 — 실측 기준. 동물 56 = 카드와 동일, 사람 64 = 1:1 네이티브.
const _animalSize = 56.0, _personSize = 64.0;
const _depthMin = 0.86, _depthSpan = 0.20; // 원근 스케일
// 셀(마리 1개 박스) — 고정 기하라 스케일이 변해도 지면선이 안 흔들린다.
const _cellW = 104.0, _chipH = 16.0, _spriteBoxH = 72.0, _labelH = 18.0;
const _cellH = _chipH + _spriteBoxH + _labelH; // 106
const _groundY = _chipH + _spriteBoxH; // 88 — 셀 안 지면선
// 배회
const _speedWander = 26.0, _speedWanderVar = 20.0; // 26..46 px/s
const _speedChase = 78.0, _speedChaseVar = 34.0; // 78..112 px/s
const _arriveWander = 3.0, _arriveChase = 26.0; // 26 = 겹치기 전에 멈춘다
// 위상/초 — [_Critter] 는 한 위상에 두 번 튄다 → 1.4 ≈ 기존 700ms 컨트롤러.
const _bobHzWander = 1.4, _bobHzChase = 2.3;
const _restMin = 0.4, _restVar = 1.2, _repick = 6.0, _maxDt = 0.05;
const _spawnJitter = 14.0, _fadeOut = 0.45;
// 상한
const _labelMax = 12, _beastMax = 48;
// 팔레트 — 앱은 dark 단일(main.dart). 숲은 초록이라 시드(바이올렛)를 안 따른다(의도).
const _skyTop = Color(0xFF16281C), _skyBottom = Color(0xFF2A4A31);
const _plateBg = Color(0xB3101A14);

/// 스프라이트 콘텐츠 바닥이 64px 캔버스 바닥에서 뜬 픽셀 — alpha bbox 실측값. 기본 9.
/// 아래 종들은 프레임 안에 작게 그려져 많이 뜬다(안 넣으면 발밑 그림자가 6~10px 어긋난다).
const _botGap = <String, int>{
  'animal-monkey': 14, 'animal-fish': 15, 'animal-koala': 16, 'animal-parrot': 17,
  'animal-elephant': 17, 'animal-penguin': 18, 'animal-chick': 18, 'animal-crab': 19,
  'forest-rocks-high': 0, 'forest-tent': 5, 'forest-rocks-low': 8, 'forest-stones': 8,
  'forest-tree': 12, 'forest-rocks-ramp': 12, 'forest-tree-high': 13, 'forest-flag': 14,
  'forest-plant': 21,
};

/// 콘텐츠 발이 스프라이트 박스 top 에서 차지하는 비율 — 그리기: `top = 발밑y - _footInset(s)*size`.
/// 사람 12종은 전부 botGap 12~13 이라 한 값, 표에 없는 동물 16종은 6~11 이라 기본 9(최대 오차 2.6px).
double _footInset(String s) =>
    (64 - (s.startsWith('character-') ? 12 : (_botGap[s] ?? 9))) / 64; // 0.70(crab) ~ 1.0(rocks-high)

/// 팩마다 캔버스 대비 콘텐츠 스케일이 달라(나무 22×38 < 여우 39×46) 종류별 렌더 크기가 강제된다.
/// 64px 로 그리면 여우가 나무보다 큰 숲이 된다. 값 옆은 실제 렌더 결과(px).
/// 숲 팩 13종 중 11종만 반입 — bridge(물이 없다)·fence(가로 1세그먼트라 경계로 못 쓴다) 제외.
const _propSize = <String, double>{
  'forest-tree': 132, // 45×78  (여우 34×40 의 약 2배 높이)
  'forest-tree-high': 150, // 38×87  (좁고 큰 침엽수)
  'forest-rocks-high': 76, // 62×76
  'forest-rocks-low': 60, 'forest-rocks-ramp': 60,
  'forest-tent': 84, // 68×64  (사람 36×40 보다 크게)
  'forest-flag': 72, 'forest-plant': 44, 'forest-stones': 40,
  'forest-patch-grass': 96, 'forest-patch-dirt': 88,
};

/// 뒷숲 추첨 풀 — 나무가 두 번 들어가 흔한 쪽으로 기운다(숲이니까).
const _backKinds = [
  'forest-tree', 'forest-tree-high', 'forest-rocks-high',
  'forest-tree', 'forest-rocks-ramp', 'forest-tree-high',
];

/// 콩콩 파형(0..1, 위로) — 한 위상에 두 번. [_Critter] 와 숲 씬의 발밑 그림자가 같이 쓴다.
double hopWave(double phase) => math.sin(phase * 2 * math.pi).abs();

/// 씬 배치용 결정론 해시 — [agentColor]·[agentAnimal]·[personSprite] 와 같은 h*31+c 규약.
/// [salt] 로 같은 키에서 독립된 값을 여러 개 뽑는다(x·y·종류). 폴링마다 숲이 춤추지 않게.
int _sceneHash(String key, int salt) {
  var h = salt & 0x7fffffff;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

double _sceneRand(String key, int salt) => (_sceneHash(key, salt) % 10007) / 10007.0;

/// 배경 소품 1개. [flat] = 바닥 얼룩(중심 앵커), 아니면 발밑 앵커([_footInset]).
class _Prop {
  final String sprite;
  final Offset at;
  final double size;
  final bool flat;
  const _Prop(this.sprite, this.at, this.size, {this.flat = false});
}

/// 세션 1개 = 세로 열 1개. 사람은 빈터 **위**에 고정, 동물은 빈터([play]) 안에서만 논다.
class _Clearing {
  final String sessionId, project, sprite; // sprite = personSprite(sessionId)
  final Offset personFeet;
  final Rect play;
  const _Clearing({
    required this.sessionId,
    required this.project,
    required this.sprite,
    required this.personFeet,
    required this.play,
  });
}

/// 씬 안의 동물 한 마리 = 도는 서브 1개. [run] 은 폴링마다 갈리지만 위치·기분은 이어진다.
class _Beast {
  final String agentId, sprite; // 'animal-fox' — agentAnimal 로 1회 결정
  final Color color; // agentColor(agentType)
  AgentRun run; // 폴링마다 교체(final 아님)
  String sessionId;
  Offset pos = Offset.zero, target = Offset.zero;
  double speed = 0, hopHz = 0, arrive = _arriveWander, rest = 0, until = 0;
  double phase = 0; // 0..1 — **개체별 누적**. 공유 위상이면 전원이 같은 박자로 뛴다(로봇)
  double fade = 1;
  bool moving = false, leaving = false, hovered = false, placed = false;
  String? chaseId; // 살아있는 추격 목표. null = 고정 목표점

  _Beast({
    required this.agentId,
    required this.sprite,
    required this.color,
    required this.run,
    required this.sessionId,
  });
}

/// 숲 씬의 모델 — 위젯을 모른다(순수 계산 + Listenable). 소유자는 [_ForestSceneState].
///
/// [tick] 만 notify 한다. [resize]·[sync] 는 빌드/레이아웃 중에 불려서 notify 하면
/// "setState during build" 로 죽는다.
class _ForestScene extends ChangeNotifier {
  final _beasts = <String, _Beast>{};
  final _byId = <String, _Clearing>{}; // sessionId → 빈터
  final _rnd = math.Random(); // 움직임은 결정론이 아니다 — 정체성(동물·색·사람)만 해시로 고정한다
  Map<String, String> _projectOf = const {}; // sessionId → project
  List<String> _sessions = const [];
  Size _size = Size.zero;
  Duration _last = Duration.zero;

  double clock = 0;
  List<_Clearing> clearings = const [];
  List<_Prop> floor = const [], back = const []; // 배경 — 리사이즈/세션 변화 때만 갱신
  int hidden = 0;
  double sceneW = 0, colW = 0;

  Iterable<_Beast> get beasts => _beasts.values;

  /// 이 마리가 노는 빈터 — 뷰가 원근 스케일(깊이)을 계산할 때 쓴다.
  _Clearing? clearingOf(String sessionId) => _byId[sessionId];

  /// 창 크기 변화 — [LayoutBuilder] 안에서 부른다. **notify 금지**.
  void resize(Size s) {
    if (s == _size) return;
    _size = s;
    _relayout();
  }

  /// 폴링 결과를 맞춘다 — 위치·기분은 그대로 두고 목록만. **notify 금지**.
  void sync(List<AgentRun> runs) {
    // 48 상한. startedAt 오름차순 = 폴링마다 집합이 안 흔들리는 안정 기준.
    final shown = runs.toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    hidden = math.max(0, shown.length - _beastMax);
    if (hidden > 0) shown.removeRange(_beastMax, shown.length);

    final live = <String>{};
    for (final r in shown) {
      live.add(r.agentId);
      final b = _beasts[r.agentId];
      if (b == null) {
        // 키는 agentId — 폴링은 매번 새 AgentRun 을 만들어서 객체 동일성으로 맞추면
        // 2초마다 전원이 리셋된다.
        _beasts[r.agentId] = _Beast(
          agentId: r.agentId,
          sprite: 'animal-${agentAnimal(r.agentType)}',
          color: agentColor(r.agentType),
          run: r,
          sessionId: r.sessionId,
        );
      } else {
        b.run = r;
        b.sessionId = r.sessionId;
        // isRunning 은 "마지막 레코드 60초 이내" 추정이라 false↔true 로 튄다 → 다시
        // 나타나면 사라지던 마리를 되살린다(안 그러면 사라졌다 나타난다).
        b.leaving = false;
        b.fade = 1;
      }
    }
    for (final b in _beasts.values) {
      if (!live.contains(b.agentId)) b.leaving = true;
    }

    // 열 = 지금 **마리가 있는** 세션. 사라지는 중(leaving)인 마리도 제 빈터에서 마저
    // 페이드해야 해서 runs 가 아니라 _beasts 에서 뽑는다 — 이 덕에 "모든 마리는 제 빈터를
    // 갖는다" 가 불변식이 된다(마지막 한 마리가 빠진 열은 다음 폴링에 접힌다).
    final projects = <String, String>{};
    for (final b in _beasts.values) {
      projects.putIfAbsent(b.sessionId, () => b.run.project);
    }
    final sessions = projects.keys.toList()..sort(); // readLive 는 mtime 순 → 정렬 안 하면 2초마다 사람이 자리를 바꾼다
    _projectOf = projects;
    // 열 구성이 그대로면(대개 그렇다) 열·소품을 다시 계산하지 않는다 — 2초마다 숲이 춤추지 않게.
    // 이미 깔린 것(_byId)과 비교하므로 크기가 0이라 걸러진 레이아웃도 다음 기회에 스스로 낫는다.
    if (sessions.length == _byId.length && sessions.every(_byId.containsKey)) {
      _spawnNew(); // 열 그대로 — 새로 뜬 마리만 세운다
    } else {
      _sessions = sessions;
      _relayout();
    }
  }

  /// 매 프레임 — **유일한 notify**.
  void tick(Duration elapsed) {
    // dt 상한 필수: 창을 숨기면 엔진이 프레임을 끊어(hidden·paused·detached) 복귀 시
    // elapsed 가 수 초 점프한다 → 없으면 전원 순간이동.
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, _maxDt);
    _last = elapsed;
    clock += dt;
    for (final b in _beasts.values) {
      final c = _byId[b.sessionId];
      if (c != null) _step(b, dt, c);
    }
    _beasts.removeWhere((_, b) => b.leaving && b.fade <= 0);
    notifyListeners();
  }

  void _step(_Beast b, double dt, _Clearing c) {
    if (b.leaving) {
      b.fade -= dt / _fadeOut;
      return;
    }
    if (b.hovered) {
      b.moving = false; // 호버하면 멈춘다 — 움직이는 걸 툴팁으로 읽을 수 없다
      return;
    }
    if (b.moving) b.phase = (b.phase + dt * b.hopHz) % 1.0;
    if (b.rest > 0) {
      b.rest -= dt;
      b.moving = false;
      return;
    }
    if (b.chaseId != null) {
      // 스냅샷이 아니라 라이브 추적 = 진짜로 쫓아간다
      final t = _beasts[b.chaseId];
      if (t == null || t.leaving) {
        _pick(b, c);
        return;
      }
      b.target = t.pos;
    }
    final d = b.target - b.pos, dist = d.distance;
    if (dist <= b.arrive) {
      _pick(b, c);
      return;
    }
    b.pos += d * (math.min(b.speed * dt, dist) / dist); // min → 오버슛(=떨림) 원천 봉쇄
    b.moving = true;
    b.until -= dt;
    if (b.until <= 0) _pick(b, c); // 안전망: 못 잡는 추격을 6초에 끊는다
  }

  /// 다음 놀이 — 쉬기 20% / 친구 쫓기 25%(혼자면 어슬렁) / 어슬렁 55%.
  ///
  /// 목표점이 항상 [play](볼록) 안이라 직선 이동은 밖으로 못 나간다 → 경계 반사·클램프 코드가
  /// 통째로 필요 없다. `pos ∈ play` 를 깨는 건 리사이즈뿐이고 그건 [_relayout] 이 잡는다.
  void _pick(_Beast b, _Clearing c) {
    b.chaseId = null;
    final r = _rnd.nextDouble();
    if (r < 0.20) {
      b.moving = false;
      b.hopHz = 0;
      b.rest = _restMin + _rnd.nextDouble() * _restVar;
      return;
    }
    if (r < 0.45) {
      final friends = [
        for (final o in _beasts.values)
          if (!o.leaving && o.agentId != b.agentId && o.sessionId == b.sessionId) o
      ];
      if (friends.isNotEmpty) {
        final t = friends[_rnd.nextInt(friends.length)];
        b
          ..chaseId = t.agentId
          ..target = t.pos
          ..speed = _speedChase + _rnd.nextDouble() * _speedChaseVar
          ..hopHz = _bobHzChase
          ..arrive = _arriveChase
          ..until = _repick
          ..moving = true;
        return;
      }
    }
    b
      ..target = Offset(c.play.left + _rnd.nextDouble() * c.play.width,
          c.play.top + _rnd.nextDouble() * c.play.height)
      ..speed = _speedWander + _rnd.nextDouble() * _speedWanderVar
      ..hopHz = _bobHzWander
      ..arrive = _arriveWander
      ..until = _repick
      ..moving = true;
  }

  /// 새로 뜬 마리는 제 사람 발밑에서 튀어나온다 — "이 세션이 얘를 띄웠다" 가 공짜 서사.
  void _spawnNew() {
    for (final b in _beasts.values) {
      if (b.placed) continue;
      final c = _byId[b.sessionId];
      if (c == null) continue; // 아직 레이아웃 전 — 첫 resize 가 다시 부른다
      b.pos = c.personFeet +
          Offset((_rnd.nextDouble() - 0.5) * _spawnJitter * 2,
              _rnd.nextDouble() * _spawnJitter);
      b.phase = _rnd.nextDouble(); // 같이 튀어나온 마리들이 한 박자로 뛰지 않게
      b.placed = true;
      _pick(b, c);
    }
  }

  /// 열·사람 앵커·소품 재계산 + `pos ∈ play` 복구. 리사이즈/세션 변화에서만.
  void _relayout() {
    final n = _sessions.length;
    if (n == 0 || _size.isEmpty) {
      clearings = const [];
      floor = const [];
      back = const [];
      _byId.clear();
      sceneW = 0;
      colW = 0;
      return;
    }
    sceneW = math.max(_size.width, n * _minColW); // 좁으면 씬을 넓히고 가로 스크롤
    colW = sceneW / n;
    final feetY = (_size.height * 0.26).clamp(76.0, 120.0);
    final cs = <_Clearing>[];
    final fl = <_Prop>[], bk = <_Prop>[];
    for (int i = 0; i < n; i++) {
      final sid = _sessions[i]; // 시드 = sessionId(불변) — project 시드는 폴링마다 숲을 재배치한다
      final colLeft = colW * i;
      final personFeet = Offset(colW * (i + 0.5), feetY);
      final play = Rect.fromLTRB(
        colLeft + _padX,
        feetY + _playTopGap,
        colLeft + colW - _padX,
        math.max(feetY + _playTopGap + 60, _size.height - _playPadBottom),
      );
      cs.add(_Clearing(
        sessionId: sid,
        project: _projectOf[sid] ?? '',
        sprite: personSprite(sid),
        personFeet: personFeet,
        play: play,
      ));

      // 1) 뒷숲 — 열을 슬롯으로 쪼개 칸마다 1개(해시로 그냥 뿌리면 뭉친다). 거절 샘플링 없음 = 무한루프 0.
      final slots = (colW / 120).round().clamp(3, 8);
      for (int k = 0; k < slots; k++) {
        final sx = colLeft +
            20 +
            (colW - 40) * (k + .5) / slots +
            (_sceneRand(sid, 100 + k * 3) - .5) * 30;
        if ((sx - personFeet.dx).abs() < 96) continue; // 캠프 자리는 비운다 = 빈터 입구
        final kind = _backKinds[_sceneHash(sid, 101 + k * 3) % _backKinds.length];
        // 발밑 y ∈ [feetY*0.66, feetY*0.96] — 이보다 위면 132px 나무의 우듬지가 씬 밖으로 잘린다.
        bk.add(_Prop(
          kind,
          Offset(sx, feetY * (0.66 + _sceneRand(sid, 102 + k * 3) * 0.30)),
          _propSize[kind]!,
        ));
      }

      // 2) 캠프 — 해시 안 씀. 모든 세션이 같은 모양이어야 '캠프' 라는 기호로 읽힌다.
      fl.add(_Prop('forest-patch-dirt', personFeet - const Offset(0, 4), 88, flat: true));
      bk.add(_Prop('forest-tent', personFeet + const Offset(-56, -2), 84));
      bk.add(_Prop('forest-flag', personFeet + const Offset(46, 0), 72));

      // 3) 바닥 얼룩 + 소형 장식 — 놀이터 안엔 납작하거나 아주 작은 것만(세로 소품은 전부
      //    놀이터 밖이라 소품↔동물 y-sort 가 아예 필요 없다 = 배경을 정적 레이어로 격리).
      final m = (play.width * play.height / 26000).round().clamp(3, 9);
      for (int k = 0; k < m; k++) {
        final kind = _sceneRand(sid, 300 + k * 3) < 0.72
            ? 'forest-patch-grass'
            : 'forest-patch-dirt';
        fl.add(_Prop(kind, _inPlay(sid, play, 301 + k * 3), _propSize[kind]!, flat: true));
      }
      final q = (play.width / 240).round().clamp(2, 4);
      for (int k = 0; k < q; k++) {
        final kind =
            _sceneRand(sid, 500 + k * 3) < 0.5 ? 'forest-plant' : 'forest-stones';
        bk.add(_Prop(kind, _inPlay(sid, play, 501 + k * 3), _propSize[kind]!));
      }
    }
    clearings = cs;
    floor = fl;
    back = bk;
    _byId
      ..clear()
      ..addEntries(cs.map((c) => MapEntry(c.sessionId, c)));

    for (final b in _beasts.values) {
      final c = _byId[b.sessionId];
      if (c == null || !b.placed) continue;
      b.pos = Offset(b.pos.dx.clamp(c.play.left, c.play.right),
          b.pos.dy.clamp(c.play.top, c.play.bottom));
      b.until = 0; // 전원 즉시 재추첨 — 목표가 새 빈터 밖에 남으면 가장자리에 붙어 선다
    }
    _spawnNew();
  }

  /// [play] 안의 결정론 좌표 — [salt], [salt]+1 두 개를 쓴다.
  Offset _inPlay(String sid, Rect play, int salt) => Offset(
        play.left + _sceneRand(sid, salt) * play.width,
        play.top + _sceneRand(sid, salt + 1) * play.height,
      );
}

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
  final _ForestScene _scene = _ForestScene();
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
    for (final sprite in _propSize.keys) {
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
    final ws = _scene.beasts.where((b) => b.fade > 0).toList()
      ..sort((a, b) {
        final c = a.pos.dy.compareTo(b.pos.dy);
        return c != 0 ? c : a.agentId.compareTo(b.agentId); // List.sort 는 불안정 — 동률 깜빡임 방지
      });
    final label = ws.length <= _labelMax; // 넘으면 글자 수프 — 칩·호버·탭은 그대로 남는다
    return Stack(
      children: [
        for (int i = 0; i < _scene.clearings.length; i++)
          _PersonStand(c: _scene.clearings[i], clock: _scene.clock, index: i),
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
      ],
    );
  }

  /// 마리 1개 = Stack 직계 [Positioned]. **key 필수** — 없으면 정렬이 바뀔 때 Stack 이
  /// 인덱스로 매칭해 다른 마리의 Element(호버·툴팁 상태)를 물려받는다.
  Widget _cell(_Beast b, bool label) {
    final c = _scene.clearingOf(b.sessionId);
    if (c == null) return const SizedBox.shrink(); // sync 가 마리마다 빈터를 보장한다
    final t = ((b.pos.dy - c.play.top) / c.play.height).clamp(0.0, 1.0);
    final size = _animalSize * (_depthMin + _depthSpan * t); // 48..59 — 아래(가까움)일수록 큼
    return Positioned(
      key: ValueKey(b.agentId),
      left: b.pos.dx - _cellW / 2,
      top: b.pos.dy - _groundY,
      width: _cellW,
      height: _cellH,
      child: _SceneCritter(
        b: b,
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
  final List<_Prop> floor, back;
  final double colW;
  final int cols;
  const _Backdrop({
    required this.floor,
    required this.back,
    required this.colW,
    required this.cols,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_skyTop, _skyBottom],
        ),
      ),
      child: Stack(
        children: [
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

  Widget _prop(_Prop p) => Positioned(
        left: p.at.dx - p.size / 2,
        top: p.flat
            ? p.at.dy - p.size / 2
            : p.at.dy - _footInset(p.sprite) * p.size,
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

/// 사람 1명 — 제 빈터 **위**에 고정. 동물은 빈터 안에서만 노니까 사람도 이름표도 안 가린다.
class _PersonStand extends StatelessWidget {
  final _Clearing c;
  final double clock;
  final int index;
  const _PersonStand({required this.c, required this.clock, required this.index});

  @override
  Widget build(BuildContext context) {
    // 서 있되 죽어 있진 않게 — 아주 느린 숨(±1.5px). [index] 로 사람마다 위상을 어긋내
    // 여럿이 한 박자로 들썩이는 걸 막는다.
    final breathe = math.sin(clock * 0.9 + index * 1.7) * 1.5;
    final spriteTop = _groundY - _footInset(c.sprite) * _personSize;
    return Positioned(
      left: c.play.left, // 열 폭 = 이름표가 잘리지 않을 만큼 넓다(personFeet 가 그 중앙)
      top: c.personFeet.dy - _groundY,
      width: c.play.width,
      height: _cellH,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: spriteTop + breathe,
            child: Center(
              child: _Critter(
                sprite: c.sprite,
                phase: 0,
                running: false, // 사람은 서 있는다 — 뛰는 건 동물뿐
                size: _personSize,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: _cellH - spriteTop + 2, // 스프라이트 박스 바로 위(숨쉬어도 이름표는 안 흔들리게)
            child: Center(
              child: _SessionPlate(sessionId: c.sessionId, project: c.project),
            ),
          ),
        ],
      ),
    );
  }
}

/// 씬 안의 동물 한 마리 = 셀(104×106) 1개. 위에서부터 도구 칩 · 스프라이트 · 발밑 라벨,
/// 그리고 지면선([_groundY])에 발밑 그림자. 셀 기하가 고정이라 원근 스케일이 변해도
/// 지면선이 안 흔들린다.
class _SceneCritter extends StatelessWidget {
  final _Beast b;
  final double size;
  final bool label;
  final ValueChanged<bool> onHover;

  const _SceneCritter({
    required this.b,
    required this.size,
    required this.label,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final run = b.run;
    final cur = run.toolCalls.isEmpty ? null : run.toolCalls.last;
    final spriteTop = _groundY - _footInset(b.sprite) * size;
    final lift = b.moving ? hopWave(b.phase) : 0.0;
    final rw = size * 0.30 * (1 - 0.35 * lift); // 뛰어오르면 그림자가 작아져 '높이' 가 보인다
    return Opacity(
      opacity: b.fade,
      child: Stack(
        children: [
          // ① 발밑 그림자 — 타입색을 섞어 정체성을 땅에도 남긴다.
          Positioned(
            left: _cellW / 2 - rw,
            top: _groundY - rw * 0.35,
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
          // ② 지금 만지는 도구 — 스무 마리가 각자 Bash/Read 를 달고 뛰는 게 이 씬의 맥박.
          if (cur != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: _chipH,
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
                      builder: (_) => _AgentLogSheet(run: b.run),
                    ),
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
          // ④ 타입 이름표 — 초록 위 대비로 판을 깔고, 긴 이름(workflow-subagent)은 알아서 줄인다.
          //    슬롯이 지면선~셀 바닥 딱 _labelH — 여기서 내리면 셀 밖이라 Stack 이 말없이 자른다.
          if (label)
            Positioned(
              left: 0,
              right: 0,
              top: _groundY,
              height: _labelH,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _plateBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _TypeBadge(agentType: run.agentType),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 사람 이름표 — 이 서브들을 스폰한 메인(부모)이 누구/어디인지.
class _SessionPlate extends StatelessWidget {
  final String sessionId, project;
  const _SessionPlate({required this.sessionId, required this.project});

  @override
  Widget build(BuildContext context) {
    final shortId = sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _plateBg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          '세션 $shortId · ${_projectLabel(project)}',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
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
