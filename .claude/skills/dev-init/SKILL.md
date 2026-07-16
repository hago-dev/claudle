---
name: dev-init
description: 프로젝트 초기 셋업 (의존성 설치, fvm 버전 고정, 첫 실행)
user-invocable: true
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
---

# dev-init

Claudle(Flutter 데스크톱) 초기 개발 환경을 셋업한다.

## 실행 절차

1. **Flutter 버전 고정 확인** — `.fvmrc`가 `3.41.2`를 지정한다.
   ```bash
   fvm use          # 미설치 시 fvm install 먼저
   fvm flutter --version
   ```
   fvm 미사용 시 로컬 `flutter --version`이 3.41.2와 다르면 빌드/린트 결과가 CI(.github/workflows/build-windows.yml, 동일 버전 고정)와 어긋날 수 있다.

2. **의존성 설치**
   ```bash
   fvm flutter pub get
   ```

3. **플랫폼 활성화 확인** (데스크톱 전용 — ios/android 디렉토리 없음)
   ```bash
   fvm flutter config --enable-macos-desktop     # macOS에서
   fvm flutter config --enable-windows-desktop    # Windows에서(CI도 동일)
   ```

4. **실행**
   ```bash
   fvm flutter run -d macos     # macOS: 메뉴바 전용(LSUIElement) — 창은 숨김 상태로 시작
   fvm flutter run -d windows   # Windows: 우측 상단 항상-위 HUD 모드
   TOKENBAR_FORCE_HUD=1 fvm flutter run -d macos   # macOS에서 HUD 미리보기(검증용)
   ```

## 참고
- 로컬 DB(`usage.db`)는 최초 실행 시 Application Support 디렉토리에 자동 생성됨 — 별도 마이그레이션 단계 없음.
- 단가 데이터는 `assets/pricing/litellm_claude.json`에 번들 — 외부 설정/시크릿 불필요(전부 로컬, 서버 의존 없음. 예외: 구독 한도 조회는 Claude OAuth usage 엔드포인트를 60s 폴링).
- `.claude/`는 `.gitignore`에 등록되어 있어(레포 정책) 이 스킬 디렉토리 자체는 git에 커밋되지 않는다.
