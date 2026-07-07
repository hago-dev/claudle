# Claudle — Windows 빌드 & 설치파일 만들기

> 이 저장소는 macOS·Windows 공용 코드다. **Windows 빌드는 반드시 Windows 머신에서** 해야
> 한다(Flutter 는 macOS 에서 Windows 바이너리를 크로스컴파일하지 못한다).

## 0. 준비 (Windows 10/11 x64)

- **Flutter 3.41.2** (이 저장소의 `.fvmrc` 기준. `flutter --version` 으로 확인)
- **Visual Studio 2022** + "C++ 데스크톱 개발" 워크로드 (Flutter Windows 빌드 필수)
- **Inno Setup 6.3 이상** — https://jrsoftware.org/isdl.php (설치파일 컴파일용;
  `.iss` 의 `ArchitecturesAllowed=x64compatible` 가 6.3+ 를 요구. CI 는 최신판 자동 설치)

```powershell
flutter config --enable-windows-desktop
flutter doctor            # "Visual Studio - develop for Windows" 체크 확인
```

## 1. 의존성

```powershell
flutter pub get
```

## 2. (선택) 트레이 아이콘 재생성

트레이 `.ico`(66개)는 이미 커밋되어 있어 보통 건너뛴다. `assets/tray/`의 PNG 를 바꿨을 때만:

```powershell
dart run tool/gen_win_ico.dart
```

> Windows 시스템 트레이는 `.ico` 만 로드한다(PNG 실패). 이 툴이 PNG 매트릭스를 정방 투명
> 패딩 후 `.ico` 로 변환한다. `image` dev 의존성 필요(pub get 에 포함됨).

## 3. 릴리스 빌드

```powershell
flutter build windows --release
```

산출물: `build\windows\x64\runner\Release\` (`tokenbar.exe` + DLL + `data\` + VC++ 런타임 DLL).
이 폴더만으로 실행 가능하므로 **포터블 배포**가 필요하면 이 폴더를 zip 하면 된다.

## 4. 설치파일(.exe) 컴파일

Inno Setup 6 로 `windows\installer\claudle.iss` 를 열고 **Build → Compile**.

산출물: `windows\installer\dist\Claudle-Setup-1.0.0.exe`

## 5. 배포

미서명 설치파일이라 첫 실행 시 **SmartScreen** 경고가 뜬다 → **"추가 정보 → 실행"**
(macOS 의 quarantine 해제와 같은 성격). 사내 슬랙 전달 등 비공식 배포에 적합.

- 서명(SmartScreen 무경고)을 원하면 코드사인 인증서(EV/OV)가 필요하다 — macOS 공증과
  마찬가지로 별도 인증서 발급 후 `signtool` 로 서명. 현재는 보류.

---

## 참고 — Windows 동작 차이 (macOS 대비)

- **트레이 텍스트 없음**: macOS 메뉴바는 아이콘 옆에 "55% · 6m" 텍스트를 띄우지만, Windows
  시스템 트레이는 텍스트 타이틀을 지원하지 않는다 → 헤드라인을 **툴팁**(아이콘 hover)으로 표시.
  사용량 채움(아이콘의 바이올렛 높이)이 항상-보이는 유일한 신호이므로 그대로 유지.
- **자격증명**: Claude Code 는 Windows 에서 `%USERPROFILE%\.claude\.credentials.json` 평문
  파일에 OAuth 토큰을 저장한다(macOS 는 키체인). 코드가 자동으로 이 파일을 읽는다.
- **DB 위치**: `%APPDATA%\kr.hago\Claudle\usage.db` (Runner.rc 의 CompanyName\ProductName).
- **앱 아이콘**: 현재 Flutter 기본 아이콘. 브랜드 아이콘을 원하면 고해상도(256px) 푸들 소스로
  `windows\runner\resources\app_icon.ico` 를 교체(트레이 동작과 무관, 선택).

## 참고 — CI 로 자동 빌드(Windows 머신 없이)

GitHub Actions `windows-latest` 러너에서 `flutter build windows --release` + Inno Setup 컴파일을
돌려 설치파일 아티팩트를 뽑을 수 있다. 필요하면 워크플로를 추가한다(현재 미설정).
