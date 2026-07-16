---
name: git-summary
description: 현재 변경사항 기반 커밋 메시지/PR 설명 생성 (Conventional Commits, 한국어)
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
---

# git-summary

현재 브랜치의 변경 사항을 분석하여 커밋 메시지 또는 PR 설명을 생성한다.

## 형식
`{type}[(scope)]: {한국어 설명}` — 자세한 규칙은 `/changelog` 참조.

| type | 용도 |
|---|---|
| feat | 새 기능 |
| fix | 버그 수정 |
| chore | 버전/설정/의존성 |
| docs | 문서 |
| refactor | 리팩토링 |
| test | 테스트 |

scope는 플랫폼 한정 변경일 때 사용(`(windows)`, `(macos)`).

## PR 설명 형식
```markdown
## Summary
- 변경 요약 1~3줄

## Test plan
- [ ] fvm flutter test
- [ ] fvm flutter analyze
- [ ] (플랫폼 변경 시) macOS/Windows 양쪽 수동 실행 확인
```

## 커밋 전 확인
- `pubspec.yaml` version을 올렸다면 `windows/installer/claudle.iss`의 `AppVersion`도 함께 바뀌었는지 확인(과거 드리프트 발생 이력 있음).
- `.claude/`는 `.gitignore`에 있어 `git status`에 잡히지 않음 — 스킬/설정 변경은 커밋 대상이 아님이 정상.
