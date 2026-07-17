import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar/domain/models/context_gauge.dart';
import 'package:tokenbar/presentation/context_gauge_bar.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 400, child: child)),
);

ContextGauge _gauge({required int used}) => ContextGauge(
  sessionId: 's',
  usedTokens: used,
  windowSize: 1000000,
  pctOverride: 70,
  updatedAt: DateTime(2026, 7, 17),
);

void main() {
  testWidgets('남은 %를 보여준다', (tester) async {
    await tester.pumpWidget(
      _wrap(ContextGaugeBar(gauge: _gauge(used: 574000))),
    );
    expect(find.text('18% 남음'), findsOneWidget);
  });

  testWidgets('게이지가 없으면 안내를 보여준다', (tester) async {
    await tester.pumpWidget(
      _wrap(const ContextGaugeBar(gauge: null, hint: '켜면 채워집니다')),
    );
    expect(find.text('켜면 채워집니다'), findsOneWidget);
    expect(find.textContaining('남음'), findsNothing);
  });

  testWidgets('켤 수 있으면 버튼을 주고, 누르면 콜백이 온다', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _wrap(
        ContextGaugeBar(
          gauge: null,
          hint: '켜면 채워집니다',
          onEnable: () => tapped++,
        ),
      ),
    );
    await tester.tap(find.text('게이지 켜기'));
    expect(tapped, 1);
  });

  testWidgets('켤 수 없으면(남의 statusLine) 버튼을 숨긴다', (tester) async {
    await tester.pumpWidget(
      _wrap(const ContextGaugeBar(gauge: null, hint: '다른 statusLine 이 있습니다')),
    );
    expect(find.text('게이지 켜기'), findsNothing);
  });

  testWidgets('채움이 임계값 기준으로 계산된다', (tester) async {
    // 500k/700k = 0.714… — 전체 윈도우(1M) 기준이면 0.5 였을 것.
    await tester.pumpWidget(
      _wrap(ContextGaugeBar(gauge: _gauge(used: 500000))),
    );
    await tester.pumpAndSettle();
    final box = tester.widget<FractionallySizedBox>(
      find.byKey(const ValueKey('context-gauge-fill')),
    );
    expect(box.widthFactor, closeTo(500000 / 700000, 1e-6));
  });
}
