#!/bin/bash
# Claudle 릴리스: Developer ID 서명 → notarize → staple → 무경고 배포 zip.
#
# 전제(1회 수동, tool/release_notarize.md 참고):
#   1) "Developer ID Application: … (6UGQQRH395)" 인증서가 키체인에 설치됨
#   2) notary 자격증명 프로필 저장됨:
#        xcrun notarytool store-credentials <PROFILE> \
#          --apple-id <apple-id> --team-id 6UGQQRH395 --password <앱전용암호>
#
# 사용: bash tool/release_notarize.sh <notary-profile-name>
set -euo pipefail

PROFILE="${1:?사용법: bash tool/release_notarize.sh <notary-profile-name>}"
SRC="build/macos/Build/Products/Release/tokenbar.app"
STAGE="$(mktemp -d)/Claudle"
APP="$STAGE/Claudle.app"
OUT="$HOME/Desktop/Claudle-macOS-notarized.zip"
README_SRC="$(cd "$(dirname "$0")/.." && pwd)/tool/dist_readme_notarized.txt"

# Developer ID Application 인증서 자동 탐색(팀 무관 — 설치된 첫 항목)
IDENTITY="$(security find-identity -v -p codesigning \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
[ -n "$IDENTITY" ] || {
  echo "ERROR: Developer ID Application 인증서 없음. STEP 1(Account Holder가 발급) 먼저."; exit 1; }
# 인증서 CN "Developer ID Application: Name (TEAMID)" 에서 팀ID 추출
TEAM_ID="$(printf '%s' "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
echo "▶ 서명 ID: $IDENTITY  (팀 $TEAM_ID)"

[ -d "$SRC" ] || { echo "ERROR: 릴리스 빌드 없음: $SRC (fvm flutter build macos --release 먼저)"; exit 1; }
mkdir -p "$STAGE"
cp -R "$SRC" "$APP"

# 안쪽→바깥 서명(프레임워크/dylib 먼저, 그다음 앱). 하드런타임 + 보안 타임스탬프.
echo "▶ 중첩 코드 서명…"
while IFS= read -r -d '' f; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
done < <(find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 2>/dev/null)

echo "▶ 앱 서명…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "▶ 서명 검증…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶ notarize 제출(완료까지 대기, 보통 1~5분)…"
SUBZIP="$(mktemp -d)/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBZIP"
xcrun notarytool submit "$SUBZIP" --keychain-profile "$PROFILE" --wait

echo "▶ 티켓 staple + 최종 검증…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv "$APP"   # 기대: accepted, source=Notarized Developer ID

# 배포 zip(안내문 포함)
[ -f "$README_SRC" ] && cp "$README_SRC" "$STAGE/설치방법.txt" || true
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"
echo ""
echo "✅ 완료: $OUT"
echo "   받는 사람은 압축 풀고 /Applications 로 드래그 → 더블클릭 → '열기'. (xattr 불필요)"
