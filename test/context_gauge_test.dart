import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar/domain/models/context_gauge.dart';

/// 테스트용 게이지 한 개.
ContextGauge _g({required int window, required int used, int? pct}) =>
    ContextGauge(
      sessionId: 's',
      usedTokens: used,
      windowSize: window,
      pctOverride: pct,
      updatedAt: DateTime(2026, 7, 17),
    );

void main() {
  group('tokensOf — CC 의 Lwe() 합산식', () {
    test('네 필드를 모두 더한다(output 포함)', () {
      // 실제 세션 로그에서 뽑은 usage.
      expect(
        ContextGauge.tokensOf(const {
          'input_tokens': 2,
          'cache_creation_input_tokens': 6010,
          'cache_read_input_tokens': 57587,
          'output_tokens': 1526,
        }),
        2 + 6010 + 57587 + 1526,
      );
    });

    test('캐시 필드가 없으면 0 으로 본다', () {
      expect(
        ContextGauge.tokensOf(const {'input_tokens': 100, 'output_tokens': 5}),
        105,
      );
    });
  });

  group('compactThreshold', () {
    test('기본은 윈도우 - 13000 (퍼센트가 아니다)', () {
      expect(_g(window: 200000, used: 0).compactThreshold, 187000);
    });

    test('pct override 가 있으면 둘 중 작은 쪽', () {
      expect(_g(window: 1000000, used: 0, pct: 70).compactThreshold, 700000);
    });

    test('pct 가 커도 예약분 13000 은 못 넘는다', () {
      expect(_g(window: 200000, used: 0, pct: 99).compactThreshold, 187000);
    });

    test('범위 밖 pct 는 무시하고 기본값', () {
      expect(_g(window: 200000, used: 0, pct: 0).compactThreshold, 187000);
      expect(_g(window: 200000, used: 0, pct: 101).compactThreshold, 187000);
    });
  });

  group('remainingPercent — CC 툴팁과 같은 숫자', () {
    test('스크린샷 케이스: 1M 윈도우 / override 70 / 574k 사용 → 18% 남음', () {
      expect(_g(window: 1000000, used: 574000, pct: 70).remainingPercent, 18);
    });

    test('빈 세션은 100% 남음', () {
      expect(_g(window: 200000, used: 0).remainingPercent, 100);
    });

    test('임계값을 넘으면 0 에서 바닥친다(음수 금지)', () {
      expect(_g(window: 200000, used: 999999).remainingPercent, 0);
    });

    test('전체 윈도우가 아니라 임계값이 분모다', () {
      // 1M/70 → 임계값 700k. 500k 사용 시 윈도우 기준이면 50% 남음이지만,
      // auto-compact 기준으로는 29% 남음이어야 한다.
      expect(_g(window: 1000000, used: 500000, pct: 70).remainingPercent, 29);
    });
  });

  group('filledFraction — 게이지 채움', () {
    test('절반 쓰면 0.5', () {
      expect(
        _g(window: 213000, used: 100000).filledFraction,
        closeTo(0.5, 1e-9),
      );
    });

    test('0..1 로 잘린다', () {
      expect(_g(window: 200000, used: 999999).filledFraction, 1.0);
    });
  });
}
