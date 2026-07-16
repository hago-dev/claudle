---
name: app-icon-splash
description: 트레이/앱 아이콘 생성 파이프라인 가이드 (스플래시 없음 — 트레이 전용 앱)
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Bash
  - Glob
---

# app-icon-splash

Claudle은 스플래시 스크린이 없다(LSUIElement=true, 메뉴바/HUD 전용 앱이라 부팅 화면 개념이 없음). 이 스킬은 **트레이 아이콘 + 앱 아이콘** 파이프라인만 다룬다.

## 트레이 아이콘 (핵심 — 브랜드화 완료)
- 소스(SSOT): `tool/gen_run_dog.swift`(AppKit) — 러닝 푸들 6프레임 × 채움 11단계(0~100, 10씩) = 66 PNG를 `assets/tray/run/run_<frame>_<fill>.png`(56×34)로 생성. `assets/tray/run/*.png`는 **생성물**이지 손으로 관리하는 소스가 아니다.
- 예외 — `assets/tray/icon.png`/`icon@2x.png`는 **손으로 관리하는 소스**다(생성기 없음 — `gen_run_dog.swift`는 `run_*`만 쓴다). `gen_win_ico.dart`가 `icon.png`를 소비해 `icon.ico`를 만드므로, 이 계열에서 생성물은 `icon.ico` 하나다.
- macOS: PNG 그대로 `tray_manager`가 로드.
- **Windows는 PNG를 못 읽는다** — 시스템 트레이가 `LoadImage(IMAGE_ICON, LR_LOADFROMFILE)`로 아이콘을 읽는데, 이 API는 무압축 **DIB(BITMAPINFOHEADER)** 형식만 파싱하고 PNG-in-ICO는 매직바이트에서 거부한다. `tool/gen_win_ico.dart`가 PNG를 정방 투명 패딩 후 32bpp BGRA DIB `.ico`로 직접 인코딩.
- 재생성(아이콘 디자인을 바꿨을 때만 — 이미 커밋된 PNG/`.ico`는 보통 재생성 불필요):
  ```bash
  swift tool/gen_run_dog.swift assets/tray/run   # 1) 매트릭스 66 PNG (macOS 전용, 출력 디렉토리는 인자)
  fvm dart run tool/gen_win_ico.dart             # 2) PNG → DIB .ico
  ```
  1)은 프리뷰 `_sheet_fill.png`도 같은 디렉토리에 쓴다(커밋 대상 아님) — 2)가 `run/*.png`를 전부 훑으므로 지우고 돌릴 것.
  검증: 각 `.ico` 데이터 오프셋(22바이트)이 `28 00 00 00`(=40, BITMAPINFOHEADER)로 시작해야 함.
- Windows 트레이는 텍스트 타이틀 미지원 → 아이콘의 바이올렛 채움 높이가 유일한 상시-표시 신호, 헤드라인 텍스트는 툴팁으로 대체(`windows/installer/BUILD.md` 참고 섹션).

## 앱 아이콘 (Dock/작업표시줄용 — 현재 미브랜드화, 알려진 상태)
- macOS: `macos/Runner/Assets.xcassets/AppIcon.appiconset/` — 확인 필요(변경 이력 없음, 기본값 가능성).
- Windows: `windows/runner/resources/app_icon.ico` — **현재 Flutter 기본 아이콘 그대로**(`windows/installer/BUILD.md`에 명시). 트레이 동작과는 무관하며 교체는 선택 사항.
- 교체 시: 고해상도(256px+) 소스에서 표준 도구로 재생성(예: `flutter_launcher_icons` 패키지 도입은 새 의존성 추가이므로 필요성 먼저 확인 — 현재 미설치).

## 체크리스트
- [ ] 러닝 아이콘 디자인 변경 시 `assets/tray/run/*.png` 직접 편집 금지 — `gen_run_dog.swift` 수정 → 재실행 → `gen_win_ico.dart` 재실행 → PNG/`.ico` 함께 커밋
- [ ] 단, `assets/tray/icon.png`/`icon@2x.png`는 생성기가 없으므로 직접 편집이 유일한 경로 — 편집 후 `gen_win_ico.dart` 재실행으로 `icon.ico` 갱신
- [ ] Windows `.ico` 데이터 오프셋 검증(`28 00 00 00`)
- [ ] 앱 아이콘 브랜드화는 별도 요청 시에만(현재 트레이 아이콘만 브랜드화 완료 상태가 의도적일 수 있음 — 임의로 바꾸지 말 것)
