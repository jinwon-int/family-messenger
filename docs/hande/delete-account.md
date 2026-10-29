# 한데(Hande) 계정 및 데이터 삭제 안내

> Google Play 「계정 삭제 요청 URL」· App Store 「Privacy Choices」 와 공용. 앱 설정 화면의 「계정 및 데이터 삭제」 링크가 이 페이지를 연다. 게시 주소: `https://jinwon-int.github.io/family-messenger/hande/delete-account/` · 문의 **support@rnmaru.com** · 최종 수정 2026-10-29

## 한데의 「계정」이란
한데에는 아이디·비밀번호 계정이 없고 앱 안에서 계정을 만들지도 않는다. 「계정」은 두 가지의 조합이다.
1. **로그인 신원** — 서버 운영자가 허용한 Google 계정(Cloudflare Access 로그인). 허용 목록은 운영자가 관리한다.
2. **기기 기록** — 각 기기가 처음 설정에서 만든 기기 ID(`<이름>-android-…` / `<이름>-iphone-…`)와 서명 공개키·지문·상태(활성/폐기)·로그인 신원(`subject`)이 적힌 서버의 기기 정책 체인.

대화 내용은 종단간 암호화되어 서버에 **암호문으로만** 있고, 복호화된 기록은 각 기기 안에만 있다.

서버는 운영자마다 다르다(앱 첫 화면에서 고른 서버). 아래 절차는 rnmaru.com 을 운영하는 법인의 서버(`relay.seoyoon-family.com`)에 대한 것이고, 다른 운영자의 서버는 그 운영자에게 요청한다.

## 1. 지금 바로 — 이 기기의 자료 지우기(앱 안)
앱 → **설정**(대화방 목록·등록 대기·로그인 화면 오른쪽 위 ⚙) → **「이 기기 지우기」** → 확인.

지워지는 것: 이 기기의 암호화 키·그룹 상태, 복호화된 대화 기록(`messages.db`), 로그인 세션 값, 설정(서버·이름·읽음 위치), 기기 ID. 앱은 처음 설정으로 돌아가고 다음 등록은 **새 기기 ID** 로 한다(옛 ID 는 다시 쓸 수 없다). 되돌릴 수 없다. 앱 삭제도 같은 효과다.

이 기기 지우기로는 **서버의 기기 기록이 바뀌지 않는다**(기기 기록은 다른 기기·운영자의 승인으로만 바뀌는 변조 방지 체인이라 앱 혼자 지울 권한이 없다). 서버 쪽은 아래 2 를 요청한다.

## 2. 서버 쪽 — 기기 폐기 · 대화방 데이터 삭제 · 로그인 허용 해제(요청)
**support@rnmaru.com** 으로(또는 가족 운영자에게 직접) 다음을 적어 보낸다.
- 로그인에 쓴 Google 계정(이메일) — 본인 확인을 위해 **그 계정에서** 보내는 것이 가장 빠르다
- 기기 ID(앱 설정 화면 · 「내 기기」에 표시) 또는 「내 기기 전부」
- 요청 범위(해당하는 것 전부):
  - [ ] 기기 폐기(그 기기로는 더 이상 아무 요청도 할 수 없게)
  - [ ] 내가 참여한 대화방의 서버 데이터(암호문·메타데이터·읽음 위치) 삭제
  - [ ] 로그인 허용 목록에서 제외(더는 한데에 로그인하지 않음)

운영자가 하는 일(절차는 운영 문서 `docs/NATIVE-RELAY-OPERATIONS.md` 「기기 셀프서비스 운영」):
1. 요청자가 그 Google 계정의 주인인지 확인(해당 계정에서 보낸 메일, 또는 가족 운영자가 직접 확인).
2. 기기 폐기 — 체인에 `revoke` 기록(운영자 CLI `native-devices -revoke <기기 ID>`, 전부면 `-revoke-all <이름>`). 그 기기로는 어떤 요청도 할 수 없게 된다.
3. 대화방에서 제거 — 요청자의 기기를 참여 목록에서 뺀다(그룹 키가 갱신되어 이후 메시지는 그 기기로 풀 수 없다). 참여자 전원이 동의한 대화방은 닫고 데이터를 삭제한다(`-reset-room`). 다른 가족이 계속 쓰는 대화방은 요청자의 암호문·읽음 위치가 보존 기한(최대 30일, 첨부 60일)에 따라 자동 정리된다.
4. 푸시 토큰(iOS)·키 패키지·읽기 커서는 기기 폐기와 함께 제거되거나 만료된다.
5. 로그인 허용 목록(Cloudflare Access 정책)에서 제외(요청한 경우).
6. 처리 결과 회신 — 접수 후 **7일 이내**.

## 3. 삭제 뒤 남는 것(정직한 범위)
- **기기 정책 체인의 「폐기됨」 기록** — 기기 ID·서명 공개키·지문·로그인 신원(`subject`)·이름·폐기 시각. 체인은 변조 방지용 **불변(append-only) 기록**이라 지울 수 없으며, 폐기된 기기가 다시 살아나거나 같은 ID 가 재사용되는 것을 막는 용도 외에는 쓰이지 않는다.
- **아직 보존 기한이 안 지난 암호문** — 서버가 읽을 수 없는 바이트이며 최대 30일(첨부 60일) 안에 자동 삭제된다.
- **오프호스트 백업** — 서버 저장소의 사본이 최대 30일 보관된다. 백업 안의 데이터도 같은 기한에 사라진다.
- **다른 가족의 기기에 이미 전달된 메시지** — 각자의 기기 안에만 있고 서버에는 없다.
- 서버 로그(기기 ID·요청 경로, 내용 없음)는 30일이 지나면 지워진다.
- Cloudflare Access 로그인 로그는 Cloudflare 의 보존 정책을 따른다.

## 4. 문의
support@rnmaru.com — [개인정보처리방침](privacy.md) 6절 참고.

---

## English summary — Account and data deletion
Hande has no username/password accounts; your "account" is (1) the Google identity our operator allowed to log in through Cloudflare Access and (2) the device record (device ID, public signing key, fingerprint, state) in the server's device-policy chain. Messages exist on the server only as ciphertext.

1. **In the app, right now:** Settings (⚙) → **"Wipe this device"** → confirm. This deletes this device's keys, decrypted history, session and settings; the app returns to first-time setup with a new device ID. Deleting the app has the same effect. This does not change the server-side device record.
2. **Server side, by request:** email **support@rnmaru.com** from the Google account you log in with, give your device ID (Settings → "My devices") or "all my devices", and tick what you want: revoke the device, delete my room data, remove my login. The operator revokes the device (E3), removes it from rooms, and replies within **7 days**.
3. **What remains:** a tombstone in the append-only device-policy chain (device ID, public key, fingerprint, login subject, revocation time — kept only so a revoked device can never come back or be reused); ciphertext until its retention expires (30 days, attachments 60 days); off-host backups for up to 30 days; copies of messages already delivered to other family members' devices.

If you use Hande with a server run by someone else, contact that operator instead.
