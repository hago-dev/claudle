import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart'; // material.dart 는 Ticker 를 export 하지 않는다

import '../core/util/format.dart';
import '../domain/models/agent_run.dart';
import 'agent_log_sheet.dart';
import 'agent_widgets.dart';
import 'forest_scene.dart';

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
class ForestSceneView extends StatefulWidget {
  final List<AgentRun> runs;
  const ForestSceneView({super.key, required this.runs});

  @override
  State<ForestSceneView> createState() => _ForestSceneState();
}

class _ForestSceneState extends State<ForestSceneView>
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
  void didUpdateWidget(covariant ForestSceneView oldWidget) {
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
  /// 탭과 같은 [AgentLogSheet], `live` 로 지시=최신 last-prompt·활동 최근순). 없으면 그냥 스프라이트.
  Widget _person(BuildContext context) {
    final sprite = Critter(
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
            '${projectLabel(run.project)} · '
            '${compactTokens(run.inputTokens + run.outputTokens)} tokens · '
            '도구 ${run.toolCalls.length}회'
            '${tool == null ? '' : '\n▸ ${tool.name} ${tool.detail}'}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, // Image 는 hitTestSelf=false
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => AgentLogSheet(run: run, live: true),
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
                      '${elapsed(run.endedAt.difference(run.startedAt))} · '
                      '${compactTokens(run.inputTokens + run.outputTokens)} tokens · '
                      '도구 ${run.toolCalls.length}회'
                      '${cur == null ? '' : '\n▸ ${cur.name} ${cur.detail}'}',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque, // Image 는 hitTestSelf=false
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      // 씬의 종·색을 그대로 — 라이브 배정은 등장마다 섞여 run 으로 복원 불가.
                      builder: (_) => AgentLogSheet(
                          run: b.run, sprite: b.sprite, color: b.color),
                    ),
                    // 😵(dizzy) 는 이모트 수명 동안 한 바퀴 — 각도는 clock 유도라 타이머가 없다.
                    child: Transform.rotate(
                      angle: b.dizzy
                          ? (clock - b.emoteAt) / emoteFor * 2 * math.pi
                          : 0,
                      child: Critter(
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
                      actionLabel(run),
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
        child: Icon(toolIcon(tool.name), size: 11, color: color),
      ),
    );
  }
}
