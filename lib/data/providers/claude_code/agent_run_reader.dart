import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../domain/models/agent_run.dart';
import 'claude_path_resolver.dart';

/// `subagents/**/agent-*.jsonl` → [AgentRun]. 읽기 전용, DB 미경유.
///
/// 규약(실측 대조):
///  - 경로 = `projects/<project>/<sessionId>/subagents/[workflows/<workflowId>/]agent-<agentId>.jsonl`.
///  - 타입 정본은 옆의 `agent-<agentId>.meta.json` 의 `agentType`(줄의 `slug` 는 일부에만 있어 안 씀).
///  - 첫 줄(`type:"user"`)의 `message.content` = 받은 작업 지시.
///  - `type:"assistant"` 줄의 `content[]` 중 `tool_use` = 도구 호출(+`input` 에 무엇을 만졌는지),
///    `text` = 에이전트가 쓴 글, `message.usage` = 토큰.
///
/// 메인 세션(`projects/<project>/<sessionId>.jsonl` — 경로에 `subagents/` 가 없고 옆에
/// `.meta.json` 도 없다)도 같은 레코드 규약이라 [readLive] 가 함께 읽는다([_readMain]).
/// 다른 점은 타입([mainAgentType] 고정)·설명(최신 `ai-title`)뿐.
class AgentRunReader {
  /// 마지막 레코드가 이 안쪽이면 아직 실행 중으로 본다.
  static const Duration _runningWindow = Duration(seconds: 60);

  /// 설명 길이 — 카드에서 두 줄로 접히는 정도.
  static const int _descriptionMax = 100;

  /// 도구 인자 길이 — 카드 한 줄. 넘치면 화면에서 다시 말줄임된다.
  static const int _detailMax = 120;

  final ClaudePathResolver resolver;
  final DateTime Function() _now;

  AgentRunReader({ClaudePathResolver? resolver, DateTime Function()? now})
      : resolver = resolver ?? ClaudePathResolver(),
        _now = now ?? DateTime.now;

  /// 모든 claude 루트의 서브에이전트 실행. 파싱 불가한 파일은 건너뛴다.
  ///
  /// 설명은 파일을 다 읽은 뒤에 확정한다 — 워크플로우 팬아웃은 프롬프트 앞부분이 통째로
  /// 공유돼(실측 1869자) 한 파일만 보고 앞 100자를 자르면 전부 같은 문장이 된다.
  List<AgentRun> readAll() {
    final drafts = <_Draft>[];
    for (final f in resolver.jsonlFiles()) {
      if (!p.basename(f.path).startsWith('agent-')) continue;
      final draft = _readFile(f);
      if (draft != null) drafts.add(draft);
    }
    return _describe(drafts);
  }

  /// 라이브 폴링용 — **서브에이전트 + 메인 세션** 중 최근 [within] 안에 수정된 파일만
  /// 파싱한다. 지금 도는 것의 파일만 방금 쓰였으므로, 매 초 전체([readAll], 실측 2.3초)를
  /// 다시 읽지 않아도 된다. (막 끝난 것도 섞일 수 있다 — 호출부가 `isRunning` 으로 거른다.)
  ///
  /// 메인 세션이 섞이는 이유: 서브 없이 프롬프트만 돌면(= 메인만 일하면) 서브 파일이 아예
  /// 없어서 라이브 씬이 텅 빈다. 둘은 [AgentRun.agentType] == [mainAgentType] 로 구분한다.
  ///
  /// [within] 은 판정 창(60초)보다 넉넉히 잡는다: 파일 mtime 은 마지막 레코드 시각과
  /// 미묘하게 다를 수 있어(항상 그 이상) 여유를 둬야 도는 마리를 놓치지 않는다.
  ///
  /// 비용: 메인 세션 파일은 크지만(실측 최대 15MB) 창 안에 드는 건 지금 도는 세션뿐이고
  /// 전체 파싱이 실측 ~60ms/15MB(대부분 파일 읽기) 라 2초 폴링에 얹을 만하다.
  List<AgentRun> readLive({Duration within = const Duration(seconds: 90)}) {
    final cutoff = _now().toUtc().subtract(within);
    final drafts = <_Draft>[];
    for (final f in resolver.jsonlFiles()) {
      final main = !p.basename(f.path).startsWith('agent-');
      if (main && !_isMainSession(f.path)) continue; // 서브도 메인도 아닌 파일
      final DateTime modified;
      try {
        modified = f.statSync().modified.toUtc();
      } catch (_) {
        continue; // 읽는 사이 사라짐/실패 → 건너뜀
      }
      if (modified.isBefore(cutoff)) continue; // 오래된 파일 = 안 도는 것, 파싱 생략
      final draft = main ? _readMain(f) : _readFile(f);
      if (draft != null) drafts.add(draft);
    }
    return _describe(drafts);
  }

  /// 기록 탭 그룹의 사람이 읽는 제목 — 워크플로우는 `workflowName`, 세션은 최신 `ai-title`.
  /// 키는 호출부의 그룹 키와 같은 규약(`workflowId ?? sessionId`), 못 찾은 그룹은 **키가 없다**
  /// (호출부가 기존 ID 폴백을 쓴다).
  ///
  /// [representatives] 는 그룹당 대표 실행 1건 — 제목 파일은 그룹마다 하나뿐이라 [readAll] 이
  /// 읽는 1400 파일을 다시 읽을 이유가 없다. **그룹을 확정한 뒤** 부르는 게 이 싸기의 전제다.
  ///
  /// 비용(실측 134그룹 = 워크플로우 80 + 세션 54): 합쳐 ~0.95초. 워크플로우 JSON 은 작아서
  /// 공짜에 가깝고 값은 전부 세션 jsonl 이 치른다(그쪽만 파일당 수 MB). 기록 탭 첫 진입에서
  /// readAll(1.7초) 뒤에 한 번만 든다 — 그래서 라이브(2초 폴링)엔 안 쓴다.
  Map<String, String> readTitles(List<AgentRun> representatives) {
    final titles = <String, String>{};
    for (final r in representatives) {
      final key = r.workflowId ?? r.sessionId;
      if (titles.containsKey(key)) continue; // 대표가 여럿 와도 파일은 한 번만
      final dir = _sessionDir(r.filePath);
      if (dir == null) continue;
      final title = r.workflowId != null
          ? _workflowName(File(p.join(dir, 'workflows', '${r.workflowId}.json')))
          : _aiTitle(File('$dir.jsonl'));
      if (title != null) titles[key] = title;
    }
    return titles;
  }

  /// 이 서브에이전트 실행의 세션 디렉토리(= `subagents` 의 부모). 제목 파일 둘 다 여기 기준이다:
  /// 세션은 `<sessionDir>.jsonl`, 워크플로우는 `<sessionDir>/workflows/<workflowId>.json`.
  /// `subagents` 아래 깊이가 워크플로우 유무로 갈려서(0/2단계) 이름으로 거슬러 올라간다.
  String? _sessionDir(String agentPath) {
    var dir = p.dirname(agentPath);
    while (p.basename(dir) != 'subagents') {
      final parent = p.dirname(dir);
      if (parent == dir) return null; // 루트까지 갔다 = 서브에이전트 구조가 아님
      dir = parent;
    }
    return p.dirname(dir);
  }

  /// `workflows/<workflowId>.json` 의 `workflowName` — 사람이 지은 워크플로우 이름.
  String? _workflowName(File f) {
    try {
      final decoded = json.decode(f.readAsStringSync());
      if (decoded is Map) {
        final name = decoded['workflowName'];
        if (name is String && name.trim().isNotEmpty) {
          return _clip(_oneLine(name), _descriptionMax);
        }
      }
    } catch (_) {
      // 파일 없음/깨짐 → 폴백(호출부가 ID 를 쓴다).
    }
    return null;
  }

  /// 메인 세션 파일의 최신 제목 = 마지막 `type:"ai-title"`. 없는 세션도 있다(실측).
  ///
  /// 제목만 필요할 땐 줄마다 [json.decode] 하지 않는다 — 세션 파일은 크고(실측 최대 15MB)
  /// 여기선 그룹 수만큼 읽는다. 문자열 선별 후 파싱이 실측 40ms vs 48ms/15MB.
  String? _aiTitle(File f) {
    String? title;
    for (final line in _rawLines(f)) {
      if (!line.contains('"ai-title"')) continue;
      final Object? decoded;
      try {
        decoded = json.decode(line);
      } catch (_) {
        continue;
      }
      if (decoded is! Map || decoded['type'] != 'ai-title') continue;
      final t = decoded['aiTitle'];
      if (t is String && t.trim().isNotEmpty) {
        title = _clip(_oneLine(t), _descriptionMax); // 덮어쓴다 — 마지막이 최신
      }
    }
    return title;
  }

  /// 에이전트 1마리의 전체 작업 로그 — 도구 호출(인자 포함)과 에이전트가 쓴 글을 순서대로.
  ///
  /// [readAll] 에 안 담고 클릭 시 그 파일만 다시 읽는다 — 글까지 담으면 1400 파일 ×
  /// 수 KB 를 늘 들고 있게 되고, 정작 보는 건 한 번에 한 마리다.
  List<AgentStep> readSteps(String filePath) {
    final steps = <AgentStep>[];
    var promptSeen = false;
    for (final line in _lines(File(filePath))) {
      final message = line['message'];
      if (message is! Map) continue;
      final content = message['content'];
      // 첫 `type:"user"`(content 가 String) = 받은 지시. 카드 설명과 달리 클립하지 않는다 —
      // 상세 로그는 "무엇을 하라고 시켰나" 를 전문으로 보여주는 자리다. 도구 결과는 content 가
      // List 라 여기 안 걸린다(첫 지시 한 번만).
      if (!promptSeen && line['type'] == 'user' && content is String) {
        promptSeen = true;
        final prompt = _oneLine(content);
        if (prompt.isNotEmpty) steps.add(AgentStep.prompt(prompt));
        continue;
      }
      if (content is! List) continue;
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            final text = _oneLine((block['text'] as String?) ?? '');
            if (text.isNotEmpty) steps.add(AgentStep.text(text));
          case 'tool_use':
            steps.add(AgentStep.toolUse(_toolCall(block)));
        }
      }
    }
    return steps;
  }

  /// 메인 세션 1개의 "지금 하는 일" 로그 — 서브의 [readSteps] 와 두 가지가 다르다.
  ///
  ///  ① 받은 지시 = 최신 `last-prompt`(사람이 방금 친 것). 서브는 첫 `user` 줄이 곧 지시지만
  ///     메인의 첫 `user` 줄은 몇 시간 전 세션 시작이라 "지금" 이 아니다. 없으면 첫 `user` 로 폴백.
  ///  ② 활동은 **최근순**(파일 역순). 세션 파일은 수천 줄이라 정순으로 두면 지금 하는 일이 맨
  ///     아래 파묻힌다 — 클릭한 사람이 보려는 건 방금 한 일이다.
  ///
  /// [readSteps] 와 마찬가지로 클릭 시 그 파일만 읽는다(라이브 씬은 이 로그를 늘 들고 있지 않다).
  List<AgentStep> readMainSteps(String filePath) {
    String? lastPrompt, firstUser;
    final activity = <AgentStep>[];
    for (final line in _lines(File(filePath))) {
      if (line['type'] == 'last-prompt') {
        final last = line['lastPrompt'];
        if (last is String && last.trim().isNotEmpty) lastPrompt = last; // 마지막 = 최신
        continue;
      }
      final message = line['message'];
      if (message is! Map) continue;
      final content = message['content'];
      if (firstUser == null && line['type'] == 'user' && content is String) {
        firstUser = content;
      }
      if (content is! List) continue;
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            final text = _oneLine((block['text'] as String?) ?? '');
            if (text.isNotEmpty) activity.add(AgentStep.text(text));
          case 'tool_use':
            activity.add(AgentStep.toolUse(_toolCall(block)));
        }
      }
    }
    final prompt = _oneLine(lastPrompt ?? firstUser ?? '');
    return [
      if (prompt.isNotEmpty) AgentStep.prompt(prompt),
      ...activity.reversed, // 최근이 앞
    ];
  }

  /// 파일의 줄들(원문). 읽기 실패(라이브 세션 중 사라짐 등)면 빈 목록.
  Iterable<String> _rawLines(File f) {
    final String bytes;
    try {
      // 라이브 세션 중 스캔 → 읽는 사이 사라질 수 있음. 깨진 바이트도 통과.
      bytes = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
    } catch (_) {
      return const [];
    }
    return const LineSplitter().convert(bytes);
  }

  /// 파일의 JSON 객체 줄들. 부분/깨진 줄은 건너뛴다(flush 중일 수 있음).
  Iterable<Map<Object?, Object?>> _lines(File f) sync* {
    for (final line in _rawLines(f)) {
      final Object? decoded;
      try {
        decoded = json.decode(line);
      } catch (_) {
        continue;
      }
      if (decoded is Map) yield decoded;
    }
  }

  /// 파일 하나를 훑는다 — 서브와 메인 세션이 레코드 규약(timestamp·`message.usage`·
  /// `content[].tool_use`)을 공유해서 스캔도 공유한다. 다른 건 부르는 쪽이 정한다.
  _Scan _scan(File f) {
    final s = _Scan();
    for (final obj in _lines(f)) {
      final ts = DateTime.tryParse((obj['timestamp'] as String?) ?? '')?.toUtc();
      if (ts != null) {
        if (s.startedAt == null || ts.isBefore(s.startedAt!)) s.startedAt = ts;
        if (s.endedAt == null || ts.isAfter(s.endedAt!)) s.endedAt = ts;
      }

      // 메인 세션만 갖는 레코드들 — `message` 가 아예 없어서 아래 검사보다 먼저 본다.
      // 둘 다 세션이 도는 동안 갱신되므로 덮어쓴다(마지막 = 최신).
      if (obj['type'] == 'ai-title') {
        final title = obj['aiTitle'];
        if (title is String && title.trim().isNotEmpty) s.aiTitle = title;
        continue;
      }
      if (obj['type'] == 'last-prompt') {
        final last = obj['lastPrompt'];
        if (last is String && last.trim().isNotEmpty) s.lastPrompt = last;
        continue;
      }

      final message = obj['message'];
      if (message is! Map) continue;
      final content = message['content'];

      if (s.prompt == null && obj['type'] == 'user' && content is String) {
        s.prompt = content;
      }

      if (content is List) {
        for (final block in content) {
          if (block is Map && block['type'] == 'tool_use') {
            s.toolCalls.add(_toolCall(block));
          }
        }
      }

      final usage = message['usage'];
      if (usage is Map) {
        s.inputTokens += (usage['input_tokens'] as num?)?.toInt() ?? 0;
        s.outputTokens += (usage['output_tokens'] as num?)?.toInt() ?? 0;
      }
    }
    return s;
  }

  _Draft? _readFile(File f) {
    final path = f.path;
    final parts = path.split(RegExp(r'[/\\]')); // Windows 겸용
    final subIdx = parts.lastIndexOf('subagents');
    if (subIdx < 1) return null; // 서브에이전트 구조가 아님
    final project = ClaudePathResolver.projectFromPath(path);
    if (project == null) return null;

    final s = _scan(f);
    if (s.startedAt == null || s.endedAt == null) return null; // 빈/무의미한 파일

    final (agentType, metaDescription) = _meta(path);
    return _Draft(
      run: AgentRun(
        agentId: p.basenameWithoutExtension(path).substring('agent-'.length),
        agentType: agentType,
        project: project,
        sessionId: parts[subIdx - 1],
        filePath: path,
        workflowId:
            (subIdx + 2 < parts.length && parts[subIdx + 1] == 'workflows')
                ? parts[subIdx + 2]
                : null,
        description: '', // _describe 에서 확정
        startedAt: s.startedAt!,
        endedAt: s.endedAt!,
        toolCalls: s.toolCalls,
        inputTokens: s.inputTokens,
        outputTokens: s.outputTokens,
        isRunning: _now().toUtc().difference(s.endedAt!) < _runningWindow,
      ),
      metaDescription: metaDescription,
      prompt: s.prompt ?? '',
    );
  }

  /// 메인 세션 파일(`projects/<project>/<sessionId>.jsonl`) → 사람 1명분의 실행.
  ///
  /// 서브와 다른 것만 여기서 정한다: 타입은 [mainAgentType] 고정(`meta.json` 이 없다),
  /// 설명은 최신 `ai-title` > 사람이 마지막으로 친 글 > 첫 `user` 줄. `ai-title` 이 없는
  /// 세션이 실측 142/438 이라 폴백이 실제로 쓰인다 — 그리고 그중 88건은 첫 `user` 줄이
  /// `<command-*>` 확장이라 [_Scan.lastPrompt] 를 먼저 본다.
  /// 앞의 둘은 "프롬프트보다 우선하는 짧은 제목" 이라 [_describe] 의 meta 라벨 자리를 쓴다.
  _Draft? _readMain(File f) {
    final path = f.path;
    final project = ClaudePathResolver.projectFromPath(path);
    if (project == null) return null;

    final s = _scan(f);
    if (s.startedAt == null || s.endedAt == null) return null; // 빈/무의미한 파일

    final sessionId = p.basenameWithoutExtension(path);
    return _Draft(
      run: AgentRun(
        agentId: sessionId,
        agentType: mainAgentType,
        project: project,
        sessionId: sessionId,
        filePath: path,
        workflowId: null,
        description: '', // _describe 에서 확정
        startedAt: s.startedAt!,
        endedAt: s.endedAt!,
        toolCalls: s.toolCalls,
        inputTokens: s.inputTokens,
        outputTokens: s.outputTokens,
        isRunning: _now().toUtc().difference(s.endedAt!) < _runningWindow,
      ),
      metaDescription:
          s.aiTitle == null ? null : _clip(_oneLine(s.aiTitle!), _descriptionMax),
      prompt: s.lastPrompt ?? s.prompt ?? '',
    );
  }

  /// 메인 세션 파일인가 — `projects/<project>/<sessionId>.jsonl`, 즉 프로젝트 디렉토리
  /// **바로 아래**. 서브는 그 밑 `subagents/` 로 한 단계 이상 더 들어간다.
  bool _isMainSession(String path) {
    final parts = path.split(RegExp(r'[/\\]')); // Windows 겸용
    final idx = parts.lastIndexOf('projects');
    return idx >= 0 && parts.length == idx + 3;
  }

  /// 도구 호출 → 이름 + 사람이 읽을 인자 하나.
  ToolCall _toolCall(Map<Object?, Object?> block) {
    final name = (block['name'] as String?) ?? 'unknown';
    final input = block['input'];
    return ToolCall(name, input is Map ? _detail(input) : '');
  }

  /// 인자 중 "뭘 만졌나" 를 가장 잘 말해주는 것 하나. 실측 키 순서대로 본다.
  String _detail(Map<Object?, Object?> input) {
    for (final key in const [
      'file_path',
      'command',
      'pattern',
      'description',
      'url',
    ]) {
      final value = input[key];
      if (value is! String || value.trim().isEmpty) continue;
      return _clip(key == 'file_path' ? _shortPath(value) : _oneLine(value),
          _detailMax);
    }
    return '';
  }

  /// 설명 확정 — meta 라벨(정본) > 같은 워크플로우끼리 공통 접두사를 걷어낸 프롬프트 > 인덱스.
  List<AgentRun> _describe(List<_Draft> drafts) {
    final byWorkflow = <String, List<_Draft>>{};
    for (final d in drafts) {
      final wf = d.run.workflowId;
      if (wf != null) byWorkflow.putIfAbsent(wf, () => []).add(d);
    }

    // 경로는 파일당 유일 → 확정한 설명을 되찾는 키로 쓴다.
    final byPath = <String, String>{};

    // 1순위: meta.json 의 라벨. 사람이 쓴 짧은 라벨이라 제일 정확하다(실측 16% 만 있음).
    for (final d in drafts) {
      if (d.metaDescription != null) byPath[d.run.filePath] = d.metaDescription!;
    }

    // 2순위: 프롬프트. 워크플로우 안에서는 서로 갈라지는 지점부터 보여준다.
    // 공유 접두사는 팬아웃 전체의 성질이라 meta 라벨을 쓰는 마리의 프롬프트도 재료로 넣는다
    // (라벨 없는 마리가 그룹에 하나뿐이어도 접두사는 걷어내야 하니까).
    for (final group in byWorkflow.values) {
      final prompts = [
        for (final d in group)
          if (d.prompt.isNotEmpty) d.prompt,
      ];
      final cut = prompts.length < 2 ? 0 : _commonPrefix(prompts);
      for (final d in group) {
        if (d.metaDescription == null) {
          byPath[d.run.filePath] = _fromPrompt(d.prompt, cut);
        }
      }
    }
    for (final d in drafts) {
      byPath[d.run.filePath] ??= _fromPrompt(d.prompt, 0); // 워크플로우 밖
    }

    // 3순위(최후): 그래도 같으면 몇 번째 마리인지라도. 순서는 시작 시각.
    for (final group in byWorkflow.values) {
      final counts = <String, int>{};
      for (final d in group) {
        counts.update(byPath[d.run.filePath]!, (n) => n + 1, ifAbsent: () => 1);
      }
      final seen = <String, int>{};
      for (final d in [...group]
        ..sort((a, b) => a.run.startedAt.compareTo(b.run.startedAt))) {
        final desc = byPath[d.run.filePath]!;
        final total = counts[desc]!;
        if (total < 2) continue;
        final i = seen[desc] = (seen[desc] ?? 0) + 1;
        byPath[d.run.filePath] = '$desc ($i/$total)';
      }
    }

    return [
      for (final d in drafts) d.run.withDescription(byPath[d.run.filePath]!),
    ];
  }

  /// 프롬프트 앞 [cut] 자(= 그룹 공통분)를 걷어낸 뒤 앞 [_descriptionMax] 자.
  /// 걷어내니 남는 게 없으면(프롬프트가 아예 같으면) 원문에서 — 구분은 인덱스가 맡는다.
  String _fromPrompt(String prompt, int cut) {
    final rest = _oneLine(prompt.substring(cut));
    return _clip(rest.isEmpty ? _oneLine(prompt) : rest, _descriptionMax);
  }

  /// 프롬프트들이 공유하는 접두사 길이. 전부 똑같으면 0(걷어낼 게 아니라 구분이 불가능한 것).
  int _commonPrefix(List<String> prompts) {
    final first = prompts.first;
    var n = 0;
    while (n < first.length &&
        prompts.every((s) => n < s.length && s.codeUnitAt(n) == first.codeUnitAt(n))) {
      n++;
    }
    if (n == first.length && prompts.every((s) => s.length == n)) return 0;
    // 단어 중간에서 자르면 "…ction)" 처럼 시작한다 → 마지막 공백까지 되감는다.
    while (n > 0 && !_isSpace(first.codeUnitAt(n - 1))) {
      n--;
    }
    return n;
  }

  /// `agent-<id>.meta.json` 의 agentType(항상 있음) 과 description(사람이 쓴 라벨, 일부만).
  (String, String?) _meta(String jsonlPath) {
    try {
      final meta = File('${p.withoutExtension(jsonlPath)}.meta.json');
      final decoded = json.decode(meta.readAsStringSync());
      if (decoded is Map) {
        final description = decoded['description'];
        return (
          (decoded['agentType'] as String?) ?? 'unknown',
          description is String && description.trim().isNotEmpty
              ? _clip(_oneLine(description), _descriptionMax)
              : null,
        );
      }
    } catch (_) {
      // meta 없음/깨짐 → 폴백.
    }
    return ('unknown', null);
  }
}

/// 파일 하나를 훑은 결과 — 서브와 메인 세션이 공유하는 레코드들. 정체성(누구인지·어느 세션인지)은
/// 경로에서 나오므로 여기 없다.
class _Scan {
  DateTime? startedAt, endedAt;

  /// 사람이 준 첫 지시 = `type:"user"` 의 `content` 가 String 인 첫 줄(도구 결과는 List 다).
  String? prompt;

  /// 최신 제목 — 메인 세션의 마지막 `type:"ai-title"`. 서브 파일엔 이 레코드가 없다.
  String? aiTitle;

  /// 사람이 마지막으로 친 글 — 메인 세션의 `type:"last-prompt"`. 슬래시 명령을 쓰면 첫 `user`
  /// 줄이 `<command-message>…` 확장이라 사람 글이 아니다(실측: 제목 없는 142 세션 중 88건).
  /// 이 레코드는 사람이 친 원문 그대로다(실측 437/438 세션 보유).
  String? lastPrompt;

  final toolCalls = <ToolCall>[];
  int inputTokens = 0, outputTokens = 0;
}

/// 읽자마자의 1마리 — 설명은 아직 미정이라 그 재료(meta 라벨·첫 프롬프트)를 들고 있다.
class _Draft {
  final AgentRun run;

  /// 1순위 재료(없으면 null) — 서브는 `meta.json` 의 라벨, 메인 세션은 최신 `ai-title`.
  /// 둘 다 "프롬프트보다 우선하는 짧은 제목" 이라 [AgentRunReader._describe] 는 출처를 안 가린다.
  final String? metaDescription;

  final String prompt;
  const _Draft({
    required this.run,
    required this.metaDescription,
    required this.prompt,
  });
}

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

/// 개행·연속 공백 → 공백 하나. 한 줄에 넣으려면 개행이 있으면 안 된다.
String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;

/// 경로는 마지막 2 세그먼트만 — 한 줄에 다 안 들어가고, 구분되는 정보는 뒤쪽에 있다.
String _shortPath(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
  return parts.length <= 2 ? path : parts.sublist(parts.length - 2).join('/');
}
