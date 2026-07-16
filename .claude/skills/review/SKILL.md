---
name: review
description: Claudle 코드 리뷰 — Critical/Warning/Info 등급. $ARGUMENTS로 파일/디렉토리 지정.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# review

`$ARGUMENTS`로 파일/디렉토리를 받아 프로젝트 실제 컨벤션 기준으로 코드 리뷰한다. 범용 버그/성능 탐지는 네이티브 `/code-review`가 diff에서 더 깊게 커버하므로, 여기서는 **이 프로젝트 고유 패턴** 위반에 집중한다.

## Critical
- 레이어 위반: `domain/`이 `data/`나 `application/`을 import(의존 방향은 항상 `presentation → application → data → domain`, `core`는 어디서나 참조 가능).
- Deep Module 위반: `AppController` 밖에서 `UsageProvider` 구현체를 직접 인스턴스화/호출(등록은 반드시 `ProviderRegistry` 경유).
- `usage.db` 등 로컬 파일 경로를 하드코딩(항상 `path_provider`의 `getApplicationSupportDirectory()` 경유).
- 플랫폼 분기 누락: `Platform.isWindows`/`Platform.isMacOS` 체크 없이 macOS·Windows 중 한쪽 전용 API(트레이 vs HUD) 직접 사용.

## Warning
- `ValueNotifier`/`ValueListenableBuilder` 대신 `setState` 남용(전역 상태를 로컬 State로 복제).
- `StatefulWidget`을 상태 없이 사용(로컬 mutable state가 없으면 `StatelessWidget`으로 충분 — `dashboard.dart`/`agents_screen.dart`의 기존 분해 패턴 참조).
- 위젯 파일 내 `build()` 비대화 — 기존 파일들처럼 private 위젯 클래스(`_XxxCard`, `_XxxRow` 등)로 분해하지 않음.
- 미사용 import, `print()` 디버그 출력 잔존(로그가 필요하면 `status`/`phase` ValueNotifier 경유로 UI에 노출하는 기존 패턴 따름).

## Info
- 네이밍 불일치: 파일 snake_case ↔ 클래스 PascalCase 어긋남, 접미사 관례(`_provider`=인터페이스, `_service`=오케스트레이션, `_repository`=저장소, `_controller`=앱 상태 소유자) 이탈.
- 매직 넘버(포맷 임계값 등)를 `core/util/format.dart`처럼 이름 있는 상수/함수로 뽑지 않음.
- 한국어 주석/설명과 영어 코드 식별자 혼용 규칙(기존 전 코드베이스 패턴) 이탈.

## 출력 형식
```
## 리뷰 결과: {파일명}

🔴 Critical ({n}건)
- [C1] {설명} — {파일}:{라인}

🟡 Warning ({n}건)
- [W1] {설명} — {파일}:{라인}

🔵 Info ({n}건)
- [I1] {설명} — {파일}:{라인}
```
