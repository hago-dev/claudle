; Claudle — Windows 설치 스크립트 (Inno Setup 6)
;
; 선행: Windows 에서  flutter build windows --release  실행(→ build\windows\x64\runner\Release\).
; 컴파일: Inno Setup 6 로 이 파일 열고 Build → Compile.
;         산출물 = windows\installer\dist\Claudle-Setup-<버전>.exe
;
; 미서명이라 실행 시 SmartScreen 경고 → "추가 정보 → 실행"(맥 quarantine 해제와 동일 성격).

#define AppName "Claudle"
#define AppExeName "tokenbar.exe"            ; exe 이름은 패키지명(tokenbar) 유지 — 표시명만 Claudle
; ⚠️ pubspec.yaml 의 version 과 손으로 맞춰야 한다 — Inno 는 pubspec 을 읽지 않는다.
; (exe 내부 버전은 Runner.rc 가 FLUTTER_VERSION_* 로 자동 동기 → 여기만 밀리면
;  "설치파일명·제어판은 구버전, exe 는 신버전" 인 물건이 나온다. 실제로 1.0.0 로 밀려 있었다.)
#define AppVersion "1.1.0"
#define AppPublisher "kr.hago"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; AppId 는 업그레이드 식별용 고정 GUID — 변경 금지(바꾸면 재설치가 별개 앱으로 취급됨).
AppId={{B8F3A1C4-2D6E-4A7B-9C0F-3E5D7A9B1C2E}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir=dist
OutputBaseFilename=Claudle-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 관리자 권한 없이 사용자 단위 설치(사내 배포에 적합) → {autopf} 는 사용자 폴더로 자동 해석.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startup"; Description: "Windows 시작 시 Claudle 자동 실행"; GroupDescription: "추가 작업:"

[Files]
; Flutter Release 출력 전체(exe·DLL·data\, VC++ 런타임 DLL 포함)를 통째로 설치.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
; 트레이 전용 앱 → 시작 시 자동 실행 옵션(선택).
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExeName}"; Description: "지금 Claudle 실행"; Flags: nowait postinstall skipifsilent
