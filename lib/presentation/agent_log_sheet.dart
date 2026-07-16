import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/util/format.dart';
import '../data/providers/claude_code/agent_run_reader.dart';
import '../domain/models/agent_run.dart';
import 'agent_widgets.dart';
import 'forest_scene.dart';

/// 상세 로그는 클릭한 1마리 것만 그때 읽는다 — 파일 하나라 전체 스캔보다 훨씬 싸다.
/// 아이솔레이트 진입점: 경로만 넘긴다(클로저가 State 를 잡으면 넘어가지 못한다).
List<AgentStep> _readSteps(String filePath) =>
    AgentRunReader().readSteps(filePath);

/// 메인 세션(사람) 클릭 상세 — 서브와 달리 지시=최신 last-prompt, 활동=최근순([readMainSteps]).
List<AgentStep> _readMainSteps(String filePath) =>
    AgentRunReader().readMainSteps(filePath);

/// 카드의 아이콘 줄로는 "Read 를 12번 했다" 까지고, **뭘** 읽었는지는 여기서 본다.
class AgentLogSheet extends StatefulWidget {
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
  const AgentLogSheet({
    super.key,
    required this.run,
    this.live = false,
    this.sprite,
    this.color,
  });

  @override
  State<AgentLogSheet> createState() => _AgentLogSheetState();
}

class _AgentLogSheetState extends State<AgentLogSheet> {
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
                  child: Critter(
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
                          TypeBadge(agentType: run.agentType, color: color),
                          const SizedBox(width: 8),
                          Text(
                            '${projectLabel(run.project)} · '
                            '${elapsed(run.endedAt.difference(run.startedAt))} · '
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
          ? ToolLine(tool: tool, color: color)
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

