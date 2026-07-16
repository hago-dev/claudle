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
│   └── limits_controller.dart — 구독 한도 폴링(60s).
├── core/
│   ├── db/usage_database.dart      — sqlite3 래퍼 + 집계 결과 타입 UsageTotals.
│   ├── pricing/                    — CostCalculator, PricingRepository, ModelPricing.
│   └── util/                       — format, project_root, user_home.
├── data/
│   ├── ingest/ingest_service.dart  — 백필·증분 파싱.
│   ├── limits/                     — RealLimitsSource(OAuth usage 엔드포인트), ClaudeCredentials(키체인/파일).
│   └── providers/
│       ├── claude_code/            — ClaudeCodeUsageProvider, ClaudeJsonlParser, ClaudePathResolver, AgentRunReader.
│       └── stub/                   — StubUsageProvider(테스트/검증용 seam, TOKENBAR_STUB=1 일 때만 활성).
├── domain/
│   ├── provider/usage_provider.dart — UsageProvider 인터페이스 + ProviderRegistry.
│   ├── limits/limits_source.dart    — LimitsSource 인터페이스.
│   └── models/                      — UsageEvent, SubscriptionLimits/LimitBucket, AgentRun/AgentStep/ToolCall.
└── presentation/
    ├── dashboard.dart        — 메인 대시보드(총계·기간선택·한도패널·차트).
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
