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

  /// 메인 세션 줄 — 서브와 달리 `isSidechain`·`agentId` 가 없다(실측).
  String mainAssistantLine(String toolName) => json.encode({
        'type': 'assistant',
        'timestamp': '2026-07-17T09:00:05.000Z',
        'sessionId': 'main-1',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'name': toolName,
              'input': {'command': 'x'},
            },
          ],
        },
      });

  String lastPromptLine(String prompt) =>
      json.encode({'type': 'last-prompt', 'lastPrompt': prompt, 'sessionId': 'main-1'});

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

  /// [live] = 메인 세션(사람 클릭) 경로 — 상세를 readMainSteps(최근순)로 읽는다.
  Widget sheet(AgentRun r, {bool live = false}) =>
      MaterialApp(home: Scaffold(body: AgentLogSheet(run: r, live: live)));

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

  /// 지금 스크롤이 어디 있나 — ListView.controller 는 위젯의 공개 필드다.
  ScrollController scrollOf(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;

  group('스크롤은 새 내용이 붙는 쪽을 향한다', () {
    // 두 경로의 정렬이 정반대다(리더): 서브 readSteps 는 정순이라 새 도구가 **아래**,
    // 메인 readMainSteps 는 activity.reversed 라 새 도구가 **위**(지금 하는 일을 맨 위에
    // 보여주려는 의도). 따라가는 쪽도 그에 맞춰 갈려야 한다.

    testWidgets('메인 세션(live): 새 내용이 위라 위를 본다', (tester) async {
      // 한 화면을 넘겨야 스크롤이 생긴다.
      file.writeAsStringSync([
        lastPromptLine('지금 시킨 일'),
        for (var i = 0; i < 40; i++) mainAssistantLine('Tool$i'),
      ].join('\n'));

      await tester.runAsync(() async {
        await tester.pumpWidget(sheet(run(isRunning: true), live: true));
        await Future.delayed(const Duration(milliseconds: 800));
        await tester.pump();

        final s = scrollOf(tester);
        expect(s.position.maxScrollExtent, greaterThan(0), reason: '스크롤이 생길 만큼 길어야 한다');
        expect(s.offset, 0, reason: '메인은 최근순 — 새 활동이 맨 위다. 바닥으로 밀면 정반대다');
      });
    });

    testWidgets('서브에이전트: 새 내용이 아래라 아래를 본다', (tester) async {
      file.writeAsStringSync([
        userLine('지시'),
        for (var i = 0; i < 40; i++) assistantLine('Tool$i', 'x'),
      ].join('\n'));

      await tester.runAsync(() async {
        await tester.pumpWidget(sheet(run(isRunning: true)));
        await Future.delayed(const Duration(milliseconds: 800));
        await tester.pump();

        final s = scrollOf(tester);
        expect(s.position.maxScrollExtent, greaterThan(0));
        expect(s.offset, s.position.maxScrollExtent,
            reason: '서브는 정순 — 새 도구가 맨 아래다');
      });
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
