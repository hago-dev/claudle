/// 큰 토큰 수를 메뉴바용으로 짧게: 1234 → 1.2K, 1.2e6 → 1.2M, 3.6e9 → 3.6B.
String compactTokens(int n) {
  final a = n.abs();
  if (a >= 1000000000) return '${(n / 1e9).toStringAsFixed(a >= 1e10 ? 0 : 1)}B';
  if (a >= 1000000) return '${(n / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1)}M';
  if (a >= 1000) return '${(n / 1e3).toStringAsFixed(a >= 1e4 ? 0 : 1)}K';
  return '$n';
}

/// $8.14 / $1.2K (비용).
String money(double v) {
  if (v.abs() >= 10000) return '\$${(v / 1000).toStringAsFixed(1)}K';
  return '\$${v.toStringAsFixed(2)}';
}

/// 남은 시간 압축: 6m / 2h 14m / 3d 5h. 음수/null → '0m'.
String compactDuration(Duration? d) {
  if (d == null || d.isNegative) return '0m';
  final days = d.inDays;
  final h = d.inHours % 24;
  final m = d.inMinutes % 60;
  if (days > 0) return '${days}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

const _weekdaysKo = ['월', '화', '수', '목', '금', '토', '일'];

/// 재설정 시각을 한글로: "(일) 오후 6:59".
String resetClockKo(DateTime t) {
  final wd = _weekdaysKo[t.weekday - 1];
  final ampm = t.hour < 12 ? '오전' : '오후';
  var h12 = t.hour % 12;
  if (h12 == 0) h12 = 12;
  final mm = t.minute.toString().padLeft(2, '0');
  return '($wd) $ampm $h12:$mm';
}
