---
name: changelog
description: git log 기반 변경 이력 생성 (Conventional Commits, 한국어)
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
---

# changelog

git log를 기반으로 변경 이력을 생성한다.

## 커밋 컨벤션 (관찰됨)
```
<type>[(scope)]: <한국어 설명>[ + <추가 설명>]
```
- 실제 로그 예시:
  - `feat: 메인 에이전트도 라이브에 + 이름표를 사람이 읽는 타이틀로`
  - `chore: v1.1.0 — 에이전트 시각화 반영 + Inno 버전 드리프트 해소`
  - `feat(windows): 우측 상단 항상-위 미니 패널(HUD) 모드`
  - `fix(windows): 리뷰 확정 4건 수정 — DIB ICO·창팝업·VC런타임·Inno6.3`
- type: `feat`, `fix`, `chore` 확인됨(`docs`/`refactor`/`test`는 Conventional Commits 표준 확장으로 사용 가능).
- scope는 선택적, 플랫폼명(`windows`, `macos`) 사용 사례 있음.
- `—`(em dash)로 부제 구분, `+`로 복수 변경 나열하는 스타일이 자주 쓰임.

## 실행
```bash
git log --oneline -20                      # 최근 커밋 훑기
git log --oneline v1.0.0..HEAD             # 태그 이후 변경(릴리즈 노트용)
git log --pretty=format:"%h %s" <range>    # 파싱용
```

## 출력 형식 (예시)
```markdown
## v1.1.0
### Features
- 메인 에이전트도 라이브에 + 이름표를 사람이 읽는 타이틀로 (afc1263)
- 에이전트 시각화 — 서브에이전트를 숲에서 뛰노는 동물로 (55bff93)

### Fixes
- ...

### Chore
- v1.1.0 — 에이전트 시각화 반영 + Inno 버전 드리프트 해소 (99ada34)
```

## 버전 태그 주의
- `pubspec.yaml`의 `version:`과 `windows/installer/claudle.iss`의 `AppVersion`을 **손으로 동기화**해야 한다(Inno가 pubspec을 읽지 않음). 릴리즈 변경 이력 생성 시 두 값이 일치하는지 함께 확인.
