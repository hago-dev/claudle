import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tokenbar/domain/models/agent_run.dart';
import 'package:tokenbar/presentation/agents_screen.dart';

/// 회귀: 기록 탭 첫 진입에서 "읽기 실패: Illegal argument in isolate message:
/// object is unsendable - _AsyncCompleter" 크래시(실기기).
///
/// 원인: Dart 는 같은 스코프의 클로저들이 캡처 Context 를 공유한다 — `_load` 안에서
/// `Isolate.run(() => _readTitles(reps))` 를 만들면 이웃 setState 클로저가 캡처한
/// State(unsendable)까지 스폰 메시지에 끌려간다. 그래서 스폰 클로저는 톱레벨의
/// 깨끗한 스코프([titlesInIsolate])에서만 만든다.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('agents_isolate_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('titlesInIsolate: unsendable 을 쥔 호출부 스코프에서도 스폰되고, '
      'AgentRun 이 왕복해 제목이 돌아온다', () async {
    // _load 의 State 격 — 이 스코프의 형제 클로저가 캡처하는 unsendable.
    final port = ReceivePort();
    addTearDown(port.close);
    void sibling() => port.sendPort; // 호출부 Context 에 unsendable 을 심는다

    // 실측 구조: <sessionDir>/subagents/workflows/<wf>/agent-*.jsonl 이 대표,
    // 제목은 <sessionDir>/workflows/<wf>.json 의 workflowName.
    final sessionDir = p.join(tmp.path, 'projects', '-proj', 'sess-1');
    final agentPath =
        p.join(sessionDir, 'subagents', 'workflows', 'wf_1', 'agent-a1.jsonl');
    File(p.join(sessionDir, 'workflows', 'wf_1.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(json.encode({'workflowName': '리뷰 5축 팬아웃'}));

    final rep = AgentRun(
      agentId: 'a1',
      agentType: 'workflow-subagent',
      project: '-proj',
      sessionId: 'sess-1',
      filePath: agentPath,
      workflowId: 'wf_1',
      description: '',
      startedAt: DateTime.utc(2026, 7, 16),
      endedAt: DateTime.utc(2026, 7, 16, 0, 1),
      toolCalls: const [ToolCall('Read', 'x/y.dart')],
      inputTokens: 1,
      outputTokens: 2,
      isRunning: false,
    );

    final titles = await titlesInIsolate([rep]);
    expect(titles, {'wf_1': '리뷰 5축 팬아웃'});
    sibling();
  });
}
