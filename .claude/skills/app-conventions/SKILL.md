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
- 파일 하나 안에 다수의 **private** `StatelessWidget`/`StatefulWidget`(`_TotalsCard`, `_DailyBars` 등)로 쪼개는 것이 기본 — private 면 API 표면이 안 늘고, 그 화면 안에서만 쓰는 조각이 밖으로 새지 않는다.
- **단 파일이 ~700줄을 넘으면 응집된 덩어리를 별도 파일로 분리한다.** private 한 파일 규칙은 700줄쯤에서 이득(좁은 API 표면)보다 비용(탐색·테스트 불가)이 커진다. 실제로 `agents_screen.dart`가 2002줄까지 자라 5개로 갈렸다(2026-07-17).
- 분리 기준은 **줄 수가 아니라 결합도** — 한 곳에서만 쓰는 위젯은 그 파일에 private 로 남기고, 여러 파일이 쓰는 것만 public 으로 올린다(`agent_widgets.dart` = `Critter`·`TypeBadge`·`ToolLine`·`toolIcon`+포맷 헬퍼).
- 모델(계산·`ChangeNotifier`)과 뷰(위젯)는 파일을 가른다 — 모델이 private 면 **테스트를 아예 못 쓴다**. `forest_scene.dart`(모델) ↔ `forest_scene_view.dart`(뷰)가 그 짝.
- 에이전트 화면 현재 배치: `agents_screen.dart`(셸: 탭·폴링) · `agent_history_view.dart`(기록·재생·카드) · `agent_log_sheet.dart`(상세 시트) · `forest_scene.dart`/`forest_scene_view.dart`(라이브 숲) · `agent_widgets.dart`(공유).
- 로컬 상태가 없으면 `StatelessWidget`. `AppController`/`LimitsController`의 값은 `ValueListenableBuilder`로 구독.

## 플랫폼 분기 규칙
- 플랫폼 판별은 `Platform.isWindows`/`Platform.isMacOS` (또는 `main.dart`의 `hudMode` getter 재사용) — UI 트리 최상단(`main.dart`)에서 한 번만 분기하고, 화면 내부에서 산발적으로 재분기하지 않는다.
- 개발용 강제 오버라이드: `TOKENBAR_FORCE_HUD=1` 환경변수로 macOS에서 HUD 미리보기 — 이 패턴을 따라 새 플랫폼 오버라이드가 필요하면 환경변수 방식 유지.

## 포맷/표시 규칙
- 숫자·기간 포맷은 항상 `core/util/format.dart`의 기존 함수(`compactTokens`, `money`, `compactDuration`, `resetClockKo`) 경유 — 화면 코드에서 직접 포맷 로직 작성 금지.

## 디자인 톤
- 다크 테마 고정(`ColorScheme.fromSeed(seedColor: 0xFF7C5CFF, brightness: Brightness.dark)`), 둥근 카드 — `main.dart`의 `tokenBarTheme()` 재사용, 색상 하드코딩 대신 이 테마 경유.
