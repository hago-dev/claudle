---
name: app-context
description: Claudle 앱 전용 컨텍스트 (플랫폼 차이, 빌드/서명/배포 현황)
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# app-context

일반 아키텍처는 `/project-context` 참조. 여기는 **플랫폼별 차이 + 빌드/서명/배포 현황**만 다룬다(app-builder류 에이전트 전용 프리로드).

## 플랫폼
- Flutter `3.41.2`(fvm 고정) — **데스크톱 전용, ios/android 없음**.
- macOS: `LSUIElement=true`(Dock 아이콘 없음, 메뉴바 트레이 전용). Entitlements: `app-sandbox: false`.
- Windows: 항상-위 프레임리스 HUD 패널(우측 상단), `skipTaskbar: true`. 시스템 트레이는 텍스트 타이틀 미지원 → 헤드라인은 툴팁.

## 자격증명 소스 차이
- macOS: 로그인 키체인(`security find-generic-password -s "Claude Code-credentials"`), 실패 시 `.credentials.json` 폴백.
- Windows/Linux: `%USERPROFILE%\.claude\.credentials.json` 평문 파일 그대로.

## DB 경로 차이
- macOS: `~/Library/Application Support/dev.shimkijun.tokenbar/usage.db`
- Windows: `%APPDATA%\kr.hago\Claudle\usage.db`(`Runner.rc`의 CompanyName\ProductName 기준)

## 네이티브 통합
- WebView: 미사용 · Platform Channel: 미사용 · Push(FCM/APNs): 미사용 · DeepLink: 미사용 · Fastlane: 미사용.
- 앱스토어 배포 아님 — macOS는 ad-hoc 서명 zip(공증 보류 — 상세 아래), Windows는 Inno Setup 설치파일(직접 배포).

## 빌드/서명/배포 현황 (요약 — 상세는 `/app-build`, `/app-signing`)
- macOS: 서명·공증 **자동화 스크립트는 준비됨**(`tool/release_notarize.sh`, 팀 HAGO L&F INC) — 단 Developer ID Application 인증서 미보유(Account Holder만 발급 가능, `tool/release_notarize.md` STEP 1 미완)로 **공증 보류**, 인증서 없으면 스크립트가 첫 검사에서 중단. 현재 실배포는 `tool/release_adhoc.sh`의 ad-hoc 서명 zip(`dist/Claudle-macOS-v*.zip`) — 수령자가 `xattr -dr com.apple.quarantine` 필요. 스크립트가 배포 게이트 3종(더티 트리·버전 재사용·덮어쓰기)을 강제하고 `v<버전>` annotated 태그를 기록으로 남긴다(`dist/`는 gitignore라 그 태그가 "이 zip이 어느 소스에서 나왔나"의 유일한 근거이자 롤백 경로 — `git checkout v<버전>`) — 상세는 `/app-build`.
- Windows: **미서명**(SmartScreen 경고 알려진 상태), EV/OV 인증서 도입은 보류.
- Windows CI: `.github/workflows/build-windows.yml`(수동 dispatch 또는 `v*` 태그 push).
- 버전 동기화 함정: `pubspec.yaml` version ↔ `windows/installer/claudle.iss` AppVersion 수동 동기화 필요.
