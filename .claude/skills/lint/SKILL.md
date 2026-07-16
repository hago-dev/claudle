---
name: lint
description: Dart 정적 분석 및 포맷 검사 실행
user-invocable: true
disable-model-invocation: true
allowed-tools:
  - Bash
---

# lint

프로젝트 정적 분석 및 포맷을 실행한다.

## 실행

```bash
fvm flutter analyze          # 정적 분석 (analysis_options.yaml 기준)
fvm dart format --output=none --set-exit-if-changed .   # 포맷 검사만(변경 없음)
fvm dart format .            # 포맷 적용
```

## 설정
- `analysis_options.yaml` — `package:flutter_lints/flutter.yaml` 기반, 커스텀 rule 오버라이드 없음(기본 권장 세트 그대로).
- 대상: `lib/**/*.dart`, `test/**/*.dart`, `bin/**/*.dart`, `tool/*.dart`.

## 실패 시
- `flutter analyze` 에러는 파일:라인과 함께 원인을 설명하고 최소 수정안 제시.
- 포맷 diff는 `dart format .`으로 일괄 적용 가능(로직 변경 없음 — 안전).
