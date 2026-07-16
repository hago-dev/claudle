---
name: gen-doc
description: Claudle 문서 자동 생성 (dartdoc 주석/클래스/기능 설명). $ARGUMENTS로 대상 지정.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
  - Edit
---

# gen-doc

`$ARGUMENTS`로 파일/클래스/기능명을 받아 문서를 생성한다.

## 대상별 동작

### 클래스/파일
- 기존 코드의 dartdoc 스타일을 따른다: `///` 블록, 첫 줄은 한 줄 요약, 이후 배경/설계 이유 설명(예: `app_controller.dart`의 "**Deep Module**: provider 가 어떻게..." 주석 패턴).
- 공개 API(class·메서드)에는 "왜 이렇게 했는가"를 남긴다 — 단순 파라미터 나열보다 설계 의도 우선(레포 전체 관찰 패턴).

### 기능/레이어 (예: `ingest`, `providers`, `limits`)
- 해당 레이어 디렉토리 구조와 각 파일의 역할을 표로 정리.
- `core → domain ← data ← application ← presentation` 의존 방향 명시.

### README.md
- 현재 `README.md`는 `flutter create` 기본 템플릿 그대로 미채워져 있음 — 실제 문서화 요청 시 앱 목적(Claudle 🐩: Claude Code 사용량 데스크톱 앱), 플랫폼(macOS 메뉴바/Windows HUD), 빌드 방법(`fvm flutter build ...`)으로 교체 제안.

## 스타일
- 한국어로 작성(레포 전체 주석/커밋 메시지가 한국어).
- 코드 식별자(클래스/함수/변수명)는 영어 그대로 유지.
- 과도한 장식/이모지 남발 지양 — 기존 주석 톤(간결, 배경 설명 위주)을 따른다.
