import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/util/format.dart';
import '../domain/models/agent_run.dart';
import 'agent_log_sheet.dart';
import 'agent_widgets.dart';
import 'forest_scene.dart';

// ── 기록 ────────────────────────────────────────────────────

/// 좌: 실행 목록(최근 것부터, 가상화) / 우: 선택한 실행의 재생.
class HistoryView extends StatefulWidget {
  final List<RunGroup> groups;
  const HistoryView({super.key, required this.groups});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  RunGroup? _selected;

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
  final RunGroup group;
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
                Critter(
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
              '${projectLabel(group.runs.first.project)} · '
              '${group.runs.length}마리 · ${elapsed(group.span)} · '
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
  final RunGroup group;
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
              Critter(
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
                      '${projectLabel(g.runs.first.project)} · 에이전트 ${g.runs.length}마리 · '
                      '${elapsed(g.span)} · ${compactTokens(g.tokens)} tokens',
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
                  '${elapsed(g.span * _clock.value)} / ${elapsed(g.span)}',
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
/// 누르면 이 마리의 전체 작업 로그([AgentLogSheet]).
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
          builder: (_) => AgentLogSheet(run: run),
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
                child: Critter(
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
                      TypeBadge(agentType: run.agentType),
                      const SizedBox(width: 8),
                      Text(
                        '${elapsed(run.endedAt.difference(run.startedAt))} · '
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
                        : ToolLine(tool: _current!, color: color),
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
                toolIcon(shown[i].name),
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


// ── 그룹 ────────────────────────────────────────────────────

/// 재생 단위 — 같은 워크플로우(있으면), 없으면 같은 세션에서 뜬 에이전트 묶음.
class RunGroup {
  final String key;
  final bool isWorkflow;
  final List<AgentRun> runs; // 시작 시각 오름차순
  final DateTime startedAt;
  final DateTime endedAt;

  /// 사람이 읽는 제목 — 워크플로우 `workflowName` / 세션 최신 `ai-title`.
  /// null = 못 찾음 → [title] 이 예전처럼 ID 로 폴백한다.
  final String? name;

  RunGroup(this.key, this.isWorkflow, this.runs, {this.name})
      : startedAt = runs.first.startedAt,
        endedAt = runs
            .map((r) => r.endedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);

  /// 제목만 채운 사본 — 제목은 그룹이 정해진 뒤에야 그 파일을 읽을 수 있어서([_load])
  /// [AgentRun.withDescription] 과 같은 순서 문제를 같은 방식으로 푼다.
  RunGroup withName(String? name) => RunGroup(key, isWorkflow, runs, name: name);

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
List<RunGroup> groupRuns(List<AgentRun> runs) {
  final byKey = <String, List<AgentRun>>{};
  for (final r in runs) {
    byKey.putIfAbsent(r.workflowId ?? r.sessionId, () => <AgentRun>[]).add(r);
  }
  final groups = <RunGroup>[];
  for (final e in byKey.entries) {
    final rs = e.value..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    groups.add(RunGroup(e.key, rs.first.workflowId != null, rs));
  }
  groups.sort((a, b) => b.endedAt.compareTo(a.endedAt));
  return groups;
}


