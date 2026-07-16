## 필수 원칙

> 사용자 글로벌 가이드와 별개로 **이 저장소에 고정**되어 공유·CI·다른 머신에서도 항상 적용된다. (init-skills 자동 주입)

- **TDD-first (핵심·필수)**: 동작을 바꾸는 모든 작업은 **실패하는 테스트를 먼저** 작성(RED)하고 통과시킨다(GREEN). 테스트 없이 구현 완료로 보지 않는다. 테스트 명령: `fvm flutter test`
- **Deep Module**: 작은 공개 인터페이스 뒤에 복잡도를 숨기고 호출자 컨텍스트를 최소화한다.
- **단순함**: 문제를 푸는 최소 코드. 투기적 추상화·미요청 유연성·과한 에러핸들링 금지.
- **외과적 변경**: 건드려야 할 곳만. 무관한 리팩터·포맷·죽은코드 정리 금지(발견 시 말만).
- **제1원칙**: 유추 복붙 대신 근본에서 쌓는다. 추가 전 "이 단계 자체를 없앨 수 있나?"부터 묻는다.
- **목표 기반**: 검증 가능한 성공 기준을 세우고 통과까지 반복한다.
- **코딩 전 생각**: 불확실하면 묻는다. 가정·해석 갈래·트레이드오프를 드러낸다.

## Harness

이 프로젝트는 하네스 엔지니어링으로 구성되어 있습니다.

### 스택
Flutter `3.41.2`(fvm 고정) / Dart SDK `^3.11.0` — **데스크톱 전용**(macOS 메뉴바 + Windows 항상-위 HUD, `ios/`·`android/` 없음). 상태관리 라이브러리 없음(plain `ValueNotifier`). 로컬 sqlite3 DB(외부 백엔드 없음, Claude 세션 로그를 직접 파싱). 유일한 네트워크 호출은 Claude OAuth `usage` 엔드포인트(구독 한도, 60s 폴링).

### 사용 가능한 스킬
| 스킬 | 용도 |
|------|------|
| /dev-init | 초기 셋업(fvm·pub get) |
| /lint | flutter analyze + dart format |
| /test-run | flutter_test 실행 |
| /review | 코드 리뷰(레이어 경계·Deep Module·컨벤션) |
| /debug | 4단계 구조적 디버깅 |
| /security-check | OAuth 토큰·로컬 파일 접근 점검 |
| /gen-doc | 문서 생성 |
| /changelog | git log 기반 변경 이력 |
| /git-summary | 커밋 메시지/PR 설명 생성 |
| /refactor | 리팩토링 제안/실행 |
| /app-build | macOS ad-hoc 서명 zip(공증 보류) / Windows Inno 설치파일 빌드. 배포는 커밋된 상태에서만 — `v<버전>` 태그가 기록이자 버전 재사용 가드(롤백: `git checkout v<버전>`) |
| /app-nav | 새 화면 추가(Navigator.push) |
| /app-signing | macOS 서명(공증 보류) / Windows 미서명 상태 |
| /app-icon-splash | 트레이/앱 아이콘 파이프라인 |
| /app-perf | 상시구동 앱 성능 점검(워처·DB·폴링) |
| /ci-check | GitHub Actions(Windows 빌드) 분석 |

배경 프리로드 전용(직접 호출 안 함): `project-context`, `conventions`, `app-context`, `app-conventions`.

### 사용 가능한 워크플로 (구 팀 → flow)
| 워크플로 셰이프 | 용도 |
|------|------|
| feature 셰이프 (pipeline+parallel) | 기능 개발 풀 사이클 |
| bugfix 셰이프 | 버그 수정 |
| dev 체인 (examples/dev-review.workflow.js) | 기능 개발 + 리뷰 |
| ... | `flow/SKILL.md` 셰이프 매핑 참조. 상주 팀은 `Agent`(named·`run_in_background`)+`SendMessage` |

### 4단계 아키텍트 워크플로
큰 작업은 이 순서로 — 자세한 규율은 `/conventions`, 도구 라우팅은 `/architect`:
1. **요구사항**: `/architect grill`로 모호함 제거 → `/goal` 메타프롬프트(수용 기준·불변 제약)
2. **아키텍처**: TDD-first(실패 테스트 먼저, `fvm flutter test`) + Deep Module(작은 인터페이스·복잡도 은닉)
3. **병렬**: `flow` 워크플로 / `claude agents`(Agent View) / `/bg`
4. **품질**: `deep-research`(기술결정 전) · `/code-review ultra`(머지 전) · `skill-creator`(반복 패턴 스킬화)
5. **결정 기록**: 비가역·비자명 결정은 `/decision`으로 `.claude/decisions/`에 ADR 기록(버린 대안·왜 포함). 읽기는 위 결정 인덱스가 자동 상속.

### 유지 보수
- `/init-validate` — 참조 정합성 검증 + 고아/드리프트 정리 (상태 진단 포함)
- `/init-validate --fix` — 스킬 매핑 동기화
- init-pipeline 워크플로 — 전체 재생성/업데이트 (구 /harness, `flow/examples/init-pipeline.workflow.js`)
