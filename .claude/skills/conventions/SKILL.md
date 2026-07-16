---
name: conventions
description: Claudle 네이밍/구조/커밋/TDD 컨벤션 (에이전트 프리로드용)
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# conventions

## 네이밍
- 파일: `snake_case.dart` ↔ 클래스: `PascalCase`. private 클래스/멤버: `_` 접두.
- 접미사 관례(관찰됨):
  - `_source.dart` / `_provider.dart` — seam 이름. 인터페이스는 `domain/`(`limits_source.dart`의 `LimitsSource`, `usage_provider.dart`의 `UsageProvider` — lib 전체에서 `abstract class`는 이 둘뿐. 같은 파일의 `ProviderRegistry`는 인터페이스가 아니라 구체 레지스트리), 구현체는 `data/`에 같은 접미사로 배치(`real_limits_source.dart`, `claude_code_provider.dart`) — 레이어는 접미사가 아니라 디렉토리로 판별
  - `_service.dart` — 오케스트레이션 로직(`IngestService`)
  - `_repository.dart` — 조회/변환 저장소(`PricingRepository`)
  - `_controller.dart` — application 레이어 상태 소유자(`AppController`, `LimitsController`)
  - `_reader.dart` / `_parser.dart` / `_resolver.dart` — data 레이어 단일 책임 유틸(`AgentRunReader`, `ClaudeJsonlParser`, `ClaudePathResolver`)
- `presentation/`은 접미사가 혼용됨(`dashboard.dart`엔 없고 `agents_screen.dart`엔 `_screen`) — 강제 규칙 없음, 새 화면 추가 시 기존 두 이름 중 자연스러운 쪽을 따르면 된다.
- 위젯 분해: 파일 하나 안에 다수의 **private** `StatelessWidget`/`StatefulWidget` 클래스(`_UsageBreakdown`, `_LimitsPanel`, `_TotalsCard` 등)로 쪼개는 것이 확립된 패턴 — 별도 파일로 분리하지 않는다.

## 상태관리
- 상태관리 라이브러리 없음. 축이 둘이고, **어느 축이냐로 갈린다**(UI 전용/도메인 구분이 아님):
  - **과금 집계 축** — `AppController`가 `ValueNotifier`로 소유(총계·한도·phase) → `dashboard.dart`가 `ValueListenableBuilder`로 구독(3곳), `main.dart`는 `addListener`로 트레이 갱신.
  - **에이전트 축** — `agents_screen.dart`가 reader를 직접 호출해 `State` + `setState`로 소유(`List<AgentRun>` 등, setState 14곳. `ValueNotifier`/`AppController` 참조 0). 도메인 데이터지만 의도된 설계다 — 클래스 주석 "과금 집계(대시보드)와 별개 축이라 DB 를 안 거치고 파일에서 바로 읽는다".
- 도입 배경: `app_controller.dart` 주석 "riverpod 대신 plain ValueNotifier — §2 단순함"(명시적 설계 결정).

## 커밋 메시지
`{type}[(scope)]: {한국어 설명}` — `feat`/`fix`/`chore`(+ 표준 확장 `docs`/`refactor`/`test`), scope는 플랫폼(`windows`/`macos`) 한정 시 사용. 상세는 `/changelog` 참조.

## TDD-first
- 테스트 러너: `fvm flutter test` (`test/` 디렉토리, `flutter_test` 패키지).
- 관찰된 스타일: 평면 `test()` + `expect()`(`group()` 미사용), 표준 matcher(`isNull`, `isFalse`, `endsWith` 등), 실측 로그 구조를 흉내 내는 private JSON 픽스처 헬퍼 함수.
- **RED/GREEN 확인 명령**: `fvm flutter test` — 실패=RED, 통과=GREEN. 동작을 바꾸는 작업은 이 명령으로 실패하는 테스트를 먼저 작성하고 통과시킨다.
  - ⚠️ 기존 실패 주의: `test/widget_test.dart`가 손 안 댄 Flutter 템플릿 잔재라 lib/에 없는 `MyApp`을 참조한다(`lib/main.dart`는 `ClaudleApp`) — 어떤 변경과도 무관하게 항상 실패한다. 따라서 GREEN 판정은 "스위트 전체 초록"이 아니라 **내가 쓴 테스트 통과 + 이 기존 실패 외에 새 실패 없음**으로 본다(근본 해결은 레포 쪽 — 고아 `widget_test.dart` 삭제/갱신).
- `bin/verify.dart` + `bin/*_verify.dart` 5종(총 6개)은 **자동 테스트가 아니다** — 실데이터/실API 대조용 수동 오라클 스크립트(`fvm dart run bin/xxx.dart`). 커밋 게이트가 아니라 필요 시 사람이 직접 실행.

## Deep Module
- 대표 사례: `UsageProvider`. 호출자(`AppController`)는 `backfill()`/`watch()`류의 좁은 공개 인터페이스만 알고, 각 구현체가 "어떻게" 소스를 읽는지는 모른다.
- 경계: `domain/provider/usage_provider.dart`에 인터페이스, `data/providers/`에 구현체 격리 — 단, 격리는 **사용 지점** 기준이다. `app_controller.dart`는 조립(composition root)이라 data 구현체를 직접 import·생성하고(`ClaudeCodeUsageProvider`·`StubUsageProvider`·`IngestService`·`RealLimitsSource`·`ClaudePathResolver`), 조립 이후의 사용만 `UsageProvider` 인터페이스로 한다. 순수 인터페이스 의존 사례는 `LimitsController`(`LimitsSource` 생성자 주입).

## 설계 렌즈 4질문 (리뷰·설계 점검 시 적용)
1. 인터페이스≈구현이면 inline할까(Ousterhout 얕은 모듈).
2. 이 에러를 설계로 없앨 수 있나(define errors out of existence).
3. simple인가 easy인가(Hickey decomplect).
4. essential인가 accidental complexity인가(Brooks).

## 결정 기록
비가역·비자명 결정은 `/decision`으로 `.claude/decisions/NNNN-slug.md`에 ADR로 남긴다(현재 없음 — `project-context`의 결정 인덱스가 자동 상속).
