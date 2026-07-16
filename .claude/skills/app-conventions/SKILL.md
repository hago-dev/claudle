---
name: app-conventions
description: Claudle 위젯/화면 코딩 컨벤션 (플랫폼별 규칙 포함)
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# app-conventions

일반 네이밍/레이어 컨벤션은 `/conventions` 참조. 여기는 **위젯/화면 레벨 + 플랫폼 분기 규칙**만 다룬다.

## 화면 구조
- `lib/presentation/{name}.dart` 또는 `{name}_screen.dart` — 접미사 강제 없음(기존 파일도 혼용).
- 화면 전환: `Navigator.push(MaterialPageRoute(...))` 표준 방식만 사용, 라우팅 라이브러리 도입 안 함(`/app-nav` 참조).

## 위젯 분해
- 파일 하나 안에 다수의 **private** `StatelessWidget`/`StatefulWidget`(`_TotalsCard`, `_DailyBars`, `_AgentCard` 등)로 쪼개는 것이 표준 — 별도 파일 분리보다 이 패턴을 우선.
- 로컬 상태가 없으면 `StatelessWidget`. `AppController`/`LimitsController`의 값은 `ValueListenableBuilder`로 구독.

## 플랫폼 분기 규칙
- 플랫폼 판별은 `Platform.isWindows`/`Platform.isMacOS` (또는 `main.dart`의 `hudMode` getter 재사용) — UI 트리 최상단(`main.dart`)에서 한 번만 분기하고, 화면 내부에서 산발적으로 재분기하지 않는다.
- 개발용 강제 오버라이드: `TOKENBAR_FORCE_HUD=1` 환경변수로 macOS에서 HUD 미리보기 — 이 패턴을 따라 새 플랫폼 오버라이드가 필요하면 환경변수 방식 유지.

## 포맷/표시 규칙
- 숫자·기간 포맷은 항상 `core/util/format.dart`의 기존 함수(`compactTokens`, `money`, `compactDuration`, `resetClockKo`) 경유 — 화면 코드에서 직접 포맷 로직 작성 금지.

## 디자인 톤
- 다크 테마 고정(`ColorScheme.fromSeed(seedColor: 0xFF7C5CFF, brightness: Brightness.dark)`), 둥근 카드 — `main.dart`의 `tokenBarTheme()` 재사용, 색상 하드코딩 대신 이 테마 경유.
