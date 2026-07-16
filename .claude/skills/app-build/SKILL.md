---
name: app-build
description: Claudle 플랫폼별 빌드 실행 (macOS ad-hoc 서명 zip, Windows Inno Setup 설치파일)
user-invocable: true
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
---

# app-build

macOS·Windows 각각의 빌드/배포 파이프라인을 실행한다. 이 앱은 데스크톱 전용(`ios/`, `android/` 없음) — 앱스토어 배포가 아니라 **직접 배포**(ad-hoc 서명 zip / Inno 설치파일)다.

## macOS

```bash
fvm flutter build macos --release
```
빌드 산출물만으로는 봉인이 깨진 상태라 Gatekeeper가 "손상됨"으로 오탐한다. **현재 실배포 경로**는:
```bash
bash tool/release_adhoc.sh
```
- 스크립트가 자동으로: **배포 게이트 3종**(아래) → 릴리스 재빌드(유니버설) → ad-hoc deep 재서명(`codesign --force --deep --sign -`) → 서명 검증 → `dist/Claudle-macOS-v<버전>.zip` 생성 → **`v<버전>` annotated 태그**(버전은 `pubspec.yaml`에서 자동 추출).
- ad-hoc 서명이라 수령자가 `xattr -dr com.apple.quarantine /Applications/Claudle.app` 한 줄 필요 — `tool/dist_readme_adhoc.txt`가 zip에 `설치방법.txt`로 동봉되는 수신자 안내문.

### `v<버전>` 태그 = 배포 기록
`dist/`는 gitignore라 **어떤 소스로 빌드했는지 git에 아무 흔적이 없다**. 그래서 "이 버전 이미 냈나"를 확인할 방법이 없었고, 실제로 내용이 다른 같은 번호(v1.2.0)를 두 번 만들어 앞 것을 날린 사고가 났다(2026-07-17). 태그가 그 기록이자 재사용 가드다 — **문제가 생기면 `git checkout v<버전>`으로 그 소스로 돌아간다.**
- **브랜치가 아니라 태그인 이유**: 기록은 안 움직여야 한다(브랜치는 그 위에 커밋하면 따라 움직인다). 이 레포가 이미 `v1.0.x`를 그렇게 쓰고 있고, `v*` 태그 push는 Windows CI(설치파일)까지 돌린다.
- **체크아웃 왕복 없음**: 게이트 ①이 트리를 클린으로 강제하므로 지금 트리가 이미 그 소스다. 브랜치를 따서 빌드하고 돌아오는 왕복은 아무것도 바꾸지 않으면서 실패 시 엉뚱한 브랜치에 남을 위험만 만든다(그래서 뺐다 — 병합도 당연히 no-op이었다).
- **로컬 전용** — push는 명시 요청 시에만.
- 빌드가 실패하면 태그를 남기지 않는다(남기면 재시도가 게이트 ②에 걸린다). zip이 나와야 기록으로 남는다.

### 배포 게이트 — 스크립트가 강제한다(문서 준수에 기대지 않는다)
진입 경로가 셋(`/app-build` 스킬 · `app-deployer` 에이전트 · 사람이 직접)인데 전부 이 스크립트를 지난다 → **게이트는 스크립트에 있다.** 걸리면 `exit 1`이고 부작용이 없다(브랜치·zip 안 건드림). 우회 플래그는 없다 — 사람이 아래 안내대로 치우고 다시 부른다.

| 게이트 | 조건 | 뜻 |
|---|---|---|
| ① 더티 트리 | `git status --porcelain`이 비어있지 않음 | 커밋해야 태그가 *실제 빌드된 소스*를 가리킨다. **스크립트는 커밋하지 않는다**(임의 커밋 금지) — 사람이 커밋하고 다시 부른다 |
| ② 버전 재사용 | `v<버전>` 태그가 이미 있음 | 그 버전은 이미 냈다 → `pubspec.yaml` + `claudle.iss`를 **함께** 올려라 |
| ③ 덮어쓰기 | `dist/Claudle-macOS-v<버전>.zip`이 이미 있음 | 내용이 다른 같은 이름 zip을 조용히 날리지 않는다 |

의도적 재빌드라면 사람이 치운다: `git tag -d v<버전> && rm -f dist/Claudle-macOS-v<버전>.zip`

⚠️ 게이트 ②는 **pubspec ↔ iss 일치 검사와 별개다.** 둘이 서로 맞아도 그 번호를 이미 썼으면 못 쓴다 — 실제로 "버전 동기화 정상"이라 보고해 놓고 이미 쓴 번호로 덮어쓴 사고가 그렇게 났다.

**공증(무경고) 배포는 보류 상태**:
```bash
bash tool/release_notarize.sh <notary-profile-name>
```
- Developer ID Application 인증서 미보유(Account Holder만 발급 가능) → 인증서가 없으면 스크립트가 첫 검사(`security find-identity`)에서 중단한다.
- 실행 전제는 1회 수동 준비 2가지(사람만 가능, `tool/release_notarize.md` STEP 1·2): ① "Developer ID Application" 인증서 발급, ② `xcrun notarytool store-credentials`로 공증 프로필 저장.
- 인증서가 생기면 스크립트가 자동으로: 릴리스 앱 복사 → 하드런타임 서명 → notarize 제출·대기 → staple → `spctl` 검증 → `~/Desktop/Claudle-macOS-notarized.zip` 생성.

## Windows (Windows 머신 필수 — macOS에서 크로스컴파일 불가)

```powershell
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release
```
산출물: `build\windows\x64\runner\Release\`(포터블 배포 가능, zip으로 충분).

설치파일(.exe) 컴파일: Inno Setup 6.3+ 로 `windows\installer\claudle.iss` 열고 Build → Compile → `windows\installer\dist\Claudle-Setup-<버전>.exe`.

**버전 동기화 필수**: `pubspec.yaml`의 `version`과 `.iss`의 `AppVersion`을 손으로 맞춰야 한다(Inno가 pubspec을 안 읽음 — 과거 실제 드리프트 발생, 커밋 `99ada34`).

미서명 설치파일 → 첫 실행 시 SmartScreen 경고("추가 정보 → 실행"). 무경고를 원하면 EV/OV 코드사인 인증서 필요(현재 보류 상태).

### CI (Windows 머신 없이)
`.github/workflows/build-windows.yml` — `workflow_dispatch` 수동 실행 또는 `v*` 태그 push 시 자동으로 `flutter build windows --release` + Inno 컴파일 → Actions Artifacts에 설치파일 업로드.

## 트레이 아이콘 재생성 (선택 — 보통 불필요)
`assets/tray/`의 PNG는 두 갈래이니 섞지 말 것(파이프라인 상세는 `/app-icon-splash`):
- `assets/tray/run/run_<프레임>_<채움>.png` 66개(6프레임 × 채움 11단계) = **생성물**. SSOT는 `tool/gen_run_dog.swift` — 손으로 고치면 다음 재실행 때 조용히 덮어써진다.
- `assets/tray/icon.png`, `assets/tray/icon@2x.png`(각 44x44) = **손으로 관리하는 소스**. 생성기가 없어 직접 편집이 유일한 경로.

러닝 푸들 모양을 바꿨을 때만 — 스크립트를 고쳐 재실행한다(macOS 전용, 출력 디렉터리가 인자):
```bash
swift tool/gen_run_dog.swift assets/tray/run   # 미추적 미리보기 _sheet_fill.png 도 같이 생김
```
그 다음(또는 `icon.png`만 손봤다면 이것만) `.ico`를 다시 뽑는다 — `run/` 안의 **모든** `*.png` + `icon.png`를 소비해 같은 이름의 `.ico` 생성:
```bash
fvm dart run tool/gen_win_ico.dart
```
⚠️ 위 스크립트를 방금 돌렸다면 `run/`에 `_sheet_fill.png`가 남아 있어 이것까지 집어간다(→ 미추적 `_sheet_fill.ico` 생성, 커밋 전 둘 다 삭제).
Windows 트레이는 `LoadImage(IMAGE_ICON)`이라 무압축 DIB `.ico`만 로드(PNG-in-ICO는 실패) — 이미 생성된 `.ico`는 레포에 커밋돼 있어 재빌드 시 다시 돌릴 필요 없음.
