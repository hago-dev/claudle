---
name: test-run
description: flutter_test 단위 테스트 실행. $ARGUMENTS로 파일/패턴 지정. 실패 시 원인 요약.
user-invocable: true
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
---

# test-run

`test/` 아래 flutter_test 테스트를 실행한다. `$ARGUMENTS`로 특정 파일이나 디렉토리 지정 가능.

## 현재 상태
- `test/agent_run_reader_test.dart` — 서브에이전트 jsonl 파서 실측 구조 재현(픽스처 헬퍼 함수 + `test()`/`expect()` 플랫 스타일, `group()` 미사용).
- `test/widget_test.dart` — 기본 템플릿 위젯 테스트(카운터 스모크 테스트, `MyApp` 참조 — 실제 앱 진입점은 `ClaudleApp`으로 이름이 바뀌어 있어 **현재 깨져 있을 가능성**이 있다. 실행해 확인할 것).

## 실행 명령어
```bash
fvm flutter test                    # 전체
fvm flutter test $ARGUMENTS         # 특정 파일 (예: test/agent_run_reader_test.dart)
fvm flutter test --name "<패턴>"    # 테스트 이름 패턴
```

## 테스트 작성 규칙(관찰된 패턴)
- 파일: `test/<name>_test.dart` — 평면 구조, `test/` 하위 폴더 세분화 없음.
- `test()` + `expect()` 플랫 스타일 사용, `group()` 미사용(현재까지는 파일 하나에 대상 하나라 불필요).
- 매처: `isNull`, `isFalse`, `endsWith(...)` 등 표준 matcher 적극 사용.
- 실측 로그 구조를 흉내 내는 픽스처는 파일 상단 private 헬퍼 함수(`_userLine`, `_assistantLine` 등)로 JSON 인코딩해서 만든다 — mock 프레임워크 없이 순수 데이터 픽스처.

## bin/*.dart 오라클 스크립트 (자동 테스트 아님 — 구분 주의)
`bin/`에는 실제 Claude 로그·실 DB·실 API와 대조하는 수동 검증 스크립트 6종이 있다. `flutter test`가 수집하는 대상이 아니고, 필요할 때 사람이 직접 실행한다:
```bash
fvm dart run bin/verify.dart              # 전체 파싱→집계, ccusage 오라클과 대조
fvm dart run bin/ingest_verify.dart       # DB 백필 증분성(2회차 신규≈0)
fvm dart run bin/pricing_verify.dart      # 단가 변경 전 격리 검증
fvm dart run bin/limits_verify.dart       # 실 usage 엔드포인트 값을 /usage 패널과 대조
fvm dart run bin/provider_verify.dart     # provider seam end-to-end(stub, 실데이터 무오염)
fvm dart run bin/project_period_verify.dart
```

## 실패 시
- 실패한 assertion과 관련 소스(파서/DB/컨트롤러)를 함께 읽어 원인 요약.
- `widget_test.dart`가 `MyApp` 미존재로 실패한다면, 이는 템플릿 잔재이지 회귀 버그가 아님을 명시하고 실제 진입점(`ClaudleApp`, `lib/main.dart`)에 맞춘 수정 여부를 사용자에게 확인 후 진행.
