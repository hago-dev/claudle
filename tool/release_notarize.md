# Claudle Developer ID 무경고 배포 (서명 + 공증)

팀: **HAGO L&F INC** (Team ID `6UGQQRH395`)
자동화 스크립트: `tool/release_notarize.sh <notary-profile-name>`

자동화 전 **1회 수동 준비 2가지**(Apple 계정 인증이 필요해 사람만 가능):

---

## STEP 1 — "Developer ID Application" 인증서 생성

### 방법 A — Xcode (가장 쉬움)
1. Xcode 실행 → 메뉴 **Xcode → Settings…** (⌘,) → **Accounts** 탭.
2. 왼쪽에 Apple ID 가 보이면 OK. 없으면 좌하단 **"+"** → Apple ID 로그인
   (HAGO L&F INC 팀에 접근 권한 있는 계정).
3. 계정 선택 → 우하단 **"Manage Certificates…"**.
4. 좌하단 **"+"** → **"Developer ID Application"** 클릭 → 자동 생성·키체인 설치.
   - 이 항목이 **회색이거나 없으면** 그 계정이 Account Holder/Admin 이 아님
     → 회사 Apple Developer 관리자에게 요청하거나 관리자 계정으로 로그인.

### 방법 B — developer.apple.com (Xcode 계정이 안 될 때)
1. **키체인 접근** 앱 → 메뉴 **인증서 지원 → 인증 기관에서 인증서 요청…**
   → 이메일 입력, "디스크에 저장" 선택 → `CertificateSigningRequest.certSigningRequest` 저장.
2. https://developer.apple.com/account/resources/certificates → **"+"**
   → **Developer ID Application** → 위 CSR 업로드 → 생성 → `.cer` 다운로드.
3. 받은 `.cer` 더블클릭 → 키체인에 설치.

### 확인
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# → "Developer ID Application: … (6UGQQRH395)" 한 줄 나오면 성공
```

---

## STEP 2 — 공증용 자격증명 저장 (앱 전용 암호)

1. https://account.apple.com → 로그인 → **로그인 및 보안 → 앱 암호**
   → **"+"** → 이름 `claudle-notary` → 생성 → `xxxx-xxxx-xxxx-xxxx` 복사.
2. **본인 터미널**에서 아래 실행(앱 암호가 대화창/로그에 남지 않게 직접 실행 권장):
```bash
xcrun notarytool store-credentials claudle-notary \
  --apple-id <당신의-apple-id-이메일> \
  --team-id 6UGQQRH395 \
  --password xxxx-xxxx-xxxx-xxxx
```
   → 키체인에 `claudle-notary` 프로필로 저장(이후 암호 재입력 불필요).

---

## STEP 3 — 자동 실행 (내가 처리)

STEP 1·2 완료 후:
```bash
bash tool/release_notarize.sh claudle-notary
```
스크립트가 자동으로: 릴리스 앱 복사 → 하드런타임 서명 → notarize 제출·대기
→ staple → `spctl` 검증 → `~/Desktop/Claudle-macOS-notarized.zip` 생성.
받는 사람은 압축 풀고 드래그 → 더블클릭 → "열기"(xattr 불필요).
