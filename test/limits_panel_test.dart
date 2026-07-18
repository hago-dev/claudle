import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokenbar/presentation/limits_panel.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 460, child: child)),
);

void main() {
  testWidgets('아직 안 불러왔고 상태도 없으면 조회 중', (tester) async {
    await tester.pumpWidget(_wrap(const LimitsPanel(limits: null, status: '')));
    expect(find.textContaining('조회'), findsOneWidget);
  });

  testWidgets('실패했으면 왜 실패했는지 보여준다 — 침묵 금지', (tester) async {
    await tester.pumpWidget(
      _wrap(const LimitsPanel(limits: null, status: '한도 조회 실패: HTTP 429')),
    );
    // "조회 중…"에 갇히지 않고 실제 사유가 화면에 있어야 한다.
    expect(find.textContaining('429'), findsOneWidget);
    expect(find.text('한도 조회 중…'), findsNothing);
  });
}
