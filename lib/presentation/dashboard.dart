import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../core/db/usage_database.dart';
import '../core/util/format.dart';
import '../domain/models/subscription_limits.dart';

/// 상세 대시보드 창: 오늘/전체 요약 + 일별 막대 + 모델/프로젝트 순위.
///
/// 총계 노티파이어를 트리거로 DB 집계 쿼리를 다시 읽는다(로컬 25k행, sub-ms).
class DashboardScreen extends StatelessWidget {
  final AppController controller;
  const DashboardScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Claudle 🐩'),
        actions: [
          ValueListenableBuilder<String>(
            valueListenable: controller.status,
            builder: (_, s, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(s, style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ⭐ 헤드라인: 구독 사용량 한도(스샷 패널 재현).
          ValueListenableBuilder<SubscriptionLimits?>(
            valueListenable: controller.limits,
            builder: (_, lim, _) => _LimitsPanel(limits: lim),
          ),
          const SizedBox(height: 20),
          // 보조: 기간별 토큰/비용 집계.
          _UsageBreakdown(controller: controller),
        ],
      ),
    );
  }
}

/// 조회 기간 프리셋. [fromMs] = 하한 epoch ms(로컬), null = 전체.
/// custom 은 별도 [DateTimeRange] 로 상·하한을 지정(fromMs 미사용).
enum _Period {
  today('오늘'),
  week('7일'),
  month('30일'),
  all('전체'),
  custom('기간');

  const _Period(this.label);
  final String label;

  int? fromMs() {
    final now = DateTime.now();
    switch (this) {
      case _Period.today:
        return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
      case _Period.week:
        return now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
      case _Period.month:
        return now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
      case _Period.all:
      case _Period.custom:
        return null;
    }
  }
}

/// 기간 선택 + 그 기간의 요약/모델별/프로젝트별 집계.
/// 총계 변화·revision(별칭)엔 [AnimatedBuilder], 기간 선택엔 [setState] 로 리빌드.
class _UsageBreakdown extends StatefulWidget {
  final AppController controller;
  const _UsageBreakdown({required this.controller});

  @override
  State<_UsageBreakdown> createState() => _UsageBreakdownState();
}

class _UsageBreakdownState extends State<_UsageBreakdown> {
  _Period _sel = _Period.today;
  DateTimeRange? _range; // custom 기간(선택 시)

  /// (fromMs, toMs) — custom 이면 [start자정, end+1일자정), 프리셋이면 (fromMs, null).
  (int?, int?) _bounds() {
    if (_sel == _Period.custom && _range != null) {
      final s = _range!.start, e = _range!.end;
      final from = DateTime(s.year, s.month, s.day).millisecondsSinceEpoch;
      final to = DateTime(e.year, e.month, e.day)
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch; // end 포함 → 다음날 자정 미만
      return (from, to);
    }
    return (_sel.fromMs(), null);
  }

  String get _label => (_sel == _Period.custom && _range != null)
      ? '${_range!.start.month}/${_range!.start.day}~${_range!.end.month}/${_range!.end.day}'
      : _sel.label;

  void _onPreset(_Period p) => setState(() => _sel = p);

  /// 📅 버튼: 매 탭마다 날짜 범위 피커를 연다(저장 후 다시 눌러도 재열림).
  /// 이전 범위를 initialDateRange 로 넘겨 이어서 수정 가능.
  Future<void> _openPicker() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange: _range ??
          DateTimeRange(
              start: now.subtract(const Duration(days: 7)), end: now),
    );
    // 취소하면 기존 선택 유지.
    if (picked != null) {
      setState(() {
        _sel = _Period.custom;
        _range = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation:
          Listenable.merge([controller.totalsAll, controller.revision]),
      builder: (context, _) {
        final all = controller.totalsAll.value;
        if (all == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('토큰 집계 중…')),
          );
        }
        final db = controller.db;
        final (fromMs, toMs) = _bounds();
        final periodTotals = db.totalsBetween(fromMs: fromMs, toMs: toMs);
        final daily = db.dailyBuckets(days: 14);
        final models = db.byModel(limit: 8, fromMs: fromMs, toMs: toMs);
        final projects = db.byProject(limit: 8, fromMs: fromMs, toMs: toMs);
        return Column(
          children: [
            _PeriodSelector(
              selected: _sel,
              customActive: _sel == _Period.custom,
              customLabel: _sel == _Period.custom ? _label : null,
              onPreset: _onPreset,
              onCustom: _openPicker,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                    child: _TotalsCard(title: _label, totals: periodTotals)),
                const SizedBox(width: 12),
                Expanded(child: _TotalsCard(title: '전체', totals: all)),
              ],
            ),
            const SizedBox(height: 20),
            _Section(
              title: '일별 비용 (최근 14일)',
              child: SizedBox(height: 160, child: _DailyBars(daily)),
            ),
            const SizedBox(height: 20),
            _Section(title: '모델별 · $_label', child: _RankedBars(models)),
            const SizedBox(height: 20),
            _Section(
              title: '프로젝트별 · $_label  (탭하면 이름 변경)',
              child: _RankedBars(
                projects,
                onRename: (row) => _renameProject(context, row),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 프로젝트 표시명(별칭) 변경 다이얼로그. 저장 시 내장 저장소에 기록 후 리빌드.
  Future<void> _renameProject(BuildContext context, GroupRow row) async {
    final ctrl = TextEditingController(text: row.label);
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('프로젝트 이름 변경'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '표시할 이름 (비우면 원래 프로젝트명)',
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('저장')),
          ],
        ),
      );
      if (result != null) {
        widget.controller.db.setAlias(row.key, result);
        widget.controller.bumpRevision();
      }
    } finally {
      ctrl.dispose(); // 다이얼로그가 던지거나 닫혀도 반드시 해제.
    }
  }
}

/// 기간 선택: [오늘][7일][30일][전체] 세그먼트 + **항상 눌러 여는** 📅 커스텀 버튼.
/// (📅 를 세그먼트로 두면 이미 선택된 상태에서 재탭 시 콜백이 안 와 피커가 안 열림 →
///  별도 버튼으로 분리해 저장 후 재클릭에도 달력이 다시 열리게 한다.)
class _PeriodSelector extends StatelessWidget {
  final _Period selected; // 프리셋 선택(customActive 면 하이라이트 없음)
  final bool customActive;
  final String? customLabel; // "M/d~M/d"
  final ValueChanged<_Period> onPreset;
  final VoidCallback onCustom; // 매 탭마다 피커 열기
  const _PeriodSelector({
    required this.selected,
    required this.customActive,
    required this.customLabel,
    required this.onPreset,
    required this.onCustom,
  });

  static const _presets = [
    _Period.today,
    _Period.week,
    _Period.month,
    _Period.all,
  ];

  @override
  Widget build(BuildContext context) {
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    final btnStyle = ButtonStyle(
      visualDensity: VisualDensity.compact,
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12)),
      shape: WidgetStatePropertyAll(shape),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<_Period>(
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          style: btnStyle,
          segments: [
            for (final p in _presets)
              ButtonSegment(value: p, label: Text(p.label)),
          ],
          selected: customActive ? const <_Period>{} : {selected},
          onSelectionChanged: (s) {
            if (s.isNotEmpty) onPreset(s.first);
          },
        ),
        customActive
            ? FilledButton.tonalIcon(
                onPressed: onCustom,
                style: btnStyle,
                icon: const Icon(Icons.event, size: 15),
                label: Text(customLabel ?? '기간'),
              )
            : OutlinedButton.icon(
                onPressed: onCustom,
                style: btnStyle,
                icon: const Icon(Icons.event, size: 15),
                label: const Text('기간'),
              ),
      ],
    );
  }
}

/// 구독 사용량 한도 패널 — Claude Code `/usage` 화면 재현.
class _LimitsPanel extends StatelessWidget {
  final SubscriptionLimits? limits;
  const _LimitsPanel({required this.limits});

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
                Text('플랜 사용량 한도',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 10),
                Text(lim?.planLabel ?? '—',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 16),
            if (lim == null)
              const Text('한도 조회 중…')
            else ...[
              _LimitRow(
                bucket: lim.session,
                subtitle: _sessionSubtitle(lim.session),
              ),
              const SizedBox(height: 18),
              Text('주간 한도',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              for (final b in lim.weekly) ...[
                _LimitRow(bucket: b, subtitle: _weeklySubtitle(b)),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              Text('마지막 업데이트: ${_ago(lim.fetchedAt)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white38)),
            ],
          ],
        ),
      ),
    );
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
    final barColor =
        warn ? Colors.orangeAccent : Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bucket.label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.white54)),
                ],
              ),
            ),
            Text('${bucket.usedPercent}% 사용됨',
                style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()])),
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

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  final String title;
  final UsageTotals? totals;
  const _TotalsCard({required this.title, required this.totals});

  @override
  Widget build(BuildContext context) {
    final t = totals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (t == null)
              const Text('—')
            else ...[
              Text(compactTokens(t.totalTokens),
                  style: Theme.of(context).textTheme.headlineSmall),
              Text('tokens', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Text(money(t.costUsd),
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: Colors.greenAccent)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 일별 비용 막대 그래프.
class _DailyBars extends StatelessWidget {
  final List<DayBucket> data;
  const _DailyBars(this.data);

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const Center(child: Text('데이터 없음'));
    final maxCost =
        data.map((d) => d.cost).fold<double>(0, (a, b) => b > a ? b : a);
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxCost <= 0 ? 1 : maxCost * 1.15,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, _) => BarTooltipItem(
              '${data[group.x].day.substring(5)}\n${money(rod.toY)}',
              const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= data.length) return const SizedBox();
                // 이틀 간격으로만 라벨(겹침 방지). 'MM-DD' → 'DD'.
                if (i % 2 != 0) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(data[i].day.substring(8),
                      style: const TextStyle(fontSize: 10)),
                );
              },
            ),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (int i = 0; i < data.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: data[i].cost,
                  width: 12,
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.tertiary,
                    ],
                  ),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(2)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 모델/프로젝트 순위 — 비용 비례 막대 + 토큰/비용 수치.
/// [onRename] 있으면 행을 탭해 별칭 지정(프로젝트별에서 사용).
class _RankedBars extends StatelessWidget {
  final List<GroupRow> rows;
  final void Function(GroupRow row)? onRename;
  const _RankedBars(this.rows, {this.onRename});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text('데이터 없음');
    final maxCost =
        rows.map((r) => r.cost).fold<double>(0, (a, b) => b > a ? b : a);
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [for (final r in rows) _row(context, r, maxCost, scheme)]);
  }

  Widget _row(
      BuildContext context, GroupRow r, double maxCost, ColorScheme scheme) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Row(
              children: [
                Flexible(
                  child: Text(r.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ),
                if (onRename != null) ...[
                  const SizedBox(width: 3),
                  Icon(Icons.edit,
                      size: 11,
                      color: scheme.onSurface.withValues(alpha: 0.3)),
                ],
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 16,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: maxCost <= 0 ? 0 : (r.cost / maxCost),
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [scheme.primary, scheme.tertiary]),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(money(r.cost),
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            width: 56,
            child: Text(compactTokens(r.tokens),
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.5))),
          ),
        ],
      ),
    );
    if (onRename == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => onRename!(r),
      child: content,
    );
  }
}
