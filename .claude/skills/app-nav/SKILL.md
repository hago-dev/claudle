---
name: app-nav
description: Claudle 새 화면 추가 (Navigator.push 기반, GoRouter 없음). $ARGUMENTS로 화면명.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Write
  - Edit
---

# app-nav

`$ARGUMENTS`로 화면명을 받아 기존 패턴에 맞춰 새 화면을 생성/등록한다.

## 현재 네비게이션 구조 (단순 — 라우터 라이브러리 없음)
- 화면 **파일** 2개 / 최상위 **화면 클래스** 3개: `presentation/dashboard.dart`(`DashboardScreen`=macOS 대시보드 · `WindowsHudScreen`=Windows HUD — `main.dart:281-283`이 `hudMode`로 택일, `_LimitsPanel` 공유), `presentation/agents_screen.dart`(`AgentsScreen` — 서브에이전트 시각화).
- 전환은 표준 `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentsScreen()))` — 이름 있는 라우트(`onGenerateRoute`)나 `go_router` 등 라우팅 라이브러리 없음.
- `Navigator.pop(ctx)` / `Navigator.pop(ctx, value)`로 값 반환하는 다이얼로그성 팝업도 동일 파일 내에서 처리(별도 라우트로 안 뺌).

## 생성 절차
1. `lib/presentation/{name}.dart` 또는 `{name}_screen.dart` 생성(기존 두 파일이 접미사 혼용이라 강제 규칙 없음 — 다이얼로그성이면 접미사 없이, 별도 풀스크린 화면이면 `_screen` 권장).
2. 최상위 위젯은 `StatelessWidget`(로컬 state 필요 시만 `StatefulWidget`), `Scaffold` 루트.
3. 호출부(주로 `dashboard.dart`)에서 `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const {ScreenName}()))`로 연결.
4. 화면 내부에서 `ValueListenableBuilder`로 `AppController`의 `ValueNotifier`(totalsAll, limits 등)를 구독 — 새 상태관리 도입 금지.

## 하지 않는 것
- `go_router`/`Navigator 2.0`/이름 있는 라우트 테이블 도입 — 화면 수가 적어 현재 단순 push 방식이 충분(YAGNI). 화면이 크게 늘어나 필요해지면 별도 결정(`/decision`)으로 논의.
