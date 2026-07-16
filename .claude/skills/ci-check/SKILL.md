---
name: ci-check
description: GitHub Actions(Windows 빌드) 파이프라인 분석 및 개선 제안
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Grep
---

# ci-check

`.github/workflows/build-windows.yml` 파이프라인을 분석하고 개선을 제안한다.

## 현재 구성
- 트리거: `workflow_dispatch`(수동) 또는 `push` tags `v*`.
- 러너: `windows-latest`.
- 스텝: checkout → Flutter 3.41.2 셋업(`subosito/flutter-action`, cache: true) → `flutter config --enable-windows-desktop` → `flutter pub get` → `flutter build windows --release` → Inno Setup 설치(`choco install innosetup`) → `ISCC.exe`로 `.iss` 컴파일 → 설치파일을 Artifacts로 업로드.
- macOS 빌드는 CI에 없음(로컬에서 `tool/release_notarize.sh`로 수동 실행 — 서명에 개인 Apple 계정/키체인이 필요해 CI 자동화 대상이 아님).

## 검사 항목
- **버전 정합성**: 태그(`v*`)로 트리거될 때 `pubspec.yaml` version과 `windows/installer/claudle.iss`의 `AppVersion`이 태그와 일치하는지 — 워크플로에 자동 검증 스텝이 없다(수동 동기화 의존, 과거 드리프트 이력 있음). CI에 `AppVersion` 파싱 → 태그 비교 스텝 추가를 고려할 만함.
- **캐싱**: `subosito/flutter-action`의 `cache: true`만 사용 — pub 캐시는 커버되나 Inno Setup 설치(`choco install`)는 매번 재설치(수 초~수십 초 수준, 최적화 우선순위 낮음).
- **테스트 게이트 부재**: 빌드 전에 `flutter test`/`flutter analyze` 스텝이 없음 — 깨진 빌드가 태그까지 올라갈 수 있음(현재는 로컬에서 사람이 확인 후 태그를 미는 것으로 보임).
- **아티팩트 검증**: 업로드된 exe가 실행 가능한지(SmartScreen 경고는 알려진 사실이라 검증 대상 아님) 자동 스모크 테스트는 없음.

## 출력 형식
```
## CI/CD 분석 결과

### 현재 구성
- 트리거: ...
- 스텝: ...

### 개선 제안
1. [우선순위] 설명 + 기대 효과
```
