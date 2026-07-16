import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tokenbar/domain/models/agent_run.dart';
import 'package:tokenbar/presentation/agent_log_sheet.dart';

/// 시트는 열던 순간의 스냅샷을 고정해 버렸다 — 바깥 숲은 2초마다 갱신되는데 시트만 멈춰
/// 있어서, 도는 에이전트를 클릭해 놓고 봐도 새 도구가 안 올라왔다(사용자 지적).
///
/// 실제 경로(파일 → 아이솔레이트 → 타이머 → 위젯)를 그대로 태운다: [tester.runAsync] 안에선
/// 진짜 시간이 흘러 진짜 Timer 가 돈다. 가짜 시계로는 Isolate.run 이 안 끝난다.
void main() {
  late Directory tmp;
  late File file;

  String userLine(String prompt) => json.encode({
        'isSidechain': true,
        'agentId': 'aaa',
        'type': 'user',
        'timestamp': '2026-07-17T09:00:00.000Z',
        'sessionId': 'sess-1',
        'message': {'role': 'user', 'content': prompt},
      });

  String assistantLine(String toolName, String detail) => json.encode({
        'isSidechain': true,
        'agentId': 'aaa',
        'type': 'assistant',
        'timestamp': '2026-07-17T09:00:05.000Z',
        'sessionId': 'sess-1',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'name': toolName,
              'input': {'command': detail},
            },
          ],
        },
      });

  AgentRun run({required bool isRunning}) => AgentRun(
        agentId: 'aaa',
        agentType: 'delegate',
        project: '-Users-me-proj',
        sessionId: 'sess-1',
        filePath: file.path,
        workflowId: null,
        description: '지시',
        startedAt: DateTime.utc(2026, 7, 17, 9),
        endedAt: DateTime.utc(2026, 7, 17, 9, 0, 5),
        toolCalls: const [],
        inputTokens: 0,
        outputTokens: 0,
        isRunning: isRunning,
      );

  Widget sheet(AgentRun r) => MaterialApp(home: Scaffold(body: AgentLogSheet(run: r)));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('agent_log_sheet_test');
    file = File(p.join(tmp.path, 'agent-aaa.jsonl'));
    file.writeAsStringSync([userLine('지시'), assistantLine('Bash', 'ls')].join('\n'));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('도는 에이전트: 시트를 열어둔 채로 새 도구 호출이 올라온다', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(sheet(run(isRunning: true)));
      await Future.delayed(const Duration(milliseconds: 800)); // 첫 읽기(아이솔레이트)
      await tester.pump();
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('Read'), findsNothing); // 아직 안 한 일

      // 에이전트가 일을 더 했다 — 파일이 자란다(클로드 코드가 append 하는 그대로).
      file.writeAsStringSync('\n${assistantLine('Read', 'a.dart')}',
          mode: FileMode.append);

      await Future.delayed(const Duration(seconds: 3)); // 폴링 주기 경과
      await tester.pump();
      expect(find.text('Read'), findsOneWidget); // 닫았다 열지 않아도 보인다
      expect(find.text('Bash'), findsOneWidget); // 있던 것도 그대로
    });
  });

  testWidgets('끝난 에이전트: 폴링하지 않는다 — 파일이 변할 리 없다', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(sheet(run(isRunning: false)));
      await Future.delayed(const Duration(milliseconds: 800));
      await tester.pump();
      expect(find.text('Bash'), findsOneWidget);

      // 끝난 마리의 파일이 (있을 리 없지만) 바뀌어도 다시 읽지 않는다.
      file.writeAsStringSync('\n${assistantLine('Read', 'a.dart')}',
          mode: FileMode.append);
      await Future.delayed(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Read'), findsNothing);
    });
  });

  testWidgets('시트를 닫으면 폴링도 멈춘다 — dispose 후 setState 금지', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(sheet(run(isRunning: true)));
      await Future.delayed(const Duration(milliseconds: 800));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: SizedBox())); // 시트 dispose
      file.writeAsStringSync('\n${assistantLine('Read', 'a.dart')}',
          mode: FileMode.append);
      await Future.delayed(const Duration(seconds: 3));
      await tester.pump();
      // 살아 있는 타이머가 죽은 State 를 건드리면 여기서 예외로 터진다.
      expect(tester.takeException(), isNull);
    });
  });
}
