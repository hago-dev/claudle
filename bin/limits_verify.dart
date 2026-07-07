// P8-4 검증: 실제 usage 엔드포인트에서 세션/주간/Fable 한도를 뽑아 출력.
// 앱과 동일 경로(키체인 토큰 → GET /api/oauth/usage → limits[] 파싱).
// 출력값을 Claude Code /usage 패널과 대조. 실행: fvm dart run bin/limits_verify.dart
import 'package:tokenbar/data/limits/real_limits_source.dart';

Future<void> main() async {
  final src = RealLimitsSource();
  print('available: ${await src.isAvailable()}');
  try {
    final lim = await src.fetch();
    if (lim == null) {
      print('결과 없음(null)');
      return;
    }
    print('플랜: ${lim.planLabel}');
    final s = lim.session;
    print('현재 세션: ${s.usedPercent}% · 재설정 ${s.resetsAt?.toLocal()}');
    for (final w in lim.weekly) {
      print('주간 ${w.label}: ${w.usedPercent}% · 재설정 ${w.resetsAt?.toLocal()}');
    }
    print('fetchedAt: ${lim.fetchedAt}');
  } catch (e) {
    print('실패: $e');
  }
}
