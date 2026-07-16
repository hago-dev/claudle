---
name: debug
description: Claudle 4단계 구조적 디버깅 (재현→격리→추적→수정). $ARGUMENTS로 에러/증상.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

# debug

`$ARGUMENTS`로 에러 메시지나 증상을 받아 4단계 디버깅을 수행한다.

## 1. 재현
- 에러 메시지/스택 트레이스 분석. 플랫폼 명시(macOS 트레이 / Windows HUD) — 두 모드가 서로 다른 `WindowOptions`로 시작하므로 플랫폼별로 증상이 갈릴 수 있다(`lib/main.dart`의 `hudMode` 분기).
- `TOKENBAR_FORCE_HUD=1`로 macOS에서 HUD 경로 재현 가능.

## 2. 격리 — 어느 레이어인가
| 증상 | 의심 레이어 |
|---|---|
| 총계/차트 숫자가 안 맞음 | `core/pricing`(단가 매칭) 또는 `data/ingest`(dedup 키) |
| 트레이/HUD가 안 뜨거나 갱신 안 됨 | `application/app_controller.dart`(ValueNotifier 배선) 또는 `main.dart`(window_manager) |
| 새 세션이 반영 안 됨 | `data/providers/claude_code`(watcher, jsonl 파싱) |
| 한도(usage limits)가 이상함 | `data/limits/real_limits_source.dart`(OAuth 토큰/엔드포인트) |
| DB 관련 크래시 | `core/db/usage_database.dart`(sqlite3 오픈/스키마) |

## 3. 원인 추적
- `AppController.start()`(DB 오픈 → 단가 로드 → provider 등록 → backfill → watch) 순서 중 어디서 끊겼는지 로그(`status`/`phase` ValueNotifier) 확인.
- `ClaudeJsonlParser`의 dedup 키(`message.id` + `requestId`) 로직 — 스트리밍 중간값이 최종값을 덮어쓰는지 확인(`bin/verify.dart` 오라클로 대조 가능).
- 플랫폼 고유 이슈면 `windows/runner/*.cpp`(HUD) vs `macos/Runner/AppDelegate.swift`(트레이) 비교.

## 4. 수정 제안
- 최소 범위 수정안 제시. `AppController`의 Deep Module 경계(호출자는 provider 내부를 몰라야 함)를 깨지 않는 수정 우선.
- 수정 후 관련 `bin/*_verify.dart` 오라클 스크립트로 실데이터 대조 검증 권장(자동 테스트가 커버 못하는 영역).
