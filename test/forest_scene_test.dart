import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar/domain/models/agent_run.dart';
import 'package:tokenbar/presentation/forest_scene.dart';

/// 숲 씬 모델([ForestScene]) 스모크 — agents_screen 에서 분리되며 처음으로 테스트가 가능해졌다.
/// 씬의 계약: sync(폴링 diff, notify 금지) → resize(빈터 배치) → tick(유일한 notify, dt 적분).
void main() {
  final t0 = DateTime.utc(2026, 7, 16);

  AgentRun run(
    String id, {
    String session = 'sess-1',
    int outputTokens = 0,
    List<ToolCall> tools = const [],
  }) =>
      AgentRun(
        agentId: id,
        agentType: 'workflow-subagent',
        project: '-Users-me-proj',
        sessionId: session,
        filePath: '/tmp/agent-$id.jsonl',
        workflowId: null,
        description: '',
        startedAt: t0,
        endedAt: t0,
        toolCalls: tools,
        inputTokens: 0,
        outputTokens: outputTokens,
        isRunning: true,
      );

  test('등장 — sync→resize→tick 후 마리 1 + 빈터 1, 제 사람 발밑에 선다', () {
    final s = ForestScene(rnd: math.Random(1));
    final d = SceneDriver(s);
    s.sync([run('a1')]);
    s.resize(const Size(800, 600));
    d.advance(0.1);
    expect(s.beasts.length, 1);
    expect(s.clearings.length, 1);
    expect(s.clearingOf('sess-1'), isNotNull);
    expect(s.beasts.single.placed, isTrue);
  });

  test('퇴장 — 다음 sync 에서 빠지면 leaving, fade 끝나면 제거된다', () {
    final s = ForestScene(rnd: math.Random(1));
    final d = SceneDriver(s);
    s.sync([run('a1')]);
    s.resize(const Size(800, 600));
    d.advance(0.1);

    s.sync(const []);
    expect(s.beasts.single.leaving, isTrue);
    d.advance(celebrateFor + 1.0); // 축하가 끝나고 fade(0.45s)까지 지나면
    expect(s.beasts, isEmpty);
  });

  test('재등장 — leaving 중 같은 마리가 돌아오면 되살아난다(isRunning 60초 창 깜빡임 흡수)', () {
    final s = ForestScene(rnd: math.Random(1));
    final d = SceneDriver(s);
    s.sync([run('a1')]);
    s.resize(const Size(800, 600));
    d.advance(0.1);

    s.sync(const []);
    d.advance(0.2); // fade 진행 중
    s.sync([run('a1')]);
    final b = s.beasts.single;
    expect(b.leaving, isFalse);
    expect(b.fade, 1);
  });

  group('도구 이모트 말풍선', () {
    test('매핑 — _toolIcon 과 같은 도구명 규약', () {
      expect(toolEmote('Read'), '📖');
      expect(toolEmote('Bash'), '⚡');
      expect(toolEmote('BashOutput'), '⚡');
      expect(toolEmote('Edit'), '✍️');
      expect(toolEmote('Write'), '✍️');
      expect(toolEmote('Grep'), '🔍');
      expect(toolEmote('Glob'), '🔍');
      expect(toolEmote('WebFetch'), '🌐');
      expect(toolEmote('WebSearch'), '🌐');
      expect(toolEmote('Task'), '🐣'); // 서브에이전트 스폰 — 실측 도구명은 Agent 가 아니라 Task
      expect(toolEmote('mcp__context7__query-docs'), '🔌');
      expect(toolEmote('UnknownTool'), '🔧');
    });

    test('새 도구 호출 감지 — toolCalls 가 늘어난 sync 에서 발화, 스탬프 = 지금 clock', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      d.advance(0.5);

      s.sync([run('a1', tools: const [ToolCall('Bash', 'ls')])]);
      final b = s.beasts.single;
      expect(b.emote, '⚡');
      expect(b.emoteAt, s.clock);
    });

    test('만료 — emoteFor 가 지나면 tick 이 지운다(수명은 모델 소유)', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      d.advance(0.5);
      s.sync([run('a1', tools: const [ToolCall('Read', 'a.dart')])]);
      expect(s.beasts.single.emote, '📖');

      d.advance(emoteFor + 0.2);
      expect(s.beasts.single.emote, isNull);
    });

    test('미발화 — 첫 등장과 도구 불변 sync 에선 안 터진다', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      final tools = const [ToolCall('Bash', 'ls'), ToolCall('Read', 'a.dart')];
      s.sync([run('a1', tools: tools)]); // 첫 등장 — 이미 쌓인 이력은 이벤트가 아니다
      s.resize(const Size(800, 600));
      d.advance(0.1);
      expect(s.beasts.single.emote, isNull);

      s.sync([run('a1', tools: tools)]); // 불변 — 새 호출 없음
      expect(s.beasts.single.emote, isNull);
    });
  });

  group('실패 리액션 😵', () {
    test('toolCalls 개수 불변이어도 isError 증가만으로 발화한다(결과는 나중 줄로 도착)', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1', tools: const [ToolCall('Bash', 'x')])]);
      s.resize(const Size(800, 600));
      d.advance(0.5);

      // 파일 재파싱 — 같은 호출이 이번엔 is_error 로 읽혔다(개수 delta 없음).
      s.sync([run('a1', tools: const [ToolCall('Bash', 'x', isError: true)])]);
      final b = s.beasts.single;
      expect(b.emote, '😵');
      expect(b.dizzy, isTrue);
      expect(b.emoteAt, s.clock);
    });

    test('만료되면 dizzy 도 함께 풀린다', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1', tools: const [ToolCall('Bash', 'x')])]);
      s.resize(const Size(800, 600));
      d.advance(0.5);
      s.sync([run('a1', tools: const [ToolCall('Bash', 'x', isError: true)])]);

      d.advance(emoteFor + 0.2);
      final b = s.beasts.single;
      expect(b.emote, isNull);
      expect(b.dizzy, isFalse);
    });

    test('같은 에러로 재발화하지 않는다 + 첫 등장의 에러 이력도 이벤트가 아니다', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      // 첫 등장부터 에러 이력 보유 — 발화 없음.
      final errored = [const ToolCall('Bash', 'x', isError: true)];
      s.sync([run('a1', tools: errored)]);
      s.resize(const Size(800, 600));
      d.advance(0.1);
      expect(s.beasts.single.emote, isNull);

      // 같은 에러 상태로 폴링 반복 — 재발화 없음.
      s.sync([run('a1', tools: errored)]);
      expect(s.beasts.single.emote, isNull);
    });
  });

  group('생각 풍선 💭', () {
    test('도구 소식이 8초 없으면 thinking — LLM 이 생각 중이라는 뜻', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      d.advance(1.0);
      expect(s.thinking(s.beasts.single), isFalse); // 아직 8초 전

      d.advance(7.5);
      expect(s.thinking(s.beasts.single), isTrue);
    });

    test('새 도구가 도착하면 풀린다', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      d.advance(8.5);
      expect(s.thinking(s.beasts.single), isTrue);

      s.sync([run('a1', tools: const [ToolCall('Read', 'a.dart')])]);
      expect(s.thinking(s.beasts.single), isFalse);
    });

    test('leaving 마리는 생각하지 않는다', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      d.advance(8.5);

      s.sync(const []);
      expect(s.thinking(s.beasts.single), isFalse);
    });
  });

  group('완료 축하', () {
    ForestScene setup(SceneDriver Function(ForestScene) mkDriver) {
      final s = ForestScene(rnd: math.Random(1));
      final d = mkDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      d.advance(0.5);
      return s;
    }

    test('목록에서 빠지는 첫 sync 에 축하 구간이 잡힌다', () {
      late SceneDriver d;
      final s = setup((sc) => d = SceneDriver(sc));
      d.advance(0); // d 사용 표시
      s.sync(const []);
      final b = s.beasts.single;
      expect(b.leaving, isTrue);
      expect(b.celebrateUntil, greaterThan(s.clock));
    });

    test('축하 중엔 안 사라진다 — 끝나야 fade 가 시작되고 상한 수명 안에 제거된다', () {
      late SceneDriver d;
      final s = setup((sc) => d = SceneDriver(sc));
      s.sync(const []);

      d.advance(celebrateFor - 0.2); // 축하 진행 중
      expect(s.beasts.single.fade, 1);

      d.advance(0.4); // 축하 끝 + fade 시작
      expect(s.beasts.single.fade, lessThan(1));

      d.advance(1.0); // fadeOut(0.45s) 을 넉넉히 지나면 제거
      expect(s.beasts, isEmpty);
    });

    test('축하 중 재등장하면 축하·퇴장 모두 취소된다', () {
      late SceneDriver d;
      final s = setup((sc) => d = SceneDriver(sc));
      s.sync(const []);
      d.advance(0.5); // 축하 중

      s.sync([run('a1')]);
      final b = s.beasts.single;
      expect(b.leaving, isFalse);
      expect(b.fade, 1);
      expect(b.celebrateUntil, lessThanOrEqualTo(s.clock)); // 축하 꺼짐

      // 다시 빠지면 새 축하가 새로 잡힌다(첫 전환 감지가 리셋됐다는 증거).
      s.sync(const []);
      expect(b.celebrateUntil, greaterThan(s.clock));
    });

    test('leaving 유지 sync 반복이 축하를 연장하지 않는다', () {
      late SceneDriver d;
      final s = setup((sc) => d = SceneDriver(sc));
      s.sync(const []);
      final until = s.beasts.single.celebrateUntil;

      d.advance(0.3);
      s.sync(const []); // 여전히 빠져 있음 — 재발화 금지
      expect(s.beasts.single.celebrateUntil, until);
    });
  });

  group('토큰 먹고 성장', () {
    test('아무것도 안 뱉었으면 기본 크기', () {
      expect(growthScale(0), 1.0);
    });

    test('많이 뱉을수록 커진다(단조)', () {
      final scales = [0, 500, 2000, 10000, 50000].map(growthScale).toList();
      for (var i = 1; i < scales.length; i++) {
        expect(scales[i], greaterThan(scales[i - 1]));
      }
    });

    test('캡 — 아무리 뱉어도 셀 기하(spriteBoxH 72px)를 안 깬다', () {
      expect(growthScale(10000000), lessThanOrEqualTo(growthCap));
      // 최심도(가장 가까운 자리) × 캡이 스프라이트 박스를 넘으면 칩·이름표를 침범한다.
      expect(animalSize * (depthMin + depthSpan) * growthCap,
          lessThanOrEqualTo(spriteBoxH));
    });

    test('중간 구간에서 체감이 있다 — 5k 토큰이면 눈에 띄게 크다', () {
      expect(growthScale(5000), inInclusiveRange(1.05, 1.15));
    });
  });

  group('왕관 👑', () {
    test('output 토큰 최다 마리가 쓴다', () {
      final s = ForestScene(rnd: math.Random(1));
      s.sync([
        run('a1', outputTokens: 100),
        run('a2', outputTokens: 900),
        run('a3', outputTokens: 300),
      ]);
      expect(s.crownId, 'a2');
    });

    test('아무도 안 뱉었으면 왕관 없음 — 0 토큰은 왕이 아니다', () {
      final s = ForestScene(rnd: math.Random(1));
      s.sync([run('a1'), run('a2')]);
      expect(s.crownId, isNull);
    });

    test('동률은 먼저 시작한 쪽 — 폴링마다 왕관이 깜빡이지 않는다', () {
      final s = ForestScene(rnd: math.Random(1));
      final early = AgentRun(
        agentId: 'late-id', // id 정렬로 갈리면 안 된다는 걸 드러내려 이름을 반대로
        agentType: 'workflow-subagent',
        project: '-Users-me-proj',
        sessionId: 'sess-1',
        filePath: '/tmp/a.jsonl',
        workflowId: null,
        description: '',
        startedAt: t0,
        endedAt: t0,
        toolCalls: const [],
        inputTokens: 0,
        outputTokens: 500,
        isRunning: true,
      );
      final later = AgentRun(
        agentId: 'early-id',
        agentType: 'workflow-subagent',
        project: '-Users-me-proj',
        sessionId: 'sess-1',
        filePath: '/tmp/b.jsonl',
        workflowId: null,
        description: '',
        startedAt: t0.add(const Duration(seconds: 30)),
        endedAt: t0.add(const Duration(seconds: 30)),
        toolCalls: const [],
        inputTokens: 0,
        outputTokens: 500, // 동률
        isRunning: true,
      );
      s.sync([early, later]);
      expect(s.crownId, 'late-id'); // startedAt 이 빠른 쪽
      s.sync([later, early]); // 순서를 바꿔 폴링해도 그대로
      expect(s.crownId, 'late-id');
    });

    test('왕이 떠나면 차순위가 승계한다', () {
      final s = ForestScene(rnd: math.Random(1));
      s.sync([run('a1', outputTokens: 900), run('a2', outputTokens: 300)]);
      expect(s.crownId, 'a1');

      s.sync([run('a2', outputTokens: 300)]); // a1 퇴장(leaving)
      expect(s.crownId, 'a2');
    });
  });

  group('캠프파이어 모임', () {
    /// 캠프행은 확률 분기라 시드를 돌려 실제로 뽑힌 씬을 찾는다 — 시드가 고정이니 결정론이다.
    (ForestScene, SceneDriver)? findCamper() {
      for (var seed = 0; seed < 200; seed++) {
        final s = ForestScene(rnd: math.Random(seed));
        final d = SceneDriver(s);
        s.sync([run('a1')]);
        s.resize(const Size(800, 600));
        for (var i = 0; i < 40; i++) {
          d.advance(0.05);
          if (s.beasts.single.pendingRest > 0) return (s, d);
        }
      }
      return null;
    }

    test('캠프 자리는 사람 발밑 근처이고 늘 play 안이다', () {
      final s = ForestScene(rnd: math.Random(1));
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      final c = s.clearingOf('sess-1')!;
      final rnd = math.Random(3);
      for (var i = 0; i < 50; i++) {
        final spot = campSpot(c, rnd);
        expect(c.play.contains(spot), isTrue); // 목표점 ∈ play = 경계 클램프 불필요라는 불변식
        expect((spot.dx - c.personFeet.dx).abs(), lessThan(40)); // 캠프 앞마당
      }
    });

    test('캠프로 걸어간 마리는 도착해서 오래 쉰다', () {
      final found = findCamper();
      expect(found, isNotNull, reason: '200 시드 안에 캠프행이 한 번은 뽑혀야 한다');
      final (s, d) = found!;
      final b = s.beasts.single;
      final c = s.clearingOf('sess-1')!;
      expect((b.target.dx - c.personFeet.dx).abs(), lessThan(40)); // 캠프로 향한다

      d.advance(12); // 도착하고도 남을 시간 — 걸어가 pendingRest 를 rest 로 바꾼다
      expect(b.pendingRest, 0); // 한 번 쓰고 비운다
    });

    test('일반 어슬렁·쉬기는 캠프 예약을 남기지 않는다', () {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1')]);
      s.resize(const Size(800, 600));
      final b = s.beasts.single;
      var camped = false;
      for (var i = 0; i < 400; i++) {
        d.advance(0.05);
        if (b.pendingRest > 0) camped = true;
      }
      // 이 시드에선 캠프가 안 뽑혔다면 pendingRest 는 늘 0이어야 한다(= 다른 경로가 안 건드린다).
      if (!camped) expect(b.pendingRest, 0);
    });
  });

  group('낮/밤 배경', () {
    test('06:00~17:59 는 낮, 그 밖은 밤 — 경계에서 갈린다', () {
      expect(isNightAt(DateTime(2026, 7, 17, 5, 59)), isTrue);
      expect(isNightAt(DateTime(2026, 7, 17, 6, 0)), isFalse);
      expect(isNightAt(DateTime(2026, 7, 17, 17, 59)), isFalse);
      expect(isNightAt(DateTime(2026, 7, 17, 18, 0)), isTrue);
    });
  });

  group('세션 포커스', () {
    /// 세션 2개(각 1마리)가 도는 씬.
    (ForestScene, SceneDriver) twoSessions() {
      final s = ForestScene(rnd: math.Random(1));
      final d = SceneDriver(s);
      s.sync([run('a1', session: 'sess-A'), run('b1', session: 'sess-B')]);
      s.resize(const Size(800, 600));
      d.advance(0.2);
      return (s, d);
    }

    test('포커스하면 그 세션만 남고 열이 화면 전체를 쓴다 — 이게 "키워 보기"다', () {
      final (s, d) = twoSessions();
      expect(s.clearings.length, 2);
      final colWBefore = s.colW;

      s.setFocus('sess-A');
      s.sync([run('a1', session: 'sess-A'), run('b1', session: 'sess-B')]);
      d.advance(0.1);

      expect(s.clearings.length, 1);
      expect(s.clearings.single.sessionId, 'sess-A');
      expect(s.colW, s.sceneW); // 1열 = 씬 전체 폭
      expect(s.colW, greaterThan(colWBefore));
    });

    test('가려진 세션의 마리는 지워지지 않는다 — 돌아오면 놀던 자리에 그대로 있다', () {
      final (s, d) = twoSessions();
      final before = s.beasts.firstWhere((b) => b.agentId == 'b1').pos;

      s.setFocus('sess-A');
      s.sync([run('a1', session: 'sess-A'), run('b1', session: 'sess-B')]);
      d.advance(0.5);

      final hidden = s.beasts.firstWhere((b) => b.agentId == 'b1');
      expect(s.clearingOf('sess-B'), isNull); // 빈터가 없다 = 뷰가 안 그린다
      expect(hidden.pos, before); // 빈터가 없으니 _step 도 안 돈다(위치 보존)

      s.setFocus(null);
      s.sync([run('a1', session: 'sess-A'), run('b1', session: 'sess-B')]);
      expect(s.clearings.length, 2);
      expect(s.beasts.map((b) => b.agentId).toSet(), {'a1', 'b1'});
    });

    test('포커스한 세션이 끝나면 자동으로 전체 뷰로 돌아온다', () {
      final (s, d) = twoSessions();
      s.setFocus('sess-A');
      s.sync([run('a1', session: 'sess-A'), run('b1', session: 'sess-B')]);
      d.advance(0.1);
      expect(s.focus, 'sess-A');

      // A 가 통째로 빠졌다 — 축하·페이드까지 끝나 열이 접힐 때까지.
      s.sync([run('b1', session: 'sess-B')]);
      d.advance(celebrateFor + 1.0);
      s.sync([run('b1', session: 'sess-B')]);

      expect(s.focus, isNull); // 빈 화면을 들여다보게 두지 않는다
      expect(s.clearings.single.sessionId, 'sess-B');
    });

    test('포커스 중이어도 가려진 세션의 마리는 마저 퇴장한다 — 유령이 남지 않는다', () {
      final (s, d) = twoSessions();
      s.setFocus('sess-A');
      s.sync([run('a1', session: 'sess-A'), run('b1', session: 'sess-B')]);
      d.advance(0.1);

      s.sync([run('a1', session: 'sess-A')]); // B 의 마리가 끝남 — 지금 안 보이는 열이다
      d.advance(celebrateFor + 1.0);

      expect(s.beasts.map((b) => b.agentId), ['a1']); // 안 보이는 채로 사라졌다
    });
  });
}

/// tick 은 Ticker 의 누적 elapsed 를 받으므로 테스트가 절대 시각을 이어 준다.
/// 50ms 스텝 — [ForestScene] 의 dt 상한(0.05s)과 맞물려 1스텝 = 1적분이 된다.
class SceneDriver {
  final ForestScene scene;
  Duration _t = Duration.zero;
  SceneDriver(this.scene);

  void advance(double seconds) {
    final steps = (seconds / 0.05).ceil();
    for (var i = 0; i < steps; i++) {
      _t += const Duration(milliseconds: 50);
      scene.tick(_t);
    }
  }
}
