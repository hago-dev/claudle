import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../domain/models/agent_run.dart';

// ── 숲 씬(라이브)의 모델 ───────────────────────────────────────
//
// 세션(부모) = 사람 1명이 제 빈터 **위**에 서 있고, 그 세션이 띄운 서브 = 동물들이 그
// 앞마당(빈터)에서 논다. 세션 1개 = 세로 열 1개.
//
// 위젯은 모른다 — 그리기는 agents_screen.dart 의 _ForestSceneView 계열이 담당하고,
// 이 파일은 순수 계산(배치·상태머신) + 색/스프라이트 배정 규약만 가진다.

// ── 색 ─────────────────────────────────────────────────────

/// 자주 보이는 타입은 고정 색(눈에 익게), 나머지 롱테일(총 23종)은 이름 해시 → 팔레트.
const Map<String, Color> _fixedColors = {
  mainAgentType: Color(0xFFCBD5E1), // 세션(사람) — 중립 슬레이트, 종별 색과 안 겹치게
  'workflow-subagent': Color(0xFF7C5CFF), // 앱 시드 바이올렛
  'delegate': Color(0xFF4ADE80),
  'general-purpose': Color(0xFF38BDF8),
  'Explore': Color(0xFFFBBF24),
  'red-team': Color(0xFFF87171),
  'researcher': Color(0xFFA78BFA),
  'security-auditor': Color(0xFFFB923C),
  'code-reviewer': Color(0xFF34D399),
  'test-writer': Color(0xFF22D3EE),
  'Plan': Color(0xFFE879F9),
  'mentor': Color(0xFFFDE047),
};

const List<Color> _palette = [
  Color(0xFF60A5FA),
  Color(0xFFF472B6),
  Color(0xFF2DD4BF),
  Color(0xFFC084FC),
  Color(0xFFFACC15),
  Color(0xFF94A3B8),
];

/// **기록·배지** 쪽 타입별 색 — 재생 카드와 구성 미리보기 색점이 "어떤 타입 조합인지" 를
/// 읽는 자리라 결정론을 유지한다. 해시는 직접 계산 — `String.hashCode` 는 런타임이 바꿀 수 있다.
///
/// **라이브는 이걸 안 쓴다** — 색도 등장마다 섞여야 한다는 사용자 요구로 [ForestScene.sync]
/// 가 [randomAgentColor] 로 뽑고, 시트엔 그 마리의 색을 넘긴다(종과 같은 규약).
Color agentColor(String agentType) {
  final fixed = _fixedColors[agentType];
  if (fixed != null) return fixed;
  var h = 0;
  for (final c in agentType.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _palette[h % _palette.length];
}

/// 라이브 랜덤 추첨용 색 풀 — 타입 고정색(사람용 슬레이트 제외) + 해시 팔레트의 합집합.
/// 따로 안 만들고 합쳐 쓴다: 이미 라벨·배지에서 검증된 색들이고, 타입색이 늘면 풀도 따라 는다.
final List<Color> _colorPool = [
  for (final e in _fixedColors.entries)
    if (e.key != mainAgentType) e.value,
  ..._palette,
];

/// **라이브** 등장 1회 = 새로 섞은 색 하나 — [randomAnimalSprite] 와 같은 규약(사용자:
/// "색상도 여러 가지였으면"). 종과 독립으로 뽑아 같은 종끼리도 색이 갈린다.
Color randomAgentColor(math.Random rnd) => _colorPool[rnd.nextInt(_colorPool.length)];

// ── 캐릭터(큐브펫) 배정 ────────────────────────────────────────

/// `assets/agents/animal-<name>.png` 24종. 해시 배정 풀이자 declared asset 목록과 1:1.
const List<String> _animalPool = [
  'beaver', 'bee', 'bunny', 'cat', 'caterpillar', 'chick', 'cow', 'crab',
  'deer', 'dog', 'elephant', 'fish', 'fox', 'giraffe', 'hog', 'koala',
  'lion', 'monkey', 'panda', 'parrot', 'penguin', 'pig', 'polar', 'tiger',
];

/// **기록** 쪽 마리 → 스프라이트(`assets/agents/animal-<종>.png`). 종은 타입이 아니라
/// 개체(agentId) 해시 — 타입 고정 배정(delegate=개)은 팬아웃이 전부 같은 동물이라 심심하다는
/// 사용자 요구로 버렸다. 결정론인 이유: 재생 카드와 그 시트가 같은 동물을 가리켜야 해서
/// (어긋나면 클릭한 펭귄의 시트에 개가 뜬다). 해시는 [agentColor] 와 같은 h*31+c 직접 계산.
///
/// **라이브는 이걸 안 쓴다** — 등장할 때마다 종이 다시 섞여야 한다는 사용자 요구로
/// [ForestScene.sync] 가 [randomAnimalSprite] 로 뽑고, 시트엔 그 마리의 스프라이트를 넘긴다.
String agentSprite(AgentRun run) {
  var h = 0;
  for (final c in run.agentId.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return 'animal-${_animalPool[h % _animalPool.length]}';
}

/// **라이브** 등장 1회 = 새로 섞은 종 하나. 씬에 나타나는 순간 [ForestScene._rnd] 로 뽑아
/// [Beast.sprite] 에 저장한다 — 화면에 있는 동안엔 유지(매 폴링 섞으면 2초마다 종이 바뀌는
/// 스트로브가 된다), 떠났다 다시 등장하면 새 종. 랜덤 소스는 호출자가 준다(테스트가 시드를 쥔다).
String randomAnimalSprite(math.Random rnd) =>
    'animal-${_animalPool[rnd.nextInt(_animalPool.length)]}';

/// `assets/agents/character-<...>.png` 12종 — 서브를 스폰한 메인(부모)을 상징하는 사람.
/// 동물이 서브에이전트라면 이쪽은 그 위의 감독자(세션).
const List<String> _personPool = [
  'character-male-a', 'character-male-b', 'character-male-c',
  'character-male-d', 'character-male-e', 'character-male-f',
  'character-female-a', 'character-female-b', 'character-female-c',
  'character-female-d', 'character-female-e', 'character-female-f',
];

/// 세션 → 사람 스프라이트. 같은 세션(그 세션이 스폰한 서브들의 부모)은 늘 같은 사람이 되게
/// [agentColor]·[agentSprite] 와 같은 h*31+c 로 직접 계산한다(실행마다 안 바뀌게).
String personSprite(String sessionId) {
  var h = 0;
  for (final c in sessionId.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _personPool[h % _personPool.length];
}

// ── 씬 구획 ──────────────────────────────────────────────────
const _padX = 24.0, _playTopGap = 30.0, _playPadBottom = 20.0, _minColW = 300.0;
// 크기 — 실측 기준. 동물 56 = 카드와 동일, 사람 64 = 1:1 네이티브.
const animalSize = 56.0, personSize = 64.0;
const depthMin = 0.86, depthSpan = 0.20; // 원근 스케일
// 셀(마리 1개 박스) — 고정 기하라 스케일이 변해도 지면선이 안 흔들린다.
const cellW = 104.0, chipH = 16.0, spriteBoxH = 72.0, labelH = 18.0;
const cellH = chipH + spriteBoxH + labelH; // 106
const groundY = chipH + spriteBoxH; // 88 — 셀 안 지면선
// 배회
const _speedWander = 26.0, _speedWanderVar = 20.0; // 26..46 px/s
const _speedChase = 78.0, _speedChaseVar = 34.0; // 78..112 px/s
const _arriveWander = 3.0, _arriveChase = 26.0; // 26 = 겹치기 전에 멈춘다
// 위상/초 — _Critter 는 한 위상에 두 번 튄다 → 1.4 ≈ 기존 700ms 컨트롤러.
const _bobHzWander = 1.4, _bobHzChase = 2.3;
const _restMin = 0.4, _restVar = 1.2, _repick = 6.0, _maxDt = 0.05;
const _spawnJitter = 14.0, _fadeOut = 0.45;
// 이만큼 도구 소식이 없으면 💭(생각 중) — 긴 Bash 실행도 걸리는 한계는 스펙으로 수용.
const _thinkAfter = 8.0;
// 캠프 모임 — 쉬기(20%) 중 이 확률은 그 자리가 아니라 캠프까지 걸어가 오래 쉰다.
const _campChance = 0.08, _campSpread = 30.0, _campDepth = 14.0;
const _campRestMin = 2.0, _campRestVar = 2.0;
// 상한
const labelMax = 12, _beastMax = 48;
// 발밑 이름표(동작명) 글자 수 — 104px 셀에 한 줄. 넘치면 …. 사용자 요청("한 10글자").
const labelMaxChars = 10;

/// 스프라이트 콘텐츠 바닥이 64px 캔버스 바닥에서 뜬 픽셀 — alpha bbox 실측값. 기본 9.
/// 아래 종들은 프레임 안에 작게 그려져 많이 뜬다(안 넣으면 발밑 그림자가 6~10px 어긋난다).
const _botGap = <String, int>{
  'animal-monkey': 14, 'animal-fish': 15, 'animal-koala': 16, 'animal-parrot': 17,
  'animal-elephant': 17, 'animal-penguin': 18, 'animal-chick': 18, 'animal-crab': 19,
  'forest-rocks-high': 0, 'forest-tent': 5, 'forest-rocks-low': 8, 'forest-stones': 8,
  'forest-tree': 12, 'forest-rocks-ramp': 12, 'forest-tree-high': 13, 'forest-flag': 14,
  'forest-plant': 21,
};

/// 콘텐츠 발이 스프라이트 박스 top 에서 차지하는 비율 — 그리기: `top = 발밑y - footInset(s)*size`.
/// 사람 12종은 전부 botGap 12~13 이라 한 값, 표에 없는 동물 16종은 6~11 이라 기본 9(최대 오차 2.6px).
double footInset(String s) =>
    (64 - (s.startsWith('character-') ? 12 : (_botGap[s] ?? 9))) / 64; // 0.70(crab) ~ 1.0(rocks-high)

/// 팩마다 캔버스 대비 콘텐츠 스케일이 달라(나무 22×38 < 여우 39×46) 종류별 렌더 크기가 강제된다.
/// 64px 로 그리면 여우가 나무보다 큰 숲이 된다. 값 옆은 실제 렌더 결과(px).
/// 숲 팩 13종 중 11종만 반입 — bridge(물이 없다)·fence(가로 1세그먼트라 경계로 못 쓴다) 제외.
const propSize = <String, double>{
  'forest-tree': 132, // 45×78  (여우 34×40 의 약 2배 높이)
  'forest-tree-high': 150, // 38×87  (좁고 큰 침엽수)
  'forest-rocks-high': 76, // 62×76
  'forest-rocks-low': 60, 'forest-rocks-ramp': 60,
  'forest-tent': 84, // 68×64  (사람 36×40 보다 크게)
  'forest-flag': 72, 'forest-plant': 44, 'forest-stones': 40,
  'forest-patch-grass': 96, 'forest-patch-dirt': 88,
};

/// 뒷숲 추첨 풀 — 나무가 두 번 들어가 흔한 쪽으로 기운다(숲이니까).
const _backKinds = [
  'forest-tree', 'forest-tree-high', 'forest-rocks-high',
  'forest-tree', 'forest-rocks-ramp', 'forest-tree-high',
];

/// 콩콩 파형(0..1, 위로) — 한 위상에 두 번. 스프라이트와 발밑 그림자가 같이 쓴다.
double hopWave(double phase) => math.sin(phase * 2 * math.pi).abs();

/// 지금이 밤인가 — 숲 하늘이 밤이면 별이 뜬다. 로컬 시각 기준(사람이 보는 창밖과 맞아야 한다).
/// 새벽 3시 팬아웃은 밤 숲에서 논다.
bool isNightAt(DateTime local) => local.hour < 6 || local.hour >= 18;

/// 이모트 말풍선 수명(초) — 뷰의 팝 진행도(`(clock - emoteAt) / emoteFor`)와 tick 만료가 같이 쓴다.
const emoteFor = 1.4;

/// 완료 축하 길이(초) — 일이 끝난 마리는 이만큼 제자리 점프(+뷰의 별 파티클) 후에야 페이드한다.
const celebrateFor = 1.1;

/// 성장 상한 — 최심도(가장 가까운 자리) 마리가 [spriteBoxH] 를 안 넘는 값이 천장이다.
/// `56 × (0.86+0.20) × 1.2 = 71.2 ≤ 72` — 더 키우면 머리 위 칩과 발밑 이름표를 침범한다.
const growthCap = 1.2;

/// 토큰 먹고 성장 — 뱉은 만큼(output) 조금씩 커진다. 로그 스케일인 이유: 실측 분포가
/// 수백~수만으로 두 자릿수 넘게 벌어져 선형으로 하면 큰 놈만 캡에 붙고 나머지는 전부 기본 크기다.
/// 50k 토큰에서 캡에 닿는다.
double growthScale(int outputTokens) => math.min(
      growthCap,
      1 + (growthCap - 1) * math.log(1 + outputTokens / 500) / math.log(101),
    );

/// 도구 → 이모트 이모지. 도구명 규약은 agents_screen 의 _toolIcon 과 동일(실측 분포 기준,
/// 서브에이전트 스폰 도구명은 Task).
String toolEmote(String tool) {
  if (tool.startsWith('mcp__')) return '🔌';
  switch (tool) {
    case 'Bash':
    case 'bash':
    case 'BashOutput':
      return '⚡';
    case 'Read':
      return '📖';
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
      return '✍️';
    case 'Grep':
    case 'Glob':
    case 'ToolSearch':
      return '🔍';
    case 'Task':
      return '🐣';
    case 'WebFetch':
    case 'WebSearch':
      return '🌐';
    default:
      return '🔧';
  }
}

/// 씬 배치용 결정론 해시 — [agentColor]·[agentSprite]·[personSprite] 와 같은 h*31+c 규약.
/// [salt] 로 같은 키에서 독립된 값을 여러 개 뽑는다(x·y·종류). 폴링마다 숲이 춤추지 않게.
int _sceneHash(String key, int salt) {
  var h = salt & 0x7fffffff;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

double _sceneRand(String key, int salt) => (_sceneHash(key, salt) % 10007) / 10007.0;

/// 배경 소품 1개. [flat] = 바닥 얼룩(중심 앵커), 아니면 발밑 앵커([footInset]).
class SceneProp {
  final String sprite;
  final Offset at;
  final double size;
  final bool flat;
  const SceneProp(this.sprite, this.at, this.size, {this.flat = false});
}

/// 캠프(사람이 선 텐트 자리) 앞 한 점 — 빈터 맨 위, 사람 발밑 근처. 여러 마리가 각자
/// 이리로 걸어오면 저절로 캠프파이어에 둘러앉은 그림이 된다. clamp 는 좁은 열 대비 —
/// "목표점은 늘 play 안" 이 씬의 불변식이라 여기서 깨면 경계 코드가 되살아난다.
Offset campSpot(Clearing c, math.Random rnd) => Offset(
      (c.personFeet.dx + (rnd.nextDouble() - 0.5) * _campSpread * 2)
          .clamp(c.play.left, c.play.right),
      (c.play.top + rnd.nextDouble() * _campDepth)
          .clamp(c.play.top, c.play.bottom),
    );

/// 세션 1개 = 세로 열 1개. 사람은 빈터 **위**에 고정, 동물은 빈터([play]) 안에서만 논다.
class Clearing {
  final String sessionId, sprite; // sprite = personSprite(sessionId)
  final Offset personFeet;
  final Rect play;
  const Clearing({
    required this.sessionId,
    required this.sprite,
    required this.personFeet,
    required this.play,
  });
}

/// 씬 안의 동물 한 마리 = 도는 서브 1개. [run] 은 폴링마다 갈리지만 위치·기분은 이어진다.
class Beast {
  final String agentId, sprite; // 'animal-fox' — 등장 시 1회 결정
  final Color color; // randomAgentColor 로 1회 결정
  AgentRun run; // 폴링마다 교체(final 아님)
  String sessionId;
  Offset pos = Offset.zero, target = Offset.zero;
  double speed = 0, hopHz = 0, arrive = _arriveWander, rest = 0, until = 0;
  double phase = 0; // 0..1 — **개체별 누적**. 공유 위상이면 전원이 같은 박자로 뛴다(로봇)
  double fade = 1;
  bool moving = false, leaving = false, hovered = false, placed = false;
  String? chaseId; // 살아있는 추격 목표. null = 고정 목표점

  /// 지금까지 본 도구 호출 수 — [ForestScene.sync] 가 폴링 delta 로 "새 호출" 을 감지하는 기준.
  /// run 은 파일 전체를 다시 파싱한 누적치라 줄지 않는다. 첫 등장 땐 이력 전체를 이벤트로
  /// 치지 않게 지금 값으로 초기화한다.
  int seenTools = 0;

  /// 머리 위 이모트(이모지)와 발화 시각(씬 clock). 수명은 모델이 소유 — tick 이
  /// [emoteFor] 지나면 지우고, 뷰는 `clock - emoteAt` 로 팝 진행도만 유도한다.
  String? emote;
  double emoteAt = -1;

  /// 지금까지 본 실패([ToolCall.isError]) 수 — [seenTools] 와 같은 delta 규약.
  /// 결과는 호출보다 나중 줄로 도착해 toolCalls 개수 delta 없이 늘 수 있다 → 따로 센다.
  int seenErrors = 0;

  /// 😵 진행 중 — 뷰가 스프라이트를 한 바퀴 돌린다. 수명은 [emote] 채널과 함께 끝난다.
  bool dizzy = false;

  /// 마지막으로 도구 소식을 들은 씬 clock — 등장 시각으로 시작한다.
  /// [ForestScene.thinking] 의 기준: 한동안 조용하면 LLM 이 생각 중이다.
  double lastToolAt = 0;

  /// 축하가 끝나는 씬 clock — leaving 첫 전환에만 `clock + celebrateFor` 로 잡힌다.
  /// 이 시각 전까지 fade 는 보류(제자리 점프), 재등장하면 꺼진다(-1).
  double celebrateUntil = -1;

  /// 캠프에 도착하면 쉴 시간(초) — 목적지에 닿는 순간 [rest] 로 옮겨지고 0 으로 비워진다.
  /// 0 = 캠프행이 아니다(그냥 어슬렁).
  double pendingRest = 0;

  Beast({
    required this.agentId,
    required this.sprite,
    required this.color,
    required this.run,
    required this.sessionId,
  });
}

/// 숲 씬의 모델 — 위젯을 모른다(순수 계산 + Listenable). 소유자는 agents_screen 의
/// _ForestSceneState.
///
/// [tick] 만 notify 한다. [resize]·[sync] 는 빌드/레이아웃 중에 불려서 notify 하면
/// "setState during build" 로 죽는다.
class ForestScene extends ChangeNotifier {
  /// [rnd] 는 테스트가 시드를 쥐게 주입 가능 — 움직임·종·색(등장마다 섞임)은 결정론이
  /// 아니지만, 시드가 같으면 시퀀스는 같다(사람만 해시로 고정한다).
  ForestScene({math.Random? rnd}) : _rnd = rnd ?? math.Random();

  final _beasts = <String, Beast>{};
  final _byId = <String, Clearing>{}; // sessionId → 빈터
  final math.Random _rnd;
  Map<String, AgentRun> _mainOf = const {}; // sessionId → 지금 도는 메인(사람이 하는 일)

  /// sessionId → 최신 ai-title. **붙잡아 둔다** — 메인 세션 파일은 서브가 도는 동안 안 쓰여서
  /// mtime 창을 들락거린다. 매번 [_mainOf] 에서 읽으면 이름표가 제목 ↔ 세션ID 로 깜빡인다.
  final _titleOf = <String, String>{};

  /// sessionId → 마지막으로 본 메인 실행. [_titleOf] 와 같은 이유로 **붙잡아 둔다** — 사람을
  /// 클릭했을 때 그 세션의 상세 로그를 열 filePath 가 필요한데, 서브가 도는 동안 메인이 창 밖으로
  /// 빠져 [_mainOf] 가 비어도 클릭은 먹혀야 한다(마지막 본 실행의 경로로 파일을 다시 읽는다).
  final _mainRunOf = <String, AgentRun>{};

  List<String> _sessions = const []; // 지금 배치된 열(포커스 중이면 1개)
  List<String> _allSessions = const []; // 포커스와 무관하게 살아있는 전체 — 복귀·해제의 근거
  Size _size = Size.zero;
  Duration _last = Duration.zero;

  double clock = 0;
  List<Clearing> clearings = const [];
  List<SceneProp> floor = const [], back = const []; // 배경 — 리사이즈/세션 변화 때만 갱신
  int hidden = 0;
  double sceneW = 0, colW = 0;

  /// 지금 output 토큰을 가장 많이 뱉은 마리 — 뷰가 머리에 👑 을 얹는다.
  /// null = 아직 아무도 안 뱉었다(0 토큰은 왕이 아니다).
  String? crownId;

  /// 혼자 보고 있는 세션. null = 전체 뷰.
  ///
  /// 확대(Transform)가 아니라 **필터**다 — 열이 하나면 [_relayout] 이 알아서 화면 전체를
  /// 준다. 가려진 열의 마리는 빈터가 없어져([clearingOf] == null) 뷰도 [_step] 도 건너뛰지만
  /// [_beasts] 에는 남아 복귀하면 놀던 자리에 그대로 있다.
  String? focus;

  /// 전체 뷰로 돌아갈 수 있는가 — 뷰가 어포던스(이름표 클릭·전체 보기 버튼)를 세션이 둘 이상일
  /// 때만 보여주는 근거.
  bool get canFocus => _allSessions.length > 1;

  /// 한 세션만 크게 본다. null 이면 전체. 클릭 즉시 반영 — 다음 폴링(2초)을 기다리지 않는다.
  /// 이벤트 핸들러에서 부르므로 [_relayout] 을 직접 타도 안전하다(빌드 중이 아니다).
  void setFocus(String? sessionId) {
    if (focus == sessionId) return;
    focus = sessionId;
    _applySessions();
  }

  Iterable<Beast> get beasts => _beasts.values;

  /// 이 마리가 노는 빈터 — 뷰가 원근 스케일(깊이)을 계산할 때 쓴다.
  Clearing? clearingOf(String sessionId) => _byId[sessionId];

  /// 이 마리가 생각 중인가 — 실행 중인데 도구 소식이 [_thinkAfter] 초 없다 = LLM 이
  /// 텍스트를 쓰는 중이다. 머리 위 💭 의 재료(이모트보단 낮고 도구 칩보단 높은 우선순위).
  bool thinking(Beast b) => !b.leaving && clock - b.lastToolAt > _thinkAfter;

  /// 이 세션의 메인이 지금 도는 중이면 그 실행 — 사람 머리 위 도구 칩의 재료.
  /// null = 사람은 서 있지만 조용하다(서브만 돌거나, 메인이 60초 넘게 아무것도 안 썼다).
  AgentRun? mainOf(String sessionId) => _mainOf[sessionId];

  /// 이 세션의 사람이 읽는 제목(최신 ai-title). null = 아직 한 번도 못 봤다 → 세션ID 폴백.
  String? titleOf(String sessionId) => _titleOf[sessionId];

  /// 이 세션 사람을 클릭했을 때 상세를 읽을 메인 실행. null = 이 열이 사는 동안 메인을 한 번도
  /// 라이브로 못 봤다(앱을 팬아웃 도중 열어 메인이 창 밖) → 클릭 비활성, 다음 폴링에 낫는다.
  AgentRun? mainRunOf(String sessionId) => _mainRunOf[sessionId];

  /// 창 크기 변화 — LayoutBuilder 안에서 부른다. **notify 금지**.
  void resize(Size s) {
    if (s == _size) return;
    _size = s;
    _relayout();
  }

  /// 폴링 결과를 맞춘다 — 위치·기분은 그대로 두고 목록만. **notify 금지**.
  void sync(List<AgentRun> runs) {
    // 메인 세션은 사람이라 동물로 만들지 않는다(agentSprite 해시를 타면 안 된다) —
    // 서브와 갈리는 지점은 씬 전체에서 여기 하나뿐이고, 아래는 전부 서브(동물) 얘기다.
    final mains = <String, AgentRun>{};
    final subs = <AgentRun>[];
    for (final r in runs) {
      if (r.agentType == mainAgentType) {
        mains[r.sessionId] = r;
      } else {
        subs.add(r);
      }
    }
    _mainOf = mains;
    for (final r in mains.values) {
      if (r.description.isNotEmpty) _titleOf[r.sessionId] = r.description;
      _mainRunOf[r.sessionId] = r; // 클릭 대상 filePath 확보(창 밖으로 빠져도 남는다)
    }

    // 48 상한. startedAt 오름차순 = 폴링마다 집합이 안 흔들리는 안정 기준.
    final shown = subs..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    hidden = math.max(0, shown.length - _beastMax);
    if (hidden > 0) shown.removeRange(_beastMax, shown.length);

    final live = <String>{};
    for (final r in shown) {
      live.add(r.agentId);
      final b = _beasts[r.agentId];
      if (b == null) {
        // 키는 agentId — 폴링은 매번 새 AgentRun 을 만들어서 객체 동일성으로 맞추면
        // 2초마다 전원이 리셋된다.
        _beasts[r.agentId] = Beast(
          agentId: r.agentId,
          sprite: randomAnimalSprite(_rnd), // 등장마다 새로 섞는다(사용자 요구)
          color: randomAgentColor(_rnd), // 색도 같은 규약 — 종과 독립 추첨
          run: r,
          sessionId: r.sessionId,
        )
          ..seenTools = r.toolCalls.length // 이미 쌓인 이력은 이벤트가 아니다
          ..seenErrors = r.toolCalls.where((t) => t.isError).length
          ..lastToolAt = clock; // 등장 직후 8초 조용하면 💭 — 그것도 사실이다
      } else {
        b.run = r;
        b.sessionId = r.sessionId;
        if (r.toolCalls.length > b.seenTools) {
          // 폴링 사이에 새 도구를 만졌다 — 마지막 것 하나만 팝(여럿이면 최신이 대표).
          b.emote = toolEmote(r.toolCalls.last.name);
          b.emoteAt = clock;
          b.dizzy = false;
          b.lastToolAt = clock;
        }
        b.seenTools = r.toolCalls.length;
        final errs = r.toolCalls.where((t) => t.isError).length;
        if (errs > b.seenErrors) {
          // 실패는 도구 팝보다 나중 검사 — 같은 폴링에 둘 다 오면 실패가 더 중요하다(덮어쓴다).
          b.emote = '😵';
          b.emoteAt = clock;
          b.dizzy = true;
        }
        b.seenErrors = errs;
        // isRunning 은 "마지막 레코드 60초 이내" 추정이라 false↔true 로 튄다 → 다시
        // 나타나면 사라지던 마리를 되살린다(안 그러면 사라졌다 나타난다).
        b.leaving = false;
        b.fade = 1;
        b.celebrateUntil = -1; // 부활 = 축하 취소(끝난 게 아니었다)
      }
    }
    for (final b in _beasts.values) {
      if (!live.contains(b.agentId) && !b.leaving) {
        // 첫 전환에만 축하를 잡는다 — leaving 유지 sync 가 축하를 연장하면 영영 안 사라진다.
        b.leaving = true;
        b.celebrateUntil = clock + celebrateFor;
      }
    }

    // 왕관 — 떠나는 마리는 후보에서 뺀다(왕이 퇴장하면 차순위가 승계). 동률은 startedAt 이
    // 빠른 쪽으로 고정해야 2초 폴링마다 왕관이 둘 사이를 깜빡이지 않는다.
    Beast? king;
    for (final b in _beasts.values) {
      if (b.leaving || b.run.outputTokens <= 0) continue;
      if (king == null ||
          b.run.outputTokens > king.run.outputTokens ||
          (b.run.outputTokens == king.run.outputTokens &&
              b.run.startedAt.isBefore(king.run.startedAt))) {
        king = b;
      }
    }
    crownId = king?.agentId;

    // 열 = 지금 **마리가 있는** 세션 ∪ **메인이 도는** 세션. 사라지는 중(leaving)인 마리도
    // 제 빈터에서 마저 페이드해야 해서 runs 가 아니라 _beasts 에서 뽑는다 — 이 덕에 "모든 마리는
    // 제 빈터를 갖는다" 가 불변식이 된다(마지막 한 마리가 빠진 열은 다음 폴링에 접힌다).
    // 메인을 더하는 게 요구의 핵심이다: 서브 없이 프롬프트만 돌아도(= 동물 0마리) 열이 서고
    // 사람이 캠프에 선다.
    final ids = <String>{
      for (final b in _beasts.values) b.sessionId,
      for (final r in mains.values) r.sessionId,
    };
    _allSessions = ids.toList()..sort(); // readLive 는 mtime 순 → 정렬 안 하면 2초마다 사람이 자리를 바꾼다
    _titleOf.removeWhere((sid, _) => !ids.contains(sid)); // 열이 접히면 제목도 버린다
    _mainRunOf.removeWhere((sid, _) => !ids.contains(sid)); // 제목과 같은 생명주기
    // 보던 세션이 끝났다 — 빈 화면을 들여다보게 두지 않고 전체로 돌려보낸다.
    if (focus != null && !ids.contains(focus)) focus = null;
    _applySessions();
  }

  /// 지금 세울 열을 정한다 — 포커스 중이면 그 세션 하나, 아니면 전체. **notify 금지**
  /// ([sync] 가 빌드 중에 부른다).
  void _applySessions() {
    final sessions = focus == null ? _allSessions : [focus!];
    // 열 구성이 그대로면(대개 그렇다) 열·소품을 다시 계산하지 않는다 — 2초마다 숲이 춤추지 않게.
    // 이미 깔린 것(_byId)과 비교하므로 크기가 0이라 걸러진 레이아웃도 다음 기회에 스스로 낫는다.
    if (sessions.length == _byId.length && sessions.every(_byId.containsKey)) {
      _spawnNew(); // 열 그대로 — 새로 뜬 마리만 세운다
    } else {
      _sessions = sessions;
      _relayout();
    }
  }

  /// 매 프레임 — **유일한 notify**.
  void tick(Duration elapsed) {
    // dt 상한 필수: 창을 숨기면 엔진이 프레임을 끊어(hidden·paused·detached) 복귀 시
    // elapsed 가 수 초 점프한다 → 없으면 전원 순간이동.
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, _maxDt);
    _last = elapsed;
    clock += dt;
    for (final b in _beasts.values) {
      if (b.emote != null && clock - b.emoteAt > emoteFor) {
        b.emote = null;
        b.dizzy = false;
      }
      if (b.leaving) {
        _leave(b, dt); // 빈터 없이도(포커스로 가려진 열) 마저 퇴장한다 — 유령 방지
        continue;
      }
      final c = _byId[b.sessionId];
      if (c != null) _step(b, dt, c);
    }
    _beasts.removeWhere((_, b) => b.leaving && b.fade <= 0);
    notifyListeners();
  }

  /// 퇴장 — 축하(제자리 점프) 뒤 페이드. 빈터를 안 쓴다: 자리를 옮기지 않으니 필요가 없고,
  /// 그 덕에 포커스로 가려진 열의 마리도 안 보이는 채로 마저 사라진다.
  void _leave(Beast b, double dt) {
    if (clock < b.celebrateUntil) {
      // 축하 — 빠른 박자로 제자리 점프, 페이드는 보류(일을 끝낸 마리의 퇴장 인사).
      b.phase = (b.phase + dt * _bobHzChase) % 1.0;
      b.moving = true;
      return;
    }
    b.fade -= dt / _fadeOut;
  }

  void _step(Beast b, double dt, Clearing c) {
    if (b.hovered) {
      b.moving = false; // 호버하면 멈춘다 — 움직이는 걸 툴팁으로 읽을 수 없다
      return;
    }
    if (b.moving) b.phase = (b.phase + dt * b.hopHz) % 1.0;
    if (b.rest > 0) {
      b.rest -= dt;
      b.moving = false;
      return;
    }
    if (b.chaseId != null) {
      // 스냅샷이 아니라 라이브 추적 = 진짜로 쫓아간다
      final t = _beasts[b.chaseId];
      if (t == null || t.leaving) {
        _pick(b, c);
        return;
      }
      b.target = t.pos;
    }
    final d = b.target - b.pos, dist = d.distance;
    if (dist <= b.arrive) {
      if (b.pendingRest > 0) {
        // 캠프 도착 — 예약해 둔 만큼 눌러앉는다(다음 _pick 은 그 뒤에).
        b.rest = b.pendingRest;
        b.pendingRest = 0;
        b.moving = false;
        b.hopHz = 0;
        return;
      }
      _pick(b, c);
      return;
    }
    b.pos += d * (math.min(b.speed * dt, dist) / dist); // min → 오버슛(=떨림) 원천 봉쇄
    b.moving = true;
    b.until -= dt;
    if (b.until <= 0) _pick(b, c); // 안전망: 못 잡는 추격을 6초에 끊는다
  }

  /// 다음 놀이 — 쉬기 20%(그중 [_campChance] 는 캠프까지 걸어가서 쉰다) / 친구 쫓기 25%
  /// (혼자면 어슬렁) / 어슬렁 55%.
  ///
  /// 목표점이 항상 [play](볼록) 안이라 직선 이동은 밖으로 못 나간다 → 경계 반사·클램프 코드가
  /// 통째로 필요 없다. `pos ∈ play` 를 깨는 건 리사이즈뿐이고 그건 [_relayout] 이 잡는다.
  void _pick(Beast b, Clearing c) {
    b.chaseId = null;
    b.pendingRest = 0; // 캠프로 가다 재추첨(_repick)되면 예약도 버린다 — 아무 데서나 눌러앉지 않게
    final r = _rnd.nextDouble();
    if (r < _campChance) {
      // 캠프 모임 — 제 사람 곁으로 걸어가 오래 쉰다. 여럿이 겹치면 모닥불 그림이 된다.
      b
        ..target = campSpot(c, _rnd)
        ..speed = _speedWander + _rnd.nextDouble() * _speedWanderVar
        ..hopHz = _bobHzWander
        ..arrive = _arriveWander
        ..until = _repick
        ..moving = true
        ..pendingRest = _campRestMin + _rnd.nextDouble() * _campRestVar;
      return;
    }
    if (r < 0.20) {
      b.moving = false;
      b.hopHz = 0;
      b.rest = _restMin + _rnd.nextDouble() * _restVar;
      return;
    }
    if (r < 0.45) {
      final friends = [
        for (final o in _beasts.values)
          if (!o.leaving && o.agentId != b.agentId && o.sessionId == b.sessionId) o
      ];
      if (friends.isNotEmpty) {
        final t = friends[_rnd.nextInt(friends.length)];
        b
          ..chaseId = t.agentId
          ..target = t.pos
          ..speed = _speedChase + _rnd.nextDouble() * _speedChaseVar
          ..hopHz = _bobHzChase
          ..arrive = _arriveChase
          ..until = _repick
          ..moving = true;
        return;
      }
    }
    b
      ..target = Offset(c.play.left + _rnd.nextDouble() * c.play.width,
          c.play.top + _rnd.nextDouble() * c.play.height)
      ..speed = _speedWander + _rnd.nextDouble() * _speedWanderVar
      ..hopHz = _bobHzWander
      ..arrive = _arriveWander
      ..until = _repick
      ..moving = true;
  }

  /// 새로 뜬 마리는 제 사람 발밑에서 튀어나온다 — "이 세션이 얘를 띄웠다" 가 공짜 서사.
  void _spawnNew() {
    for (final b in _beasts.values) {
      if (b.placed) continue;
      final c = _byId[b.sessionId];
      if (c == null) continue; // 아직 레이아웃 전 — 첫 resize 가 다시 부른다
      b.pos = c.personFeet +
          Offset((_rnd.nextDouble() - 0.5) * _spawnJitter * 2,
              _rnd.nextDouble() * _spawnJitter);
      b.phase = _rnd.nextDouble(); // 같이 튀어나온 마리들이 한 박자로 뛰지 않게
      b.placed = true;
      _pick(b, c);
    }
  }

  /// 열·사람 앵커·소품 재계산 + `pos ∈ play` 복구. 리사이즈/세션 변화에서만.
  void _relayout() {
    final n = _sessions.length;
    if (n == 0 || _size.isEmpty) {
      clearings = const [];
      floor = const [];
      back = const [];
      _byId.clear();
      sceneW = 0;
      colW = 0;
      return;
    }
    sceneW = math.max(_size.width, n * _minColW); // 좁으면 씬을 넓히고 가로 스크롤
    colW = sceneW / n;
    final feetY = (_size.height * 0.26).clamp(76.0, 120.0);
    final cs = <Clearing>[];
    final fl = <SceneProp>[], bk = <SceneProp>[];
    for (int i = 0; i < n; i++) {
      final sid = _sessions[i]; // 시드 = sessionId(불변) — project 시드는 폴링마다 숲을 재배치한다
      final colLeft = colW * i;
      final personFeet = Offset(colW * (i + 0.5), feetY);
      final play = Rect.fromLTRB(
        colLeft + _padX,
        feetY + _playTopGap,
        colLeft + colW - _padX,
        math.max(feetY + _playTopGap + 60, _size.height - _playPadBottom),
      );
      cs.add(Clearing(
        sessionId: sid,
        sprite: personSprite(sid),
        personFeet: personFeet,
        play: play,
      ));

      // 1) 뒷숲 — 열을 슬롯으로 쪼개 칸마다 1개(해시로 그냥 뿌리면 뭉친다). 거절 샘플링 없음 = 무한루프 0.
      final slots = (colW / 120).round().clamp(3, 8);
      for (int k = 0; k < slots; k++) {
        final sx = colLeft +
            20 +
            (colW - 40) * (k + .5) / slots +
            (_sceneRand(sid, 100 + k * 3) - .5) * 30;
        if ((sx - personFeet.dx).abs() < 96) continue; // 캠프 자리는 비운다 = 빈터 입구
        final kind = _backKinds[_sceneHash(sid, 101 + k * 3) % _backKinds.length];
        // 발밑 y ∈ [feetY*0.66, feetY*0.96] — 이보다 위면 132px 나무의 우듬지가 씬 밖으로 잘린다.
        bk.add(SceneProp(
          kind,
          Offset(sx, feetY * (0.66 + _sceneRand(sid, 102 + k * 3) * 0.30)),
          propSize[kind]!,
        ));
      }

      // 2) 캠프 — 해시 안 씀. 모든 세션이 같은 모양이어야 '캠프' 라는 기호로 읽힌다.
      fl.add(SceneProp('forest-patch-dirt', personFeet - const Offset(0, 4), 88, flat: true));
      bk.add(SceneProp('forest-tent', personFeet + const Offset(-56, -2), 84));
      bk.add(SceneProp('forest-flag', personFeet + const Offset(46, 0), 72));

      // 3) 바닥 얼룩 + 소형 장식 — 놀이터 안엔 납작하거나 아주 작은 것만(세로 소품은 전부
      //    놀이터 밖이라 소품↔동물 y-sort 가 아예 필요 없다 = 배경을 정적 레이어로 격리).
      final m = (play.width * play.height / 26000).round().clamp(3, 9);
      for (int k = 0; k < m; k++) {
        final kind = _sceneRand(sid, 300 + k * 3) < 0.72
            ? 'forest-patch-grass'
            : 'forest-patch-dirt';
        fl.add(SceneProp(kind, _inPlay(sid, play, 301 + k * 3), propSize[kind]!, flat: true));
      }
      final q = (play.width / 240).round().clamp(2, 4);
      for (int k = 0; k < q; k++) {
        final kind =
            _sceneRand(sid, 500 + k * 3) < 0.5 ? 'forest-plant' : 'forest-stones';
        bk.add(SceneProp(kind, _inPlay(sid, play, 501 + k * 3), propSize[kind]!));
      }
    }
    clearings = cs;
    floor = fl;
    back = bk;
    _byId
      ..clear()
      ..addEntries(cs.map((c) => MapEntry(c.sessionId, c)));

    for (final b in _beasts.values) {
      final c = _byId[b.sessionId];
      if (c == null || !b.placed) continue;
      b.pos = Offset(b.pos.dx.clamp(c.play.left, c.play.right),
          b.pos.dy.clamp(c.play.top, c.play.bottom));
      b.until = 0; // 전원 즉시 재추첨 — 목표가 새 빈터 밖에 남으면 가장자리에 붙어 선다
    }
    _spawnNew();
  }

  /// [play] 안의 결정론 좌표 — [salt], [salt]+1 두 개를 쓴다.
  Offset _inPlay(String sid, Rect play, int salt) => Offset(
        play.left + _sceneRand(sid, salt) * play.width,
        play.top + _sceneRand(sid, salt + 1) * play.height,
      );
}
