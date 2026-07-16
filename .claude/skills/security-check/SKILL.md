---
name: security-check
description: Claudle 보안 점검 — OAuth 토큰 취급, 로컬 파일 접근, 민감정보 로깅. $ARGUMENTS로 대상 지정.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# security-check

`$ARGUMENTS`로 파일/디렉토리를 받아 이 프로젝트의 실제 위협 표면(로컬 데스크톱 앱, 외부 서버 없음, Claude OAuth 토큰 소비)에 맞춰 점검한다. 범용 취약점 탐지는 네이티브 `/security-review`가 diff에서 더 깊게 담당한다.

## 위협 모델
- 외부 백엔드 없음 — 유일한 네트워크 호출은 Claude OAuth `usage` 엔드포인트(구독 한도 조회, `LimitsController` 60s 폴링) 뿐.
- 신뢰 경계는 사실상 "이 앱이 로컬 파일시스템/키체인에서 무엇을 읽고 어디에 쓰는가"에 있다.

## 인증/토큰 (`lib/data/limits/claude_credentials.dart`)
- `accessToken`/`refreshToken`은 **절대 로그로 남기지 않는다**(파일 자체 주석에 명시된 불변식) — `print`/`debugPrint`/예외 메시지에 토큰 문자열이 섞이지 않는지 확인.
- macOS: 키체인(`security find-generic-password`) 우선, 실패 시 평문 `.credentials.json` 폴백. Windows/Linux는 처음부터 평문 파일 — **새 코드가 이 평문 파일 경로를 로그·에러 메시지에 그대로 노출하지 않는지** 확인(경로 자체는 민감하지 않지만 내용을 덤프하면 토큰 유출).
- 토큰은 매 폴링마다 다시 읽는 설계(Claude Code가 갱신한 최신 토큰을 얻기 위함) — 앱이 자체적으로 토큰을 캐시/영속화하는 코드를 추가하지 않았는지(캐시하면 만료·회전된 구토큰이 DB 등에 남을 위험).

## 로컬 파일 접근
- `ClaudePathResolver`가 읽는 대상은 사용자의 **Claude Code 세션 로그 전체**(jsonl) — 프롬프트/도구 호출 내용이 포함될 수 있다. 이 데이터를 로컬 `usage.db` 밖(예: 원격 전송, 클립보드, 파일 export)으로 내보내는 코드가 추가된다면 반드시 사용자 동의 흐름 필요.
- `usage.db`는 `path_provider`의 Application Support 디렉토리(OS가 보호하는 사용자 전용 경로)에만 쓴다 — 임의 경로/공유 디렉토리에 쓰는 변경은 의심.

## 엔트타이틀먼트(macOS)
- `Release.entitlements`/`DebugProfile.entitlements`: `com.apple.security.app-sandbox = false`(샌드박스 미사용), `com.apple.security.network.server = true`(로컬 서버 리스닝 권한 — 실제 용도 확인 필요, 신규 네트워크 서버 코드 추가 시 이 권한이 왜 필요한지 재검토).

## 배포 채널
- Windows 설치파일은 **미서명**(`windows/installer/claudle.iss` 주석에 명시, SmartScreen 경고 발생) — 새로 추가되는 다운로드/업데이트 경로가 이 사실을 사용자에게 숨기지 않는지, 위조 배포 채널과 혼동될 여지가 없는지 확인.
