#!/bin/bash
# Claudle 사내 배포(ad-hoc): 배포 게이트 → 릴리스 브랜치 → 재빌드 → ad-hoc 재서명 → zip.
#
# 공증(Developer ID)은 인증서 권한벽(Account Holder 전용)으로 보류 → 이 경로는
# ad-hoc 서명으로 배포하고, 수령자가 다운로드 후 quarantine 을 1줄로 해제한다
# (tool/dist_readme_adhoc.txt 안내). 무경고 배포가 필요하면 tool/release_notarize.sh.
#
# 산출물: dist/Claudle-macOS-v<버전>.zip = Claudle/Claudle.app + 설치방법.txt
#   (버전은 pubspec.yaml 의 version 에서 자동으로 읽는다 → 배포본 구분)
# 기록:   v<버전> annotated 태그 = 이 zip 이 어느 소스에서 나왔는지. dist/ 는 gitignore 라
#         git 에 아무 흔적도 안 남고, 그래서 "이 버전 이미 냈나" 를 확인할 방법이 없었다
#         (실제로 내용이 다른 v1.2.0 을 두 번 만들어 앞 것을 날렸다, 2026-07-17).
#         태그가 곧 그 기록이자 버전 재사용을 막는 가드다 — 문제가 생기면 `git checkout v<버전>`.
#
#         왜 브랜치가 아니라 태그인가: 기록은 **안 움직여야** 한다(브랜치는 커밋하면 따라
#         움직인다). 이 레포가 이미 v1.0.x 를 그렇게 쓰고 있고, v* 태그 push 는 Windows CI
#         까지 돌린다. 체크아웃 왕복도 필요 없다 — 트리가 이미 그 소스다(게이트 ①이 보장).
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
TAG="v${VERSION}"
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

# ② 버전 재사용 — 태그가 있다 = 그 버전은 이미 냈다. 내용이 다른 같은 번호가 도는 걸 막는다.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "ERROR: 태그 $TAG 가 이미 있다 → v$VERSION 은 이미 배포된 버전이다."
  echo "       pubspec.yaml 의 version 과 windows/installer/claudle.iss 의 AppVersion 을"
  echo "       **함께** 새 버전으로 올려라(Inno 는 pubspec 을 안 읽는다)."
  echo ""
  echo "       의도적 재빌드라면 먼저 치워라:"
  echo "         git tag -d $TAG && rm -f '$OUT'"
  exit 1
fi

# ③ 산출물 덮어쓰기 — 내용이 다른 같은 이름 zip 을 조용히 날린 적 있다(2026-07-17).
if [ -e "$OUT" ]; then
  echo "ERROR: $(basename "$OUT") 이 이미 있다. 덮어쓰지 않는다."
  echo "       의도한 재빌드라면 직접 지우고 다시 실행해라:"
  echo "         rm '$OUT'"
  exit 1
fi

# 기록할 커밋 — 지금 HEAD 다. 체크아웃해서 빌드하고 돌아오는 왕복은 하지 않는다:
# 게이트 ①이 트리를 클린으로 강제하므로 **지금 트리가 이미 그 소스**이고, 왕복은 아무것도
# 바꾸지 않으면서 실패 시 엉뚱한 브랜치에 남을 위험만 만든다.
COMMIT="$(git rev-parse --short HEAD)"

echo "▶ 릴리스 빌드(유니버설) — $TAG @ $COMMIT"
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

# 기록은 **zip 이 나온 뒤에만** 남긴다 — 빌드가 깨졌는데 태그가 남으면 재시도가 게이트 ②에
# 걸린다. annotated(-a)는 기존 v1.0.x 규약(`Claudle v<버전> — <요약>`)을 따른다.
git tag -a "$TAG" -m "Claudle v$VERSION (macOS ad-hoc)"

echo ""
echo "✅ 완료: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   기록: 태그 $TAG → $COMMIT (로컬 전용 — push 는 명시 요청 시에만)"
echo "         문제가 생기면 그 소스로: git checkout $TAG"
echo "   슬랙 전달 → 수령자는 /Applications 로 드래그 후 터미널에서:"
echo "     xattr -dr com.apple.quarantine /Applications/Claudle.app"
