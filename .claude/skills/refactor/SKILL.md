---
name: refactor
description: Claudle 리팩토링 제안/실행 — 중복 제거, 레이어 경계 정리. $ARGUMENTS로 대상 지정.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
  - Edit
  - Bash
---

# refactor

`$ARGUMENTS`로 대상 파일/디렉토리를 받아 리팩토링을 수행한다.

## 검사 항목
- 레이어 경계 흐림: `domain/`이 `data/`·`application/`을 import(허용 방향은 `presentation → application → data → domain`, `core`는 공용).
- Deep Module 침식: `AppController` 밖에서 provider 내부 구현을 직접 참조하는 코드.
- 위젯 비대화: `build()`가 커지면 기존 파일들처럼 private `_XxxCard`/`_XxxRow`/`_XxxSection` 클래스로 분해(파일 내 다중 private 위젯 클래스는 이 코드베이스의 확립된 패턴).
- `setState` 남용 → `ValueNotifier`/`ValueListenableBuilder`로 통일(리버팟 등 상태관리 라이브러리 도입 없이 — 기존 설계 결정 "§2 단순함" 유지).
- 중복 포맷 로직 → `core/util/format.dart`로 이동.
- 미사용 import 정리.

## 절차
1. 현재 코드 분석 및 개선점 목록 제시.
2. 리팩토링 계획 제시(사용자 확인).
3. 수정 실행.
4. `fvm flutter analyze` + `fvm flutter test` 통과 확인(동작 동일성 검증 — TDD-first 원칙, `/conventions` 참조).

## 하지 않는 것
- 상태관리 라이브러리(Riverpod/Provider/Bloc) 도입 — `app_controller.dart` 주석에 "riverpod 대신 plain ValueNotifier" 설계 이유가 명시돼 있음. 도입은 명시적 요청·결정 기록(`/decision`) 없이는 하지 않는다.
