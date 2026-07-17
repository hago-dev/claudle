import 'package:flutter/material.dart';

import '../core/util/format.dart';
import '../domain/models/context_gauge.dart';

/// 컨텍스트 소진도 에너지바 — auto-compact 까지 빨간 게이지가 찬다.
///
/// 채움/남은%는 [ContextGauge] 가 계산한다(여기선 그리기만).
class ContextGaugeBar extends StatelessWidget {
  final ContextGauge? gauge;

  /// 게이지가 없을 때 보여줄 안내(왜 비었는지).
  final String? hint;

  /// 훅을 깔 수 있으면 콜백. null 이면 버튼을 숨긴다.
  final VoidCallback? onEnable;

  const ContextGaugeBar({
    super.key,
    required this.gauge,
    this.hint,
    this.onEnable,
  });

  /// 눈금 칸 수(레트로 에너지바 느낌).
  static const int _segments = 24;

  @override
  Widget build(BuildContext context) {
    final g = gauge;
    if (g == null) return _GaugeHint(hint: hint, onEnable: onEnable);

    final fill = g.filledFraction;
    final hot = fill >= 0.85;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(hot ? '🥵' : '🐩', style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            const Text('컨텍스트', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(
              '${g.remainingPercent}% 남음',
              style: TextStyle(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
                color: hot ? Colors.redAccent : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Bar(fill: fill, hot: hot),
        const SizedBox(height: 6),
        Text(
          '${compactTokens(g.usedTokens)} / ${compactTokens(g.compactThreshold)} · auto-compact 까지',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.white54),
        ),
      ],
    );
  }
}

/// 숲의 캐릭터 머리 위(이름표 줄)에 다는 초소형 게이지.
///
/// 이름표와 **같은 줄**에 들어가야 한다 — 줄을 하나 더 얹으면 열 머리가 씬 밖으로
/// 나가 잘린다(`forest_scene_view.dart` 의 경고 참조).
class ContextGaugeMiniBar extends StatelessWidget {
  final ContextGauge gauge;
  const ContextGaugeMiniBar({super.key, required this.gauge});

  @override
  Widget build(BuildContext context) {
    final fill = gauge.filledFraction;
    final hot = fill >= 0.85;
    return Tooltip(
      message: '컨텍스트 ${gauge.remainingPercent}% 남음 · auto-compact 까지',
      child: Container(
        width: 34,
        height: 7,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(3.5),
          border: Border.all(color: Colors.white24, width: 0.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3.5),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: fill),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            builder: (_, v, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: v,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: hot
                        ? const [Color(0xFFFF5252), Color(0xFFB71C1C)]
                        : const [Color(0xFFFF8A65), Color(0xFFD32F2F)],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 알약 모양 게이지 + 눈금. 차오를수록 붉어지고, 임박하면 빛난다.
class _Bar extends StatelessWidget {
  final double fill;
  final bool hot;
  const _Bar({required this.fill, required this.hot});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 16,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
        boxShadow: hot
            ? [
                BoxShadow(
                  color: Colors.redAccent.withValues(alpha: 0.45),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fill),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => FractionallySizedBox(
                key: const ValueKey('context-gauge-fill'),
                alignment: Alignment.centerLeft,
                widthFactor: v,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFFFF8A65), Color(0xFFD32F2F)],
                    ),
                  ),
                ),
              ),
            ),
            // 눈금: 칸을 나눠 에너지바처럼.
            Row(
              children: List.generate(
                ContextGaugeBar._segments,
                (_) => Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(
                        right: BorderSide(color: Colors.black26, width: 1),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// statusline 훅이 없으면 게이지를 못 그린다 — 왜 비었는지 알리고, 켤 수 있으면 켠다.
class _GaugeHint extends StatelessWidget {
  final String? hint;
  final VoidCallback? onEnable;
  const _GaugeHint({this.hint, this.onEnable});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('🐩', style: TextStyle(fontSize: 14)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            hint ?? '컨텍스트 게이지 대기 중',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white54),
          ),
        ),
        if (onEnable != null) ...[
          const SizedBox(width: 12),
          FilledButton.tonal(onPressed: onEnable, child: const Text('게이지 켜기')),
        ],
      ],
    );
  }
}
