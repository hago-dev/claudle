import 'package:flutter/material.dart';

import '../core/util/format.dart';
import '../domain/models/subscription_limits.dart';

/// 구독 사용량 한도 패널 — Claude Code `/usage` 화면 재현.
///
/// [limits] 가 null 이면 아직 못 불러온 것. 이때 [status] 로 **왜** 못 불러왔는지
/// 보여준다 — 실패해도 "조회 중…"에 갇히면 사용자는 멈춘 건지 실패한 건지 모른다
/// (실제로 HTTP 429 를 조용히 삼켜 "안 나온다"는 오인을 낳았다).
class LimitsPanel extends StatelessWidget {
  final SubscriptionLimits? limits;

  /// [LimitsController.status] — '한도 갱신됨' / '한도 조회 실패: HTTP 429' 등.
  final String status;

  const LimitsPanel({super.key, required this.limits, required this.status});

  bool get _isError => status.contains('실패') || status.contains('없음');

  @override
  Widget build(BuildContext context) {
    final lim = limits;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '플랜 사용량 한도',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 10),
                Text(
                  lim?.planLabel ?? '—',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (lim == null)
              _placeholder(context)
            else ...[
              _LimitRow(
                bucket: lim.session,
                subtitle: _sessionSubtitle(lim.session),
              ),
              const SizedBox(height: 18),
              Text('주간 한도', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              for (final b in lim.weekly) ...[
                _LimitRow(bucket: b, subtitle: _weeklySubtitle(b)),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              Text(
                '마지막 업데이트: ${_ago(lim.fetchedAt)}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white38),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 아직 못 불러온 상태 — 실패면 사유를, 진행 중이면 조회 중을 보여준다.
  Widget _placeholder(BuildContext context) {
    if (_isError) {
      return Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Colors.orangeAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.orangeAccent),
            ),
          ),
        ],
      );
    }
    return const Text('한도 조회 중…');
  }

  static String _sessionSubtitle(LimitBucket b) {
    if (b.resetsAt == null) return '';
    final left = compactDuration(b.resetsAt!.difference(DateTime.now()));
    return '$left 후 재설정';
  }

  static String _weeklySubtitle(LimitBucket b) =>
      b.resetsAt == null ? '' : '${resetClockKo(b.resetsAt!.toLocal())}에 재설정';

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '방금';
    if (d.inMinutes < 60) return '${d.inMinutes}분 전';
    return '${d.inHours}시간 전';
  }
}

/// 한도 한 줄: 라벨 + 부제(재설정) + 진행바 + % 사용됨.
class _LimitRow extends StatelessWidget {
  final LimitBucket bucket;
  final String subtitle;
  const _LimitRow({required this.bucket, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final pct = bucket.usedFraction.clamp(0.0, 1.0);
    final warn = pct >= 0.8;
    final barColor = warn
        ? Colors.orangeAccent
        : Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bucket.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white54),
                    ),
                ],
              ),
            ),
            Text(
              '${bucket.usedPercent}% 사용됨',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation(barColor),
          ),
        ),
      ],
    );
  }
}
