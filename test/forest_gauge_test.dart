import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar/domain/models/agent_run.dart';
import 'package:tokenbar/domain/models/context_gauge.dart';
import 'package:tokenbar/presentation/context_gauge_bar.dart';
import 'package:tokenbar/presentation/forest_scene_view.dart';

/// 숲의 사람(세션) 캐릭터에 컨텍스트 게이지가 sessionId 로 조인되는지.
///
/// 라이브 판정은 게이지가 하지 않는다 — 숲이 그리는 캐릭터에만 붙으므로, 죽은 세션의
/// 낡은 덤프는 그릴 자리가 없어 자연히 걸러져야 한다.
void main() {
  final t0 = DateTime.utc(2026, 7, 17);

  AgentRun run(String id, {required String session}) => AgentRun(
    agentId: id,
    agentType: 'workflow-subagent',
    project: '-Users-me-proj',
    sessionId: session,
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

  ContextGauge gauge(String session, {int used = 574000}) => ContextGauge(
    sessionId: session,
    usedTokens: used,
    windowSize: 1000000,
    pctOverride: 70,
    updatedAt: t0,
  );

  Future<void> pumpForest(
    WidgetTester tester, {
    required List<AgentRun> runs,
    required Map<String, ContextGauge> gauges,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: ForestSceneView(runs: runs, gauges: gauges),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('세션의 게이지가 그 세션 캐릭터에 붙는다', (tester) async {
    await pumpForest(
      tester,
      runs: [run('a1', session: 'sess-1')],
      gauges: {'sess-1': gauge('sess-1')},
    );
    expect(find.byType(ContextGaugeMiniBar), findsOneWidget);
    final bar = tester.widget<ContextGaugeMiniBar>(
      find.byType(ContextGaugeMiniBar),
    );
    expect(bar.gauge.remainingPercent, 18);
  });

  testWidgets('게이지가 없는 세션엔 바가 없다 — 훅 없이도 숲은 멀쩡하다', (tester) async {
    await pumpForest(
      tester,
      runs: [run('a1', session: 'sess-1')],
      gauges: const {},
    );
    expect(find.byType(ContextGaugeMiniBar), findsNothing);
  });

  testWidgets('죽은 세션의 낡은 덤프는 그릴 자리가 없어 걸러진다', (tester) async {
    await pumpForest(
      tester,
      runs: [run('a1', session: 'sess-1')],
      gauges: {
        'sess-1': gauge('sess-1'),
        'dead-session': gauge('dead-session'),
      },
    );
    // 도는 세션은 하나뿐 → 바도 하나뿐이어야 한다.
    expect(find.byType(ContextGaugeMiniBar), findsOneWidget);
  });

  testWidgets('세션이 둘이면 각자 제 게이지를 단다 — 섞이지 않는다', (tester) async {
    await pumpForest(
      tester,
      runs: [
        run('a1', session: 'sess-1'),
        run('b1', session: 'sess-2'),
      ],
      gauges: {
        'sess-1': gauge('sess-1', used: 574000), // → 18%
        'sess-2': gauge('sess-2', used: 70000), // → 90%
      },
    );
    final bars = tester
        .widgetList<ContextGaugeMiniBar>(find.byType(ContextGaugeMiniBar))
        .toList();
    expect(bars.length, 2);
    expect(bars.map((b) => b.gauge.sessionId).toSet(), {'sess-1', 'sess-2'});
    // 세션마다 제 숫자여야 한다(한쪽 값이 양쪽에 복사되면 실패).
    final bySession = {for (final b in bars) b.gauge.sessionId: b.gauge};
    expect(bySession['sess-1']!.remainingPercent, 18);
    expect(bySession['sess-2']!.remainingPercent, 90);
  });
}
