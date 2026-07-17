---
name: project-context
description: Claudle 프로젝트 아키텍처 및 패턴 컨텍스트 (에이전트 프리로드용)
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# project-context

**Claudle 🐩** — Claude Code 사용량(토큰/비용/한도)을 측정하는 데스크톱 앱. 완전 로컬(외부 백엔드 없음) — 사용자의 Claude 세션 로그(jsonl)를 직접 파싱해 sqlite에 집계하고, 구독 한도만 Claude OAuth `usage` 엔드포인트에서 60초마다 폴링한다.

데이터 소스는 3개다: ① 세션 JSONL(토큰/비용) ② OAuth `usage`(구독 한도) ③ **statusline 덤프**(컨텍스트 게이지 — CC가 상태줄을 그릴 때마다 훅이 `<claude>/claudle/sessions/<session_id>.json`에 페이로드를 떨군다).

③이 별도인 이유: auto-compact 게이지에 필요한 **컨텍스트 윈도우 크기가 JSONL에 없다**(`model`은 `claude-opus-4-8`까지만 남아 200k/1M 구분 불가). CC가 statusline 커맨드에 주는 `context_window.context_window_size`가 유일한 로컬 출처다. 원격 설정(`heather_vale`)이 모델별 윈도우를 정하고 로컬 캐시(`~/.claude.json`의 `autoCompactWindowsCache`)는 보통 null이라, 모델 문자열로 추론하는 건 불가능하다.

**게이지는 세션당 하나** — 숲(에이전트 라이브 뷰)의 사람 캐릭터 이름표 옆에 미니바로 붙는다. 그래서 훅이 `session_id`로 파일을 쪼갠다(`sed`로 추출 — jq/python 의존 금지). 라이브 판정은 게이지 쪽에서 **하지 않는다**: 숲이 이미 `AgentRun.isRunning`으로 정하므로 `sessionId` 조인만 하면 죽은 세션의 낡은 덤프는 자연히 걸러진다(별도 시간 창을 두면 두 판정이 어긋난다).

**훅은 앱이 깐다** — `StatuslineInstaller`가 스크립트를 생성(macOS `.sh` / Windows `.ps1`)하고 `settings.json`에 병합한다. 배포 대상 전원에게 JSON을 손으로 고치라고 할 수 없기 때문. 규칙:
- **남의 `statusLine`은 덮지 않는다**(`foreign` 상태로 거부) · settings.json은 병합만 + 원자적 교체.
- **`syncScript()`를 앱 시작마다 부른다** — 스크립트는 앱이 만드는 산출물이라, 앱만 업데이트되면 사본이 갈라져 조용히 옛 동작을 한다(실제로 단일파일 시절 스크립트가 남아 세션 분리가 안 먹었다).
- ⚠️ **Windows는 게이지에 닿지 못한다** — `main.dart`가 `hudMode ? WindowsHudScreen : DashboardScreen`으로 갈라서 HUD엔 숲으로 가는 경로는 있으나 게이지 온보딩(대시보드 카드)이 없다. `.ps1`은 아직 실기 검증 전.

## 스택
- Flutter `3.41.2`(fvm 고정, `.fvmrc`) / Dart SDK `^3.11.0`
- **데스크톱 전용** — macOS + Windows만 존재(`ios/`, `android/` 디렉토리 없음).
- 트레이/윈도우: `tray_manager`, `window_manager`
- 로컬 DB: `sqlite3` + `sqlite3_flutter_libs`(Application Support 디렉토리의 `usage.db`)
- 로그 실시간 감시: `watcher`
- 대시보드 차트: `fl_chart`
- 국제화 포맷: `intl`
- **상태관리 없음** — plain `ValueNotifier`(`app_controller.dart` 주석: "riverpod 대신 plain ValueNotifier — §2 단순함").
- 패키지 매니저: pub(`pubspec.lock`), 버전 고정은 fvm.

## 아키텍처 (레이어드, 의존 방향 `presentation → application → data → domain`, `core`는 공용)
```
lib/
├── main.dart                — 진입점. hudMode(Platform.isWindows)로 macOS 메뉴바 vs Windows HUD 분기.
├── application/
│   ├── app_controller.dart   — DB+provider registry 단일 소유자(Deep Module).
│   ├── limits_controller.dart — 구독 한도 폴링(60s).
│   └── context_gauge_controller.dart — 컨텍스트 게이지 폴링(2s, 값 변화 시에만 통지).
├── core/
│   ├── db/usage_database.dart      — sqlite3 래퍼 + 집계 결과 타입 UsageTotals.
│   ├── pricing/                    — CostCalculator, PricingRepository, ModelPricing.
│   └── util/                       — format, project_root, user_home.
├── data/
│   ├── ingest/ingest_service.dart  — 백필·증분 파싱.
│   ├── limits/                     — RealLimitsSource(OAuth usage 엔드포인트), ClaudeCredentials(키체인/파일).
│   ├── statusline/                 — StatuslineInstaller(훅 스크립트 생성 + settings.json 병합, 남의 것은 안 덮음).
│   └── providers/
│       ├── claude_code/            — ClaudeCodeUsageProvider, ClaudeJsonlParser, ClaudePathResolver, AgentRunReader, ContextGaugeReader(statusline 덤프).
│       └── stub/                   — StubUsageProvider(테스트/검증용 seam, TOKENBAR_STUB=1 일 때만 활성).
├── domain/
│   ├── provider/usage_provider.dart — UsageProvider 인터페이스 + ProviderRegistry.
│   ├── limits/limits_source.dart    — LimitsSource 인터페이스.
│   └── models/                      — UsageEvent, SubscriptionLimits/LimitBucket, AgentRun/AgentStep/ToolCall, ContextGauge(auto-compact 임계값 계산).
└── presentation/
    ├── dashboard.dart        — 메인 대시보드(총계·기간선택·한도패널·차트).
    ├── context_gauge_bar.dart — 컨텍스트 에너지바(auto-compact 까지 빨간 게이지).
    └── agents_screen.dart    — 서브에이전트 시각화("숲에서 뛰노는 동물" 은유, 라이브+히스토리+재생 뷰).
```

## 핵심 패턴
- **Deep Module**(`app_controller.dart`): `AppController`는 provider가 "어떻게" 소스를 읽는지 모른다 — 등록된 `UsageProvider`들을 backfill/watch하고, 신호가 오면 총계만 다시 읽는다.
- **Provider seam**: `UsageProvider` 인터페이스 하나로 백필/워치 경로가 통일. 신규 소스는 `ProviderRegistry`에 한 줄 등록으로 확장(현재 `ClaudeCodeUsageProvider`, 테스트용 `StubUsageProvider` — `TOKENBAR_STUB=1`일 때만 활성).
- **오라클 검증 스크립트**(`bin/*.dart` 6종): `verify`, `ingest_verify`, `pricing_verify`, `limits_verify`, `provider_verify`, `project_period_verify` — `fvm dart run bin/xxx.dart`로 실행하는 **수동** 대조 검증(자동 테스트 아님, 실데이터/실API 오라클 대조용).
- **버전 드리프트 함정**: `pubspec.yaml`의 `version`과 `windows/installer/claudle.iss`의 `AppVersion`을 손으로 동기화해야 함(Inno Setup이 pubspec을 읽지 않음) — 과거 실제 드리프트 발생(커밋 `99ada34`).

## 배포
- **macOS**: 현재 실배포 = ad-hoc 서명 zip — `tool/release_adhoc.sh` → `dist/Claudle-macOS-v*.zip`(수령자 `xattr -dr com.apple.quarantine` 필요). 공증(무경고) 경로 `tool/release_notarize.sh` → `~/Desktop/Claudle-macOS-notarized.zip`는 Developer ID 인증서 미보유로 **보류**.
- **Windows**: GitHub Actions(`.github/workflows/build-windows.yml`) → `flutter build windows --release` → Inno Setup 6 컴파일 → **미서명** exe(SmartScreen 경고 발생, 알려진 상태).

## 결정 인덱스
`.claude/decisions/`가 아직 없어 이 섹션은 비어 있다. 비가역·비자명 결정이 생기면 `/decision`으로 기록 시작.
