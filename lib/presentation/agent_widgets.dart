import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/util/format.dart';
import '../domain/models/agent_run.dart';
import 'forest_scene.dart';

// ── 에이전트 화면의 공유 조각 ─────────────────────────────────
//
// 기록 탭(카드·재생)·상세 시트·숲 씬 뷰가 **모두** 쓰는 것만 여기 둔다. 한 곳에서만 쓰는
// 위젯은 그 파일에 private 로 남긴다(`_ToolStrip` = 카드, `_ToolChip` = 숲 뷰).
//
// public 인 이유는 하나뿐이다 — 파일이 갈려서. 세 화면이 같은 스프라이트·같은 도구 아이콘·
// 같은 시간 포맷을 써야 "같은 앱" 으로 읽히므로 복제하지 않고 공유한다.

/// 스프라이트 한 마리 — 정지 PNG(64x64)를 [phase] 로 통통 튀게. 걷기 프레임이 없으니
/// 작업 중([running])일 때만 바닥에서 콩콩 뛰고(Y −4~0px), 살짝 기운다. 끝나면 정지.
/// 저폴리라 [FilterQuality.none](nearest) 이 확대해도 뭉개지지 않고 각지게 유지된다.
/// [sprite] 는 `assets/agents/<sprite>.png` 의 basename — 동물(`animal-fox`)이든
/// 사람(`character-male-a`)이든 같은 위젯이 그린다. 사람(부모)은 호출부에서 `running:false` 로 정지.
class Critter extends StatelessWidget {
  final String sprite;
  final double phase; // 0..1 — 애니메이션 위상
  final bool running;
  final double size;

  const Critter({
    super.key,
    required this.sprite,
    required this.phase,
    required this.running,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    final t = phase * 2 * math.pi;
    // -abs(sin) → 위로만 튄다(바닥이 0). 한 바퀴에 콩콩 두 번.
    final bob = running ? -hopWave(phase) * 4 : 0.0;
    final tilt = running ? math.sin(t) * 0.05 : 0.0; // 뛸 때 좌우로 살짝
    return Transform.translate(
      offset: Offset(0, bob),
      child: Transform.rotate(
        angle: tilt,
        // fit 필수 — 기본값 BoxFit.scaleDown 은 확대를 안 해서 64px 원본이 그보다 큰
        // 박스에서 64px 로 박힌다. 지금은 48~64px 라 티가 안 나지만, 크기를 키우는 순간
        // 조용히 상한에 걸린다(소품에서 실제로 터졌던 버그).
        child: Image.asset(
          'assets/agents/$sprite.png',
          width: size,
          height: size,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.none,
        ),
      ),
    );
  }
}

/// 타입 배지 — 카드 머리와 상세 시트가 같이 쓴다.
class TypeBadge extends StatelessWidget {
  final String agentType;

  /// 배지 색 강제 — 라이브 시트가 클릭한 마리의 랜덤 색을 시트 전체와 맞출 때.
  /// null = 타입색([agentColor], 기록 쪽 기본).
  final Color? color;
  const TypeBadge({super.key, required this.agentType, this.color});

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? agentColor(agentType);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        // 메인은 카테고리가 아니라 '그 세션(사람)' 이다 — 'main' 원문 대신 사람 말로.
        agentType == mainAgentType ? '세션' : agentType,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 도구 한 줄 — 아이콘 + 이름 + 무엇을 만졌는지. 카드의 "지금 하는 일" 과 상세 로그가 같이 쓴다.
class ToolLine extends StatelessWidget {
  final ToolCall tool;
  final Color color;

  const ToolLine({super.key, required this.tool, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(toolIcon(tool.name), size: 12, color: color),
        const SizedBox(width: 5),
        Text(
          tool.name,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color),
        ),
        if (tool.detail.isNotEmpty) ...[
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              tool.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis, // 긴 인자(명령줄 등)는 말줄임
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 도구 → 아이콘. 실측 분포(Bash·Read·StructuredOutput·Edit·Write·Grep…) 기준.
/// 이모지 판본은 [toolEmote](forest_scene.dart) — 도구명 규약이 같아야 한다.
IconData toolIcon(String tool) {
  if (tool.startsWith('mcp__')) return Icons.extension;
  switch (tool) {
    case 'Bash':
    case 'bash':
    case 'BashOutput':
      return Icons.terminal;
    case 'Read':
      return Icons.description_outlined;
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
      return Icons.edit_outlined;
    case 'Grep':
    case 'Glob':
    case 'ToolSearch':
      return Icons.search;
    case 'Task':
      return Icons.hub_outlined;
    case 'WebFetch':
    case 'WebSearch':
      return Icons.language;
    case 'TodoWrite':
      return Icons.checklist;
    case 'StructuredOutput':
      return Icons.data_object;
    default:
      return Icons.circle;
  }
}

// ── 포맷 ───────────────────────────────────────────────────

/// 씬 발밑 이름표 — 이 마리가 받은 지시를 짧게. 없으면(워크플로우 라이브는 description 이
/// 프롬프트 꼬리라 대개 있다) 타입으로 폴백. 셀이 104px 라 [labelMaxChars] 자에서 자른다.
String actionLabel(AgentRun run) {
  final desc = run.description.trim();
  final base = desc.isEmpty ? run.agentType : desc;
  return base.characters.length > labelMaxChars
      ? '${base.characters.take(labelMaxChars)}…'
      : base;
}

/// 에이전트 소요시간은 대부분 분 미만이라 [compactDuration] 은 죄다 '0m' 이 된다 → 초까지.
String elapsed(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return compactDuration(d);
}

/// `-Users-me-Desktop-project-tokenbar` → `tokenbar`.
/// 단순화: 인코딩 경로의 마지막 세그먼트만 — 이름에 '-' 가 든 프로젝트는 잘려 보인다.
/// 필요 시 대시보드의 별칭(usage DB `setAlias`)과 연결.
String projectLabel(String encoded) {
  final parts = encoded.split('-').where((s) => s.isNotEmpty);
  return parts.isEmpty ? encoded : parts.last;
}
