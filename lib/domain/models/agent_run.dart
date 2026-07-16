/// 도구 호출 1건 — 이름 + 핵심 인자.
///
/// 이름만으로는 "Read 를 12번 했다" 까지밖에 모른다. [detail] 은 그 중 **뭘** 만졌는지
/// (`input.file_path`/`command`/`pattern`/…) 한 줄로 보여주는 값이라 이름과 붙어 다닌다.
class ToolCall {
  final String name;

  /// 인자 요약 — 파일 경로는 마지막 2 세그먼트, 그 외는 한 줄로 접어 자른 것. 없으면 ''.
  final String detail;

  const ToolCall(this.name, this.detail);
}

/// 상세 로그 한 줄 — 사람이 준 지시([isPrompt]) 이거나, 에이전트가 쓴 텍스트([tool] == null)
/// 이거나, 도구 호출([tool] != null) 이거나.
///
/// 파일 하나를 다시 읽어야 나온다([AgentRunReader.readSteps]) — [AgentRun] 에 늘 담기엔 크다.
class AgentStep {
  final ToolCall? tool;

  /// 지시([isPrompt]) 면 첫 프롬프트 전문, 아니면 에이전트가 쓴 텍스트. [tool] 이 있으면 ''.
  final String text;

  /// 사람이 이 마리에게 준 첫 지시(전문). 카드 설명은 100자로 잘리지만 이건 통째로 —
  /// 상세 로그 맨 앞에서 "무엇을 하라고 시켰나" 를 그대로 보여준다.
  final bool isPrompt;

  const AgentStep.text(this.text)
      : tool = null,
        isPrompt = false;
  const AgentStep.toolUse(ToolCall this.tool)
      : text = '',
        isPrompt = false;
  const AgentStep.prompt(this.text)
      : tool = null,
        isPrompt = true;
}

/// 메인 세션(사람이 직접 대화하는 그 세션) 의 [AgentRun.agentType].
///
/// 서브에이전트는 타입을 `meta.json` 에서 받지만 메인 세션엔 그 파일이 없다 → 이 상수로 고정한다.
/// 실측 타입 23종과 겹치지 않아야 한다 — 겹치면 메인이 동물로 그려진다(메인은 사람이다).
const String mainAgentType = 'main';

/// 에이전트 1회 실행 = jsonl 파일 하나 — 서브에이전트(`agent-<agentId>.jsonl`) 이거나
/// 메인 세션(`<sessionId>.jsonl`, [agentType] == [mainAgentType]) 이거나.
///
/// 과금 집계([UsageEvent]) 와는 별개 축이다. 이쪽은 "누가 무슨 일을 했나"(시각화)용
/// 읽기 전용 뷰라 DB 를 거치지 않고 파일에서 직접 만든다.
class AgentRun {
  final String agentId; // 파일명에서 추출 — 서브는 `agent-<agentId>`, 메인은 sessionId
  final String agentType; // meta.json 의 agentType(없으면 'unknown'). 메인은 [mainAgentType]
  final String project; // projects/ 하위 인코딩된 디렉토리명
  final String sessionId; // 이 에이전트를 띄운 세션(메인은 자기 자신)

  /// 원본 jsonl 경로 — 상세 로그를 클릭했을 때 이 파일만 다시 읽는다.
  final String filePath;

  /// 워크플로우로 실행됐을 때만 — `subagents/workflows/<workflowId>/` 에서 추출.
  final String? workflowId;

  /// 이 마리가 받은 일 — meta.json 의 라벨(메인은 최신 `ai-title`), 없으면 첫 프롬프트에서 뽑은 것.
  /// 뽑는 규칙은 [AgentRunReader.readAll] 참고(같은 워크플로우끼리 겹치지 않게 후처리한다).
  final String description;

  final DateTime startedAt; // 첫 레코드 timestamp(UTC)
  final DateTime endedAt; // 마지막 레코드 timestamp(UTC)

  /// 호출한 도구 — 호출 순서대로.
  final List<ToolCall> toolCalls;

  final int inputTokens;
  final int outputTokens;

  /// 마지막 레코드가 최근(60초 이내)이면 true — 아직 돌고 있다는 추정.
  final bool isRunning;

  const AgentRun({
    required this.agentId,
    required this.agentType,
    required this.project,
    required this.sessionId,
    required this.filePath,
    required this.workflowId,
    required this.description,
    required this.startedAt,
    required this.endedAt,
    required this.toolCalls,
    required this.inputTokens,
    required this.outputTokens,
    required this.isRunning,
  });

  /// 설명만 바꾼 사본 — 설명은 파일 하나만 봐서는 못 정하고(같은 워크플로우끼리
  /// 비교해야 한다) 전부 읽은 뒤에 확정되기 때문에 [AgentRunReader.readAll] 이 쓴다.
  AgentRun withDescription(String description) => AgentRun(
        agentId: agentId,
        agentType: agentType,
        project: project,
        sessionId: sessionId,
        filePath: filePath,
        workflowId: workflowId,
        description: description,
        startedAt: startedAt,
        endedAt: endedAt,
        toolCalls: toolCalls,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        isRunning: isRunning,
      );
}
