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

  /// 라이브 폴링용 — 최근 [within] 안에 수정된 파일만 파싱한다. 지금 도는 에이전트의
  /// 파일만 방금 쓰였으므로, 매 초 전체([readAll], 실측 2.3초)를 다시 읽지 않아도 된다.
  /// (막 끝난 마리도 섞일 수 있다 — 호출부가 `isRunning` 으로 거른다.)
  ///
  /// [within] 은 판정 창(60초)보다 넉넉히 잡는다: 파일 mtime 은 마지막 레코드 시각과
  /// 미묘하게 다를 수 있어(항상 그 이상) 여유를 둬야 도는 마리를 놓치지 않는다.
  List<AgentRun> readLive({Duration within = const Duration(seconds: 90)}) {
    final cutoff = _now().toUtc().subtract(within);
    final drafts = <_Draft>[];
    for (final f in resolver.jsonlFiles()) {
      if (!p.basename(f.path).startsWith('agent-')) continue;
      final DateTime modified;
      try {
        modified = f.statSync().modified.toUtc();
      } catch (_) {
        continue; // 읽는 사이 사라짐/실패 → 건너뜀
      }
      if (modified.isBefore(cutoff)) continue; // 오래된 파일 = 안 도는 것, 파싱 생략
      final draft = _readFile(f);
      if (draft != null) drafts.add(draft);
    }
    return _describe(drafts);
  }

  /// 에이전트 1마리의 전체 작업 로그 — 도구 호출(인자 포함)과 에이전트가 쓴 글을 순서대로.
  ///
  /// [readAll] 에 안 담고 클릭 시 그 파일만 다시 읽는다 — 글까지 담으면 1400 파일 ×
  /// 수 KB 를 늘 들고 있게 되고, 정작 보는 건 한 번에 한 마리다.
  List<AgentStep> readSteps(String filePath) {
    final steps = <AgentStep>[];
    for (final line in _lines(File(filePath))) {
      final message = line['message'];
      if (message is! Map) continue;
      final content = message['content'];
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

  /// 파일의 JSON 객체 줄들. 부분/깨진 줄은 건너뛴다(flush 중일 수 있음).
  Iterable<Map<Object?, Object?>> _lines(File f) sync* {
    final String bytes;
    try {
      // 라이브 세션 중 스캔 → 읽는 사이 사라질 수 있음. 깨진 바이트도 통과.
      bytes = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
    } catch (_) {
      return;
    }
    for (final line in const LineSplitter().convert(bytes)) {
      final Object? decoded;
      try {
        decoded = json.decode(line);
      } catch (_) {
        continue;
      }
      if (decoded is Map) yield decoded;
    }
  }

  _Draft? _readFile(File f) {
    final path = f.path;
    final parts = path.split(RegExp(r'[/\\]')); // Windows 겸용
    final subIdx = parts.lastIndexOf('subagents');
    if (subIdx < 1) return null; // 서브에이전트 구조가 아님
    final project = ClaudePathResolver.projectFromPath(path);
    if (project == null) return null;

    String? prompt;
    DateTime? startedAt, endedAt;
    final toolCalls = <ToolCall>[];
    int inputTokens = 0, outputTokens = 0;

    for (final obj in _lines(f)) {
      final ts = DateTime.tryParse((obj['timestamp'] as String?) ?? '')?.toUtc();
      if (ts != null) {
        if (startedAt == null || ts.isBefore(startedAt)) startedAt = ts;
        if (endedAt == null || ts.isAfter(endedAt)) endedAt = ts;
      }

      final message = obj['message'];
      if (message is! Map) continue;
      final content = message['content'];

      if (prompt == null && obj['type'] == 'user' && content is String) {
        prompt = content;
      }

      if (content is List) {
        for (final block in content) {
          if (block is Map && block['type'] == 'tool_use') {
            toolCalls.add(_toolCall(block));
          }
        }
      }

      final usage = message['usage'];
      if (usage is Map) {
        inputTokens += (usage['input_tokens'] as num?)?.toInt() ?? 0;
        outputTokens += (usage['output_tokens'] as num?)?.toInt() ?? 0;
      }
    }

    if (startedAt == null || endedAt == null) return null; // 빈/무의미한 파일

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
        startedAt: startedAt,
        endedAt: endedAt,
        toolCalls: toolCalls,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        isRunning: _now().toUtc().difference(endedAt) < _runningWindow,
      ),
      metaDescription: metaDescription,
      prompt: prompt ?? '',
    );
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

/// 읽자마자의 1마리 — 설명은 아직 미정이라 그 재료(meta 라벨·첫 프롬프트)를 들고 있다.
class _Draft {
  final AgentRun run;
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
