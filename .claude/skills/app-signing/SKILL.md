---
name: app-signing
description: macOS 서명/공증 + Windows 코드사인 상태 분석 및 가이드
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Bash
---

# app-signing

플랫폼별 서명 상태를 분석하고 가이드한다. 전문 절차는 `tool/release_notarize.md`(macOS)·`windows/installer/BUILD.md`(Windows)가 SSOT — 이 스킬은 체크리스트와 진입점만 제공한다.

## macOS — 서명 + 공증 (팀: HAGO L&F INC, `tool/release_notarize.md` 참조)
- 현재 **공증 보류**: Developer ID Application 인증서 미발급(Account Holder만 발급 가능 — `tool/release_notarize.md` STEP 1 미완). 인증서가 생기기 전까지 `release_notarize.sh`는 첫 검사(인증서 탐색)에서 중단된다.
- 실제 배포 경로: `bash tool/release_adhoc.sh` — ad-hoc deep 재서명 → `dist/Claudle-macOS-v<버전>.zip`, 수령자가 `xattr -dr com.apple.quarantine /Applications/Claudle.app` 필요(안내문 `tool/dist_readme_adhoc.txt` 동봉).
- 필요: "Developer ID Application" 인증서(Xcode Accounts에서 발급, Account Holder/Admin 권한 필요) + `xcrun notarytool store-credentials`로 저장한 공증 프로필.
- 확인:
  ```bash
  security find-identity -v -p codesigning | grep "Developer ID Application"
  ```
- 자동 실행(인증서 발급 후): `bash tool/release_notarize.sh <notary-profile-name>` — 서명·공증·staple·`spctl` 검증까지 일괄.
- Entitlements: `macos/Runner/Release.entitlements`(`app-sandbox: false`), `DebugProfile.entitlements`(`app-sandbox: false`, `network.server: true`) — 신규 항목 추가 시 왜 필요한지 근거 명시.

## Windows — 현재 미서명 (알려진 상태)
- `windows/installer/claudle.iss` 주석에 명시: 미서명 설치파일 → SmartScreen 경고 발생, "추가 정보 → 실행"으로 우회(사내/비공식 배포엔 허용된 상태).
- 무경고를 원하면 EV/OV 코드사인 인증서 발급 후 `signtool`로 서명 — 현재 **보류** 중(BUILD.md에 명시).

## 체크리스트 (배포 전)
- [ ] macOS: `bash tool/release_adhoc.sh` 산출물 확인 — 스크립트 내 `codesign --verify --deep --strict` 통과 + `dist/Claudle-macOS-v<버전>.zip` 생성
- [ ] macOS: 수령자 안내에 `xattr -dr com.apple.quarantine` 포함 확인(`tool/dist_readme_adhoc.txt`)
- [ ] macOS(공증 재개 시에만): `security find-identity` 로 인증서 유효기간 확인 → `spctl -a -vv <앱경로>` 로 공증 통과 확인
- [ ] Windows: `pubspec.yaml` version ↔ `claudle.iss` AppVersion 일치 확인(드리프트 이력 있음)
- [ ] Windows: EV/OV 서명 도입 여부는 별도 결정 사항(현재 계획 없음) — 임의로 서명 파이프라인 추가하지 말 것
