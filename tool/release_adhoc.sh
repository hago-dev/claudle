#!/bin/bash
# Claudle 사내 배포(ad-hoc): 릴리스 재빌드 → ad-hoc deep 재서명 → 배포 zip.
#
# 공증(Developer ID)은 인증서 권한벽(Account Holder 전용)으로 보류 → 이 경로는
# ad-hoc 서명으로 배포하고, 수령자가 다운로드 후 quarantine 을 1줄로 해제한다
# (tool/dist_readme_adhoc.txt 안내). 무경고 배포가 필요하면 tool/release_notarize.sh.
#
# 산출물: dist/Claudle-macOS-v<버전>.zip = Claudle/Claudle.app + 설치방법.txt
#   (버전은 pubspec.yaml 의 version 에서 자동으로 읽는다 → 배포본 구분)
# 사용: bash tool/release_adhoc.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# pubspec 의 "version: 1.0.1+2" 에서 표시버전(1.0.1)만 뽑아 파일명에 사용.
VERSION="$(grep -E '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*([0-9.]+).*/\1/')"
[ -n "$VERSION" ] || { echo "ERROR: pubspec.yaml 에서 version 을 읽지 못함"; exit 1; }

SRC="build/macos/Build/Products/Release/tokenbar.app"
STAGE="$(mktemp -d)/Claudle"
APP="$STAGE/Claudle.app"
OUT="$ROOT/dist/Claudle-macOS-v${VERSION}.zip"
README_SRC="$ROOT/tool/dist_readme_adhoc.txt"

echo "▶ 릴리스 빌드(유니버설)…"
fvm flutter build macos --release

[ -d "$SRC" ] || { echo "ERROR: 릴리스 빌드 없음: $SRC"; exit 1; }
mkdir -p "$STAGE"
cp -R "$SRC" "$APP"   # 폴더명 tokenbar.app → Claudle.app(표시명 정리)

# 원본 릴리스 번들은 "nested code modified" 상태일 수 있어, ad-hoc deep 재서명으로
# 봉인을 정상화한다(서명 없으면 Gatekeeper 가 "손상됨"으로 오탐).
echo "▶ ad-hoc deep 재서명…"
codesign --force --deep --sign - "$APP"
echo "▶ 서명 검증…"
codesign --verify --deep --strict --verbose=2 "$APP"

# 배포 zip: 설치 안내문 동봉, --sequesterRsrc --keepParent 로 앱 번들 구조 보존.
[ -f "$README_SRC" ] && cp "$README_SRC" "$STAGE/설치방법.txt"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"

echo ""
echo "✅ 완료: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   슬랙 전달 → 수령자는 /Applications 로 드래그 후 터미널에서:"
echo "     xattr -dr com.apple.quarantine /Applications/Claudle.app"
