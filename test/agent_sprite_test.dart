import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar/domain/models/agent_run.dart';
import 'package:tokenbar/presentation/agents_screen.dart';

/// 사용자 요구: "동물들 랜덤으로 — 등장할 때마다 종이 다시 섞여야 한다".
///
/// 배정이 둘로 갈린다:
///  - **라이브** = [randomAnimalSprite] — 씬에 등장하는 순간 진짜 랜덤으로 뽑는다(매번 새 얼굴).
///    화면에 있는 동안엔 유지 — 스프라이트는 _Beast 에 1회 저장이라 폴링마다 안 바뀐다.
///  - **기록** = [agentSprite] — 개체(agentId) 해시. 재생을 다시 열어도 카드와 시트가
///    같은 동물을 가리켜야 해서(어긋나면 클릭한 펭귄의 시트에 개가 뜬다) 결정론을 유지한다.
void main() {
  final t0 = DateTime.utc(2026, 7, 16);

  AgentRun run(String id, {String type = 'workflow-subagent'}) => AgentRun(
        agentId: id,
        agentType: type,
        project: '-Users-me-proj',
        sessionId: 'sess-1',
        filePath: '/tmp/agent-$id.jsonl',
        workflowId: null,
        description: '',
        startedAt: t0,
        endedAt: t0,
        toolCalls: const [],
        inputTokens: 0,
        outputTokens: 0,
        isRunning: true,
      );

  test('같은 타입 팬아웃이 한 종으로 몰리지 않는다 — 종은 타입이 아니라 개체로', () {
    // 예전(타입 고정 배정)엔 workflow-subagent 12마리 = 벌 12마리(1종)였다.
    final sprites = {for (var i = 0; i < 12; i++) agentSprite(run('wf-agent-$i'))};
    expect(sprites.length, greaterThan(3));
  });

  test('같은 마리는 늘 같은 동물 — 폴링·재생·시트가 서로 어긋나지 않는다', () {
    expect(agentSprite(run('e33ab120')), agentSprite(run('e33ab120')));
  });

  test('스프라이트는 declared asset 규약(animal-<종>)을 따른다', () {
    expect(agentSprite(run('any-id')), startsWith('animal-'));
  });

  test('라이브 등장은 매번 다시 섞인다 — 연속 등장이 여러 종으로 퍼진다', () {
    final rnd = math.Random(42);
    final sprites = List.generate(50, (_) => randomAnimalSprite(rnd));
    expect(sprites.toSet().length, greaterThan(5)); // 한두 종에 안 몰린다
    expect(sprites.every((s) => s.startsWith('animal-')), isTrue); // 풀 규약 유지
  });

  test('랜덤 소스는 호출자가 준다 — 같은 시드는 같은 시퀀스(씬의 _rnd 가 섞임의 주인)', () {
    final a = List.generate(10, (_) => randomAnimalSprite(math.Random(7)));
    final b = List.generate(10, (_) => randomAnimalSprite(math.Random(7)));
    expect(a, b); // 함수 안에 숨은 Random 이 없다
  });

  test('라이브 색도 등장마다 섞인다 — 같은 타입끼리도 색이 갈린다(사용자: 여러 가지 색)', () {
    final rnd = math.Random(42);
    final colors = List.generate(50, (_) => randomAgentColor(rnd));
    expect(colors.toSet().length, greaterThan(5)); // 한두 색에 안 몰린다
  });

  test('색 랜덤도 소스는 호출자가 준다 — 같은 시드는 같은 시퀀스', () {
    final a = List.generate(10, (_) => randomAgentColor(math.Random(7)));
    final b = List.generate(10, (_) => randomAgentColor(math.Random(7)));
    expect(a, b);
  });
}
