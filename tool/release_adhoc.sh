#!/bin/bash
# Claudle 사내 배포(ad-hoc): 배포 게이트 → 릴리스 브랜치 → 재빌드 → ad-hoc 재서명 → zip.
#
# 공증(Developer ID)은 인증서 권한벽(Account Holder 전용)으로 보류 → 이 경로는
# ad-hoc 서명으로 배포하고, 수령자가 다운로드 후 quarantine 을 1줄로 해제한다
# (tool/dist_readme_adhoc.txt 안내). 무경고 배포가 필요하면 tool/release_notarize.sh.
#
# 산출물: dist/Claudle-macOS-v<버전>.zip = Claudle/Claudle.app + 설치방법.txt
#   (버전은 pubspec.yaml 의 version 에서 자동으로 읽는다 → 배포본 구분)
# 기록:   release/v<버전> 브랜치 = 이 zip 이 어느 소스에서 나왔는지. dist/ 는 gitignore 라
#         git 에 아무 흔적도 안 남고, 그래서 "이 버전 이미 냈나" 를 확인할 방법이 없었다.
#         브랜치가 곧 그 기록이자 버전 재사용을 막는 가드다.
# 사용: bash tool/release_adhoc.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# pubspec 의 "version: 1.0.1+2" 에서 표시버전(1.0.1)만 뽑아 파일명에 사용.
VERSION="$(grep -E '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*([0-9.]+).*/\1/')"
[ -n "$VERSION" ] || { echo "ERROR: pubspec.yaml 에서 version 을 읽지 못함"; exit 1; }

SRC="build/macos/Build/Products/Release/tokenbar.app"
OUT="$ROOT/dist/Claudle-macOS-v${VERSION}.zip"
README_SRC="$ROOT/tool/dist_readme_adhoc.txt"
BRANCH="release/v${VERSION}"
# STAGE(mktemp)는 게이트를 통과한 뒤에 잡는다 — 여기서 잡으면 임시폴더가 막혔을 때
# 게이트 메시지도 못 보고 죽는다(샌드박스에서 실제로 그랬다).

# ── 배포 게이트 ────────────────────────────────────────────────
# 셋 다 실제로 터진 사고에서 나왔다. 문서가 아니라 여기서 막는 이유: 스킬·에이전트·사람
# 세 진입 경로가 전부 이 스크립트를 지나간다(게이트는 가장 약한 경로만큼만 강하다).

# ① 더티 트리 — 커밋된 상태여야 release/ 브랜치가 "이 zip 의 소스" 를 진짜로 가리킨다.
#    커밋은 여기서 하지 않는다(임의 커밋 금지) — 사람이 하고 다시 부른다.
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: 커밋 안 된 변경이 있다 — 배포 전에 커밋해야 한다."
  echo "       (안 그러면 release/ 브랜치가 빌드된 소스와 다른 걸 가리킨다)"
  echo ""
  git status --short
  exit 1
fi

# ② 버전 재사용 — 브랜치가 있다 = 그 버전은 이미 냈다. 내용이 다른 같은 번호가 도는 걸 막는다.
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "ERROR: $BRANCH 가 이미 있다 → v$VERSION 은 이미 배포된 버전이다."
  echo "       pubspec.yaml 의 version 과 windows/installer/claudle.iss 의 AppVersion 을"
  echo "       **함께** 새 버전으로 올려라(Inno 는 pubspec 을 안 읽는다)."
  echo ""
  echo "       의도적 재빌드라면 먼저 치워라:"
  echo "         git branch -D $BRANCH && rm -f '$OUT'"
  exit 1
fi

# ③ 산출물 덮어쓰기 — 내용이 다른 같은 이름 zip 을 조용히 날린 적 있다(2026-07-17).
if [ -e "$OUT" ]; then
  echo "ERROR: $(basename "$OUT") 이 이미 있다. 덮어쓰지 않는다."
  echo "       의도한 재빌드라면 직접 지우고 다시 실행해라:"
  echo "         rm '$OUT'"
  exit 1
fi

# ── 릴리스 브랜치 ──────────────────────────────────────────────
# 빌드는 release/v<버전> 위에서 하고, 끝나면(실패해도) 원래 브랜치로 돌아온다.
# 빌드가 깨졌을 땐 브랜치를 남기지 않는다 — 남기면 재시도가 게이트 ②에 걸린다.
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_OK=0
cleanup() {
  git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || true
  [ "$BUILD_OK" = 1 ] || git branch -q -D "$BRANCH" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ 릴리스 브랜치 $BRANCH (끝나면 $ORIG_BRANCH 로 복귀)"
git checkout --quiet -b "$BRANCH"

echo "▶ 릴리스 빌드(유니버설)…"
fvm flutter build macos --release

[ -d "$SRC" ] || { echo "ERROR: 릴리스 빌드 없음: $SRC"; exit 1; }
STAGE="$(mktemp -d)/Claudle"
APP="$STAGE/Claudle.app"
mkdir -p "$STAGE"
cp -R "$SRC" "$APP"   # 폴더명 tokenbar.app → Claudle.app(표시명 정리)

# 원본 릴리스 번들은 "nested code modified" 상태일 수 있어, ad-hoc deep 재서명으로
# 봉인을 정상화한다(서명 없으면 Gatekeeper 가 "손상됨" 으로 오탐).
echo "▶ ad-hoc deep 재서명…"
codesign --force --deep --sign - "$APP"
echo "▶ 서명 검증…"
codesign --verify --deep --strict --verbose=2 "$APP"

# 배포 zip: 설치 안내문 동봉, --sequesterRsrc --keepParent 로 앱 번들 구조 보존.
[ -f "$README_SRC" ] && cp "$README_SRC" "$STAGE/설치방법.txt"
mkdir -p "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"

BUILD_OK=1   # 여기까지 왔으면 브랜치를 기록으로 남긴다(cleanup 이 안 지운다)

echo ""
echo "✅ 완료: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   기록: $BRANCH (로컬 전용 — push 는 명시 요청 시에만)"
echo "   슬랙 전달 → 수령자는 /Applications 로 드래그 후 터미널에서:"
echo "     xattr -dr com.apple.quarantine /Applications/Claudle.app"
