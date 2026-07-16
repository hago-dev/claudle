import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tokenbar/data/providers/claude_code/agent_run_reader.dart';
import 'package:tokenbar/data/providers/claude_code/claude_path_resolver.dart';
import 'package:tokenbar/domain/models/agent_run.dart';

/// 실측 구조(agent-*.jsonl 1줄 = 1 레코드)를 최소로 재현하는 픽스처 헬퍼.
String _userLine(String agentId, String prompt, String ts) => json.encode({
      'parentUuid': null,
      'isSidechain': true,
      'agentId': agentId,
      'type': 'user',
      'uuid': 'u1',
      'timestamp': ts,
      'sessionId': 'sess-1',
      'message': {'role': 'user', 'content': prompt},
    });

String _assistantLine(
  String agentId,
  List<(String, Map<String, Object?>)> tools,
  String ts, {
  int input = 0,
  int output = 0,
  String text = 'ok',
  List<String>? ids, // tool_use 의 id(실측 존재) — tool_result 매칭 테스트용
}) =>
    json.encode({
      'isSidechain': true,
      'agentId': agentId,
      'type': 'assistant',
      'uuid': 'a1',
      'timestamp': ts,
      'sessionId': 'sess-1',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': '...'},
          {'type': 'text', 'text': text},
          for (final (i, (name, args)) in tools.indexed)
            {
              'type': 'tool_use',
              if (ids != null) 'id': ids[i],
              'name': name,
              'input': args,
            },
        ],
        'usage': {
          'input_tokens': input,
          'output_tokens': output,
          'cache_read_input_tokens': 999, // 모델에 없는 필드 → 무시돼야 함
        },
      },
    });

/// 도구 결과 — `type:"user"` 줄의 content List 로 돌아온다(실측). `is_error:true` 가 실패 신호.
String _toolResultLine(String agentId, String toolUseId, String ts,
        {bool? isError}) =>
    json.encode({
      'isSidechain': true,
      'agentId': agentId,
      'type': 'user',
      'uuid': 'r1',
      'timestamp': ts,
      'sessionId': 'sess-1',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': toolUseId,
            'is_error': ?isError,
            'content': 'boom',
          },
        ],
      },
    });

/// 워크플로우 팬아웃 실측 구조 — 프롬프트 앞부분(실측 1869자)이 통째로 공유된다.
const _shared = '저장소: /Users/me/proj (NestJS 11 + Drizzle).\n'
    '변경 내용을 보려면: `git diff`.\n\n## 리뷰 지적 (카테고리: ';

/// 메인 세션 파일(`projects/<proj>/<sessionId>.jsonl`) 의 사람 입력 — 서브와 달리
/// `isSidechain`·`agentId` 가 없고 경로에 `subagents/` 도 없다(실측).
String _mainUserLine(String prompt, String ts) => json.encode({
      'parentUuid': null,
      'type': 'user',
      'uuid': 'u1',
      'timestamp': ts,
      'sessionId': 'main-1',
      'message': {'role': 'user', 'content': prompt},
    });

/// 메인 세션만 갖는 레코드 — 클로드 코드가 세션 제목을 계속 갱신한다(실측 81건/파일).
/// `message` 키가 아예 없어서 **마지막 것이 최신 제목**이다.
String _aiTitleLine(String title) =>
    json.encode({'type': 'ai-title', 'aiTitle': title, 'sessionId': 'main-1'});

/// 사람이 친 원문 — 메인 세션에 파일 전체로 흩어져 있고 **마지막 것이 가장 최근** 지시다.
String _lastPromptLine(String prompt) =>
    json.encode({'type': 'last-prompt', 'lastPrompt': prompt, 'sessionId': 'main-1'});

void main() {
  late Directory tmp;
  late String subagents;
  late String projectDir;

  void write(String path, String content) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('agent_run_reader_test');
    projectDir = p.join(tmp.path, 'projects', '-Users-me-proj');
    final session = p.join(projectDir, 'sess-1');
    subagents = p.join(session, 'subagents');

    // 일반 서브에이전트(meta 있음).
    write(p.join(subagents, 'agent-aaa.jsonl'), [
      _userLine('aaa', 'a' * 150, '2026-07-02T06:56:55.666Z'),
      _assistantLine(
        'aaa',
        [
          ('Bash', {'command': 'find /Users/me/proj -name "*Goods*"'}),
          ('Read', {'file_path': '/Users/me/proj/lib/single/create.dart'}),
        ],
        '2026-07-02T06:57:10.000Z',
        input: 100,
        output: 20,
      ),
      _assistantLine('aaa', [
        ('Bash', {'command': 'ls'}),
      ], '2026-07-02T06:59:02.413Z', input: 5, output: 3),
    ].join('\n'));
    write(p.join(subagents, 'agent-aaa.meta.json'),
        '{"agentType":"delegate","spawnDepth":1}');

    // 워크플로우 서브에이전트(중첩 경로).
    final wf = p.join(subagents, 'workflows', 'wf_1752_abc');
    write(p.join(wf, 'agent-bbb.jsonl'),
        _userLine('bbb', '워크플로우 지시', '2026-07-02T07:00:00.000Z'));
    write(p.join(wf, 'agent-bbb.meta.json'),
        '{"agentType":"workflow-subagent"}');

    // meta.json 없음 → 'unknown' 폴백.
    write(p.join(subagents, 'agent-ccc.jsonl'),
        _userLine('ccc', 'meta 없는 에이전트', '2026-07-02T07:01:00.000Z'));

    // 일반 세션 JSONL(에이전트 아님) → 무시돼야 함.
    write(p.join(session, '..', 'sess-1.jsonl'),
        json.encode({'type': 'assistant', 'message': {'usage': {}}}));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  AgentRunReader reader({DateTime? now}) => AgentRunReader(
        resolver: ClaudePathResolver(env: {'CLAUDE_CONFIG_DIR': tmp.path}),
        now: () => now ?? DateTime.utc(2026, 7, 3),
      );

  AgentRun byId(List<AgentRun> runs, String id) =>
      runs.firstWhere((r) => r.agentId == id);

  /// 메인 세션 파일을 깐다 — 서브와 달리 `subagents/` 밖, 프로젝트 디렉토리 바로 아래.
  /// 방금 쓰이므로 mtime 은 지금(readLive 의 90초 창 안).
  void writeMain(String sessionId, List<String> lines) =>
      write(p.join(projectDir, '$sessionId.jsonl'), lines.join('\n'));

  /// 워크플로우 하나에 프롬프트가 [prompts] 인 에이전트들을 깔고, 설명만 뽑는다.
  List<String> fanOut(String workflowId, List<String> prompts,
      {Map<int, String> metaDescriptions = const {}}) {
    final dir = p.join(subagents, 'workflows', workflowId);
    for (var i = 0; i < prompts.length; i++) {
      write(p.join(dir, 'agent-$workflowId$i.jsonl'),
          _userLine('$workflowId$i', prompts[i], '2026-07-02T09:0$i:00.000Z'));
      write(
        p.join(dir, 'agent-$workflowId$i.meta.json'),
        json.encode({
          'agentType': 'workflow-subagent',
          'description': ?metaDescriptions[i],
        }),
      );
    }
    final runs = reader()
        .readAll()
        .where((r) => r.workflowId == workflowId)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return runs.map((r) => r.description).toList();
  }

  test('agent-*.jsonl 만 읽고 일반 세션 파일은 무시한다', () {
    final runs = reader().readAll();
    expect(runs.map((r) => r.agentId).toSet(), {'aaa', 'bbb', 'ccc'});
  });

  test('일반 서브에이전트: 경로·meta·프롬프트·도구·토큰·시각 파싱', () {
    final r = byId(reader().readAll(), 'aaa');
    expect(r.agentType, 'delegate');
    expect(r.project, '-Users-me-proj');
    expect(r.sessionId, 'sess-1');
    expect(r.workflowId, isNull);
    expect(r.filePath, endsWith('agent-aaa.jsonl'));
    expect(r.description, 'a' * 100); // 첫 프롬프트 앞 100자
    expect(r.toolCalls.map((t) => t.name), ['Bash', 'Read', 'Bash']); // 순서 유지
    expect(r.inputTokens, 105);
    expect(r.outputTokens, 23);
    expect(r.startedAt, DateTime.utc(2026, 7, 2, 6, 56, 55, 666));
    expect(r.endedAt, DateTime.utc(2026, 7, 2, 6, 59, 2, 413));
    expect(r.isRunning, isFalse);
  });

  test('도구 호출은 이름만이 아니라 무엇을 만졌는지(input)까지 담는다', () {
    final r = byId(reader().readAll(), 'aaa');
    expect(r.toolCalls[0].detail, 'find /Users/me/proj -name "*Goods*"');
    expect(r.toolCalls[1].detail, 'single/create.dart'); // 경로는 마지막 2 세그먼트
    expect(r.toolCalls[2].detail, 'ls');
  });

  test('도구 인자: file_path > command > pattern > description > url 순, 없으면 빈 값', () {
    write(p.join(subagents, 'agent-eee.jsonl'), [
      _userLine('eee', '지시', '2026-07-02T10:00:00.000Z'),
      _assistantLine('eee', [
        ('Grep', {'pattern': 'SessionAuthGuard', 'output_mode': 'files'}),
        ('WebFetch', {'url': 'https://example.com/docs'}),
        ('Task', {'description': '탐색', 'subagent_type': 'Explore'}),
        ('Read', {'file_path': '/a/b/c/d.dart', 'command': '무시돼야 함'}),
        ('TodoWrite', {'todos': []}), // 뽑을 인자 없음
        ('Bash', {'command': 'echo hi\n  && ls -al'}), // 여러 줄 → 한 줄로
      ], '2026-07-02T10:00:05.000Z'),
    ].join('\n'));
    final tools = byId(reader().readAll(), 'eee').toolCalls;
    expect(tools.map((t) => t.detail), [
      'SessionAuthGuard',
      'https://example.com/docs',
      '탐색',
      'c/d.dart',
      '',
      'echo hi && ls -al',
    ]);
  });

  test('tool_result 의 is_error 가 해당 ToolCall 에 isError 로 붙는다', () {
    write(p.join(subagents, 'agent-err.jsonl'), [
      _userLine('err', '에러 나는 작업', '2026-07-02T08:00:00.000Z'),
      _assistantLine(
        'err',
        [
          ('Bash', {'command': 'exit 1'}),
          ('Read', {'file_path': '/a.dart'}),
        ],
        '2026-07-02T08:00:10.000Z',
        ids: ['toolu_1', 'toolu_2'],
      ),
      _toolResultLine('err', 'toolu_1', '2026-07-02T08:00:11.000Z',
          isError: true),
      _toolResultLine('err', 'toolu_2', '2026-07-02T08:00:12.000Z',
          isError: false),
    ].join('\n'));

    final tools = byId(reader().readAll(), 'err').toolCalls;
    expect(tools.length, 2); // tool_result 줄이 새 ToolCall 을 만들면 안 된다
    expect(tools[0].name, 'Bash');
    expect(tools[0].isError, isTrue);
    expect(tools[1].isError, isFalse);
  });

  test('is_error 필드 없음·무매칭 tool_use_id 는 전부 무해하다', () {
    write(p.join(subagents, 'agent-hhh.jsonl'), [
      _userLine('hhh', '평범한 작업', '2026-07-02T08:10:00.000Z'),
      _assistantLine('hhh', [
        ('Bash', {'command': 'ls'}),
      ], '2026-07-02T08:10:05.000Z', ids: ['toolu_9']),
      _toolResultLine('hhh', 'toolu_9', '2026-07-02T08:10:06.000Z'), // 필드 없음
      _toolResultLine('hhh', 'toolu_ghost', '2026-07-02T08:10:07.000Z',
          isError: true), // 무매칭 — 조용히 무시
    ].join('\n'));

    final tools = byId(reader().readAll(), 'hhh').toolCalls;
    expect(tools.single.isError, isFalse);
  });

  test('워크플로우 서브에이전트: workflowId 추출', () {
    final r = byId(reader().readAll(), 'bbb');
    expect(r.workflowId, 'wf_1752_abc');
    expect(r.agentType, 'workflow-subagent');
    expect(r.sessionId, 'sess-1');
    expect(r.description, '워크플로우 지시');
  });

  test('meta.json 없으면 agentType 은 unknown (크래시 금지)', () {
    final r = byId(reader().readAll(), 'ccc');
    expect(r.agentType, 'unknown');
    expect(r.toolCalls, isEmpty);
    expect(r.inputTokens, 0);
  });

  test('isRunning: 마지막 타임스탬프가 60초 이내면 true', () {
    final justAfter =
        DateTime.utc(2026, 7, 2, 6, 59, 2, 413).add(const Duration(seconds: 30));
    expect(byId(reader(now: justAfter).readAll(), 'aaa').isRunning, isTrue);

    final wellAfter =
        DateTime.utc(2026, 7, 2, 6, 59, 2, 413).add(const Duration(seconds: 90));
    expect(byId(reader(now: wellAfter).readAll(), 'aaa').isRunning, isFalse);
  });

  test('깨진 라인은 건너뛰고 나머지를 살린다', () {
    write(p.join(subagents, 'agent-ddd.jsonl'), [
      _userLine('ddd', '정상 프롬프트', '2026-07-02T08:00:00.000Z'),
      '{"type":"assistant", 부분적으로 깨진',
      _assistantLine('ddd', [
        ('Grep', {'pattern': 'x'}),
      ], '2026-07-02T08:00:05.000Z', output: 7),
    ].join('\n'));
    final r = byId(reader().readAll(), 'ddd');
    expect(r.description, '정상 프롬프트');
    expect(r.toolCalls.single.name, 'Grep');
    expect(r.outputTokens, 7);
  });

  // ── 설명 중복 (사용자 신고: "설명이 전부 똑같아 구분이 안 된다") ──

  test('팬아웃: 공유 접두사를 걷어내 서로 다른 부분부터 보여준다', () {
    final descriptions = fanOut('wffan', [
      '$_shared auth-bypass)\n제목: 헤더 신원을 그대로 신뢰한다',
      '$_shared session-lifecycle)\n제목: logout 쿠키 domain 누락',
      '$_shared deletion)\n제목: 삭제된 계약에 묶여 7/8 실패',
    ]);
    expect(descriptions.toSet(), hasLength(3)); // 전부 달라야 한다
    expect(descriptions[0], startsWith('auth-bypass)'));
    expect(descriptions[1], startsWith('session-lifecycle)'));
    expect(descriptions[2], startsWith('deletion)'));
    // 공유분(앞 100자를 죄다 잡아먹던 부분)은 사라진다.
    expect(descriptions.every((d) => !d.contains('저장소:')), isTrue);
  });

  test('팬아웃: 접두사를 단어 중간에서 자르지 않는다', () {
    final descriptions = fanOut('wfword', [
      '$_shared auth-bypass)\n제목: 첫째',
      '$_shared auth-zzz)\n제목: 둘째',
    ]);
    // 공통분은 'auth-' 까지지만 되감아서 단어 통째로 보여준다("bypass)…" 가 아니라).
    expect(descriptions[0], startsWith('auth-bypass)'));
    expect(descriptions[1], startsWith('auth-zzz)'));
  });

  test('meta.json 의 description 이 있으면 프롬프트보다 우선', () {
    final descriptions = fanOut(
      'wfmeta',
      ['$_shared auth-bypass)\n제목: 첫째', '$_shared deletion)\n제목: 둘째'],
      metaDescriptions: {0: 'Explore existing integrations and secrets'},
    );
    expect(descriptions[0], 'Explore existing integrations and secrets');
    expect(descriptions[1], startsWith('deletion)')); // 라벨 없는 쪽은 프롬프트에서
  });

  test('프롬프트가 아예 같으면 최후로 인덱스를 붙여 구분한다', () {
    final descriptions = fanOut('wfsame', ['$_shared 같은 지시', '$_shared 같은 지시']);
    expect(descriptions.toSet(), hasLength(2));
    expect(descriptions[0], endsWith(' (1/2)'));
    expect(descriptions[1], endsWith(' (2/2)'));
    expect(descriptions[0], contains('같은 지시')); // 내용은 남는다
  });

  test('설명은 한 줄로 접힌다(개행·연속 공백 제거)', () {
    write(p.join(subagents, 'agent-fff.jsonl'),
        _userLine('fff', '\n\n첫 줄\n\n  둘째 줄  ', '2026-07-02T11:00:00.000Z'));
    expect(byId(reader().readAll(), 'fff').description, '첫 줄 둘째 줄');
  });

  // ── 상세 로그(lazy) ──

  test('readSteps: 첫 지시 프롬프트를 맨 앞에 전문으로, 이어서 도구·글을 순서대로', () {
    final r = byId(reader().readAll(), 'aaa');
    final steps = reader().readSteps(r.filePath);
    // 맨 앞은 사람이 준 지시 전문 — 클립 없이(카드 설명은 100자로 잘려도 상세는 통째로).
    expect(steps.first.isPrompt, isTrue);
    expect(steps.first.text, 'a' * 150);
    expect(steps.skip(1).map((s) => s.tool?.name ?? '텍스트:${s.text}'), [
      '텍스트:ok',
      'Bash',
      'Read',
      '텍스트:ok',
      'Bash',
    ]);
    expect(steps.firstWhere((s) => s.tool?.name == 'Read').tool!.detail,
        'single/create.dart');
  });

  test('readSteps: 빈 텍스트 블록은 버린다', () {
    write(p.join(subagents, 'agent-ggg.jsonl'), [
      _userLine('ggg', '지시', '2026-07-02T12:00:00.000Z'),
      _assistantLine('ggg', [
        ('Read', {'file_path': '/x/y.dart'}),
      ], '2026-07-02T12:00:01.000Z', text: '   '),
    ].join('\n'));
    final r = byId(reader().readAll(), 'ggg');
    final tools =
        reader().readSteps(r.filePath).where((s) => s.tool != null);
    expect(tools.map((s) => s.tool!.name), ['Read']);
  });

  // ── 라이브 폴링(readLive): 파일 mtime 이 최근인 것만 ──

  test('readLive: mtime 이 오래된 파일은 건너뛰고 방금 쓰인 것만 읽는다', () {
    final now = DateTime.now().toUtc();
    // 방금 쓰인 파일(= 도는 중). write() 는 mtime 을 실제 지금으로 남긴다.
    write(p.join(subagents, 'agent-fresh.jsonl'),
        _userLine('fresh', '지금 도는 중', now.toIso8601String()));
    write(p.join(subagents, 'agent-fresh.meta.json'), '{"agentType":"delegate"}');
    // 오래 전 파일(= 안 도는 것): mtime 을 10분 전으로 되돌린다.
    final stalePath = p.join(subagents, 'agent-stale.jsonl');
    write(stalePath, _userLine('stale', '오래 전', now.toIso8601String()));
    write(p.join(subagents, 'agent-stale.meta.json'), '{"agentType":"delegate"}');
    File(stalePath).setLastModifiedSync(now.subtract(const Duration(minutes: 10)));

    final ids =
        reader(now: now).readLive().map((r) => r.agentId).toSet();
    expect(ids, contains('fresh'));
    expect(ids, isNot(contains('stale'))); // mtime 창(90초) 밖 → 파싱 생략
  });

  test('readLive: 판정 창(90초) 경계 안쪽은 포함, 바깥은 제외', () {
    final now = DateTime.now().toUtc();
    void put(String id, Duration ago) {
      final path = p.join(subagents, 'agent-$id.jsonl');
      write(path, _userLine(id, id, now.toIso8601String()));
      write(p.join(subagents, 'agent-$id.meta.json'), '{"agentType":"delegate"}');
      File(path).setLastModifiedSync(now.subtract(ago));
    }

    put('inside', const Duration(seconds: 30)); // 창 안
    put('outside', const Duration(seconds: 120)); // 창 밖

    final ids = reader(now: now).readLive().map((r) => r.agentId).toSet();
    expect(ids, contains('inside'));
    expect(ids, isNot(contains('outside')));
  });

  // ── 메인 세션 (사용자 요구: "ai 가 돌아가는게 무조건 보여야해") ──
  //
  // 서브 없이 프롬프트만 돌면 = 메인만 일하면 라이브 씬이 텅 빈다 → readLive 가 메인 세션도
  // 반환해야 사람이 캠프에 선다. 서브와 섞이므로 agentType 으로 구분된다.

  test('readLive: 메인 세션(subagents 아닌 경로)을 agentType main 으로 읽는다', () {
    final now = DateTime.now().toUtc();
    writeMain('main-1', [
      _mainUserLine('프롬프트만 돌린다', now.toIso8601String()),
      _aiTitleLine('오래된 제목'),
      _assistantLine('main-1', [
        ('Read', {'file_path': '/a/b/c.dart'}),
      ], now.toIso8601String(), input: 11, output: 22),
      _aiTitleLine('에이전트 시각화 및 작업 흐름 표시'),
    ]);

    final r = byId(reader(now: now).readLive(), 'main-1');
    expect(r.agentType, mainAgentType); // 동물 해시를 타면 안 된다 — 사람으로만 그린다
    expect(r.sessionId, 'main-1'); // agentId = sessionId
    expect(r.workflowId, isNull);
    expect(r.project, '-Users-me-proj');
    expect(r.description, '에이전트 시각화 및 작업 흐름 표시'); // 마지막 ai-title = 최신
    // 토큰·도구·시각·isRunning 은 서브와 같은 규약.
    expect(r.toolCalls.single.detail, 'b/c.dart');
    expect(r.inputTokens, 11);
    expect(r.outputTokens, 22);
    expect(r.isRunning, isTrue);
  });

  test('readLive: ai-title 이 없는 세션은 사람의 첫 프롬프트로 폴백', () {
    final now = DateTime.now().toUtc();
    writeMain('main-2', [_mainUserLine('b' * 150, now.toIso8601String())]);
    expect(byId(reader(now: now).readLive(), 'main-2').description, 'b' * 100);
  });

  test('readLive: ai-title 이 없으면 last-prompt 가 첫 user 줄보다 우선 — 슬래시 명령은 '
      '첫 user 줄이 사람 글이 아니라 <command-*> 확장이다(실측 88/142 세션)', () {
    final now = DateTime.now().toUtc();
    writeMain('main-cmd', [
      _mainUserLine(
          '<command-message>memory-consolidate</command-message>'
          '<command-name>/memory-consolidate</command-name>',
          now.toIso8601String()),
      json.encode({
        'type': 'last-prompt',
        'lastPrompt': '/memory-consolidate shimkijun --apply',
        'sessionId': 'main-cmd',
      }),
    ]);
    expect(byId(reader(now: now).readLive(), 'main-cmd').description,
        '/memory-consolidate shimkijun --apply');
  });

  test('readLive: ai-title 도 사람 프롬프트도 없으면 설명은 빈 값', () {
    final now = DateTime.now().toUtc();
    writeMain('main-3', [_assistantLine('main-3', [], now.toIso8601String())]);
    expect(byId(reader(now: now).readLive(), 'main-3').description, isEmpty);
  });

  test('readLive: 메인 세션도 mtime 창(90초) 밖이면 건너뛴다', () {
    final now = DateTime.now().toUtc();
    final path = p.join(projectDir, 'main-old.jsonl');
    write(path, _mainUserLine('오래 전', now.toIso8601String()));
    File(path).setLastModifiedSync(now.subtract(const Duration(minutes: 10)));
    expect(reader(now: now).readLive().map((r) => r.agentId),
        isNot(contains('main-old')));
  });

  test('readAll 에는 메인 세션이 안 들어간다 — 기록 그룹은 서브(마리) 단위다', () {
    writeMain('main-4', [
      _mainUserLine('지시', '2026-07-02T06:00:00.000Z'),
      _aiTitleLine('제목'),
    ]);
    expect(reader().readAll().map((r) => r.agentId).toSet(), {'aaa', 'bbb', 'ccc'});
  });

  // ── 메인 세션 상세 로그 (사용자 요구: "세션 클릭 시 그 세션이 뭘 하는지") ──
  //
  // 서브 상세([readSteps])와 두 가지가 다르다: ① "받은 지시" 는 첫 user 줄(몇 시간 전)이
  // 아니라 최신 last-prompt(사람이 방금 친 것) ② 활동은 최근순 — 세션 파일은 수천 줄이라
  // 시작부터 정순으로 두면 "지금 하는 일" 이 맨 아래 파묻힌다.

  test('readMainSteps: 맨 앞은 최신 last-prompt, 이어서 활동을 최근순으로', () {
    writeMain('main-log', [
      _mainUserLine('세션 시작 때 친 첫 말', '2026-07-02T06:00:00.000Z'),
      _lastPromptLine('예전 지시'),
      _assistantLine('main-log', [
        ('Read', {'file_path': '/a/old.dart'}),
      ], '2026-07-02T06:00:10.000Z'),
      _lastPromptLine('세션 클릭 시 하는 일을 보여줘'), // 마지막 = 지금 시킨 일
      _assistantLine('main-log', [
        ('Grep', {'pattern': '_PersonStand'}),
        ('Edit', {'file_path': '/a/new.dart'}),
      ], '2026-07-02T06:00:20.000Z'),
    ]);
    final steps = reader().readMainSteps(p.join(projectDir, 'main-log.jsonl'));

    // ① 맨 앞 = 최신 last-prompt 전문(첫 user 줄이 아니라).
    expect(steps.first.isPrompt, isTrue);
    expect(steps.first.text, '세션 클릭 시 하는 일을 보여줘');

    // ② 이어지는 활동은 최근순 — 마지막 assistant 의 블록이 먼저.
    final activity = steps.skip(1).map((s) => s.tool?.name ?? '텍스트:${s.text}');
    expect(activity, ['Edit', 'Grep', '텍스트:ok', 'Read', '텍스트:ok']);
  });

  test('readMainSteps: last-prompt 이 없으면 첫 user 줄을 지시로 폴백', () {
    writeMain('main-noprompt', [
      _mainUserLine('첫 user 줄이 곧 지시', '2026-07-02T06:00:00.000Z'),
      _assistantLine('main-noprompt', [
        ('Read', {'file_path': '/a/b.dart'}),
      ], '2026-07-02T06:00:05.000Z'),
    ]);
    final steps =
        reader().readMainSteps(p.join(projectDir, 'main-noprompt.jsonl'));
    expect(steps.first.isPrompt, isTrue);
    expect(steps.first.text, '첫 user 줄이 곧 지시');
  });

  // ── 그룹 제목 (사용자 요구: "워크플로우 ID 대신 사람이 읽는 타이틀") ──

  test('readTitles: 워크플로우는 workflowName, 세션은 최신 ai-title', () {
    // 워크플로우 JSON 은 subagents/ 가 아니라 세션 디렉토리 바로 밑에 있다(실측).
    write(p.join(projectDir, 'sess-1', 'workflows', 'wf_1752_abc.json'),
        json.encode({'workflowName': 'adversarial-verify-checks', 'agentCount': 6}));
    writeMain('sess-1', [
      _mainUserLine('지시', '2026-07-02T06:00:00.000Z'),
      _aiTitleLine('오래된 제목'),
      _aiTitleLine('최신 제목'),
    ]);

    final titles = reader().readTitles(reader().readAll());
    expect(titles['wf_1752_abc'], 'adversarial-verify-checks');
    expect(titles['sess-1'], '최신 제목');
  });

  test('readTitles: 제목 파일이 없거나 ai-title 이 없으면 키가 없다(호출부가 ID 폴백)', () {
    // setUp 의 sess-1.jsonl 은 ai-title 이 없고, wf_1752_abc.json 도 안 깔았다.
    expect(reader().readTitles(reader().readAll()), isEmpty);
  });
}
