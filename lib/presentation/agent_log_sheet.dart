import 'dart:async';
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

/// 상세 읽기의 아이솔레이트 스폰 — **반드시 이 톱레벨의 깨끗한 스코프에서 클로저를 만든다.**
///
/// Dart 는 같은 스코프의 클로저들이 캡처 Context 를 공유한다 — 폴링하는 `_read` 안에서
/// `Isolate.run(...)` 을 만들면 이웃 `setState` 클로저가 캡처한 State(→ Timer·Element,
/// unsendable)까지 스폰 메시지에 통째로 끌려가 "object is unsendable - _Timer" 로 터진다.
/// `agents_screen.dart` 의 [titlesInIsolate] 와 같은 함정이고, 처방도 같다.
Future<List<AgentStep>> _stepsInIsolate(String path, {required bool live}) =>
    Isolate.run(() => live ? _readMainSteps(path) : _readSteps(path));

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
  /// 폴링 주기 — 숲 씬과 같게. 시트를 열어둔 채로 새 도구가 올라오는 게 이 화면의 요지고,
  /// 파일 하나만 다시 읽으므로(실측 수십 ms) 이 간격이면 싸다.
  static const _poll = Duration(seconds: 2);

  /// 새 내용이 붙는 가장자리에서 이 안쪽이면 "따라가는 중" 으로 본다.
  /// 거기서 벗어나 읽고 있으면 건드리지 않는다(읽던 자리가 튀는 게 제일 짜증난다).
  static const _followSlack = 40.0;

  List<AgentStep>? _steps; // null = 첫 읽기 전(로딩)
  Object? _error;
  Timer? _timer;
  bool _busy = false; // 앞 읽기가 아직 → 겹치지 않게
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _read();
    // 끝난 마리의 파일은 더 자라지 않는다 → 폴링할 이유가 없다. 도는 동안만 따라간다.
    if (widget.run.isRunning) _timer = Timer.periodic(_poll, (_) => _read());
  }

  /// 파일을 통째로 다시 읽는다. 증분 파싱이 아닌 이유: 리더가 이미 파일 단위라 그 결을
  /// 따르고, 실패해도(읽는 사이 쓰이는 중 등) 조용히 다음 틱에 낫는다 — 이미 그린 로그를
  /// 에러 화면으로 날리지 않는다(첫 읽기만 예외: 보여줄 게 없으니 에러를 낸다).
  Future<void> _read() async {
    if (_busy) return;
    _busy = true;
    try {
      // 스폰은 [_stepsInIsolate] 에서 — 여기서 클로저를 만들면 아래 setState 가 캡처한
      // State 가 끌려가 스폰이 터진다(경로·플래그만 값으로 넘긴다).
      final steps = await _stepsInIsolate(widget.run.filePath, live: widget.live);
      if (!mounted) return; // 시트를 닫았다 — 죽은 State 에 setState 금지
      final follow = _atFollowEdge; // 갈아 끼우기 **전에** 본다(뒤에 보면 이미 늘어난 높이다)
      setState(() {
        _steps = steps;
        _error = null;
      });
      if (follow) _stickToEdge();
    } catch (e) {
      if (!mounted) return;
      if (_steps == null) setState(() => _error = e); // 첫 읽기 실패만 화면에
    } finally {
      _busy = false;
    }
  }

  /// 새 내용이 붙는 쪽 — **두 경로의 정렬이 정반대다**(리더):
  ///  - 서브([readSteps], 정순): 새 도구가 맨 **아래** → 바닥을 따라간다.
  ///  - 메인([readMainSteps], `activity.reversed`): 새 활동이 맨 **위** → 머리를 따라간다.
  ///    메인 세션 파일은 수천 줄이라 "지금 하는 일" 을 맨 위에 올리려고 일부러 뒤집은 것이다.
  ///
  /// 한쪽만 보고 짜면 다른 쪽에서 **새 내용에서 멀어지는 방향**으로 밀어 버린다(실제로 그랬다).
  bool get _followsHead => widget.live;

  /// 지금 그 가장자리를 보고 있나 — 아직 안 붙었으면(첫 프레임) 따라가는 것으로 친다.
  bool get _atFollowEdge {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return _followsHead
        ? p.pixels <= _followSlack
        : p.maxScrollExtent - p.pixels <= _followSlack;
  }

  /// 새 줄이 붙은 만큼 그 가장자리로. 레이아웃이 끝나야 maxScrollExtent 가 새 높이라
  /// 다음 프레임에 민다(지금 밀면 늘기 전 값이다).
  void _stickToEdge() {
    if (_followsHead) {
      // 머리는 늘 0 이라 지금 밀어도 되지만, 목록이 갈리는 프레임과 겹치지 않게 맞춰 둔다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(0);
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _timer?.cancel(); // 닫히면 폴링도 멈춘다
    _scroll.dispose();
    super.dispose();
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
          Expanded(child: _log(color)),
        ],
      ),
    );
  }

  /// 로그 본문 — 첫 읽기 전엔 스피너, 그 뒤론 [_read] 가 갈아 끼우는 목록.
  /// 폴링 실패는 여기 안 온다([_read] 가 이미 그린 것을 지키고 다음 틱에 낫는다).
  Widget _log(Color color) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Text('로그 읽기 실패: $error', style: const TextStyle(fontSize: 12)),
      );
    }
    final steps = _steps;
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
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: steps.length,
      itemBuilder: (context, i) => _StepRow(step: steps[i], color: color),
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

