# file-v2 — 분리 첨부 와이어 형식 (정본, #499)

첨부 파일 바이트를 MLS 경로 밖으로 빼는 형식이다. 파일은 보내는 기기가 파일마다 새 키로 암호화해 릴레이 **blob 저장소**
(`README.md` 「첨부 blob 저장소」, #505)에 올리고, MLS application 메시지에는 그 blob을 열 **설명자(descriptor)** 만 담는다.
Matrix의 "Sending encrypted attachments"와 같은 구조다. 웹·iOS·안드로이드·봇은 이 문서를 정본으로 따른다.

이전 형식 `file-v1`(첨부 1개 = MLS 메시지 1개, 평문 = 원본 파일 바이트, ≤ 5 MiB, `RELAY-APP.md` 「첨부」)은 v2 송신
전환 뒤에도 수신을 유지한다(종료 시점은 #499 결정 6).

## 1. MLS 메시지

- 종류: MLS **application** 메시지.
- 바깥(릴레이 행) `client_id`: `file-v2-<uuid>` — 정규식 `^file-v2-[a-f0-9-]{36}$`(소문자 uuid). v1과 같이 **표시 힌트일 뿐**
  인증 정보가 아니다(MLS AAD의 client_id는 여전히 기기 ID).
- 평문: UTF-8 **JSON 객체** 하나, 전체 **≤ 4 KiB**(4096바이트).

### 설명자 키 (정확히 이 집합 — 모르는 키가 하나라도 있으면 거부)

| 키 | 필수 | 형식 |
|---|---|---|
| `v` | ✓ | 숫자 `2` |
| `blob` | ✓ | 소문자 hex 64자 = **암호문**의 sha256 = 릴레이 blob id |
| `size` | ✓ | 정수, **평문** 바이트 수, 1 ~ 52,428,800(50 MiB) |
| `key` | ✓ | base64url(패딩 없음, 정규형) — 32바이트 AES-256 키 |
| `nonce` | ✓ | base64url(패딩 없음, 정규형) — 12바이트(96비트) GCM nonce |
| `mime` |  | 문자열 ≤ 100, `type/subtype`(영숫자와 `!#$&^_.+-`) — **표시 힌트**, 수신자는 신뢰하지 않음 |
| `name` |  | 문자열 1~255자, 제어 문자 없음 — **표시 힌트**, 저장 이름으로 쓸 때 마지막 경로 조각만 |
| `w`, `h` |  | 정수 1 ~ 20000 (이미지 크기 힌트) |

base64url 정규형: RFC 4648 §5 알파벳, `=` 패딩 없음, 다시 인코딩하면 같은 문자열(끝 비트가 0). 키·nonce의 디코딩 길이가
정확히 32·12가 아니면 거부한다. 같은 키의 중복은 JSON 파서 규칙을 따르므로 송신자는 만들지 않는다.

예시:
```json
{"v":2,"blob":"9f…(64 hex)","size":2481920,"key":"q1w2…(43자)","nonce":"a1b2…(16자)","mime":"image/jpeg","name":"사진.jpg","w":4032,"h":3024}
```

## 2. 암호

- **AES-256-GCM**, 파일마다 **새 무작위 키(32 B)와 nonce(12 B)** — 키·nonce를 다른 파일에 다시 쓰지 않는다.
- AAD = UTF-8 문자열 `hande-file-v2`.
- 암호문 = GCM 출력(평문 ‖ 16바이트 태그) → 암호문 길이 = `size + 16`.
- `blob` = sha256(암호문)의 소문자 hex. 릴레이도 같은 값을 id로 돌려준다(내용 주소).

## 3. 송신 (3단계에서 활성)

1. 파일 바이트(1 ~ 50 MiB) → 새 키·nonce로 암호화.
2. `POST /v2/rooms/{room}/blobs?device=<나>` 본문 = 암호문 원시 바이트 → 201(새로 저장) 또는 200(이미 있음),
   응답 `id`가 계산한 `blob`과 같은지 확인.
3. 설명자 JSON을 평문으로 MLS application 메시지 게시(`client_id = file-v2-<새 uuid>`).

업로드는 방이 이미 있고 보내는 기기가 구성원일 때만 된다(릴레이 게이트). 업로드 뒤 메시지 게시가 실패하면 같은 암호문·같은
설명자로 다시 게시한다(업로드는 멱등).

## 4. 수신

1. MLS 메시지를 해독 → `client_id`가 `file-v2-`면 평문을 설명자로 **엄격 검증**. 실패하면 "열 수 없는 메시지"로 표시하고
   **절대 텍스트로 보이지 않는다**. MLS 처리(ack)는 정상 진행.
2. 기기 이력에는 **설명자만** 보관한다(파일 바이트는 보관하지 않음 — 다시 볼 때 다시 받는다).
3. 화면에 보이거나 사용자가 열 때(지연):
   `GET /v2/rooms/{room}/blobs/{blob}?device=<나>` → 암호문 길이 = `size + 16` → sha256 = `blob` → GCM 복호화(AAD 포함) →
   평문 길이 = `size`. 하나라도 어긋나면 "첨부를 열 수 없음"(재시도 가능) — 타임라인은 계속 동작한다.
4. 표시: 미리보기 여부와 MIME은 **내용(매직 바이트)으로만** 정한다(v1과 같음). `mime`·`name`은 힌트이며 MIME으로 쓰지 않는다.

릴레이 응답: 403 `not_a_member`(구성원 아님·제거됨), 404 `no_such_blob`(보존 기간 지남), 410 `room_closed`.

## 5. 보안 성질

- 릴레이는 키를 보지 않는다 — blob 단독으로는 불투명한 암호문. 릴레이가 아는 것은 v1과 같은 크기·시각·게시 기기뿐.
- 키는 MLS 메시지 안에만 있어 MLS의 기밀성·전방 비밀성을 따른다. 방에서 제거된 기기는 이후 설명자를 해독하지 못하고,
  blob GET도 구성원 검사로 막힌다.
- `blob`(sha256) 결속과 GCM 태그로 blob 바꿔치기·변조를 탐지한다. AAD로 다른 용도의 GCM 암호문과 섞이지 않는다.
- MLS 경로에 실리는 것은 설명자(≤ 4 KiB)뿐이라 장부·동기화·NSE 부담이 파일 크기와 무관하다(#371·#495·#496의 원인 제거).

## 6. 구현 위치

- 웹(한데): `archive/experiments/openmls-browser/web/file-v2.js`(설명자·base64url·암복호화·안전한 파일명, 순수 함수),
  `archive/native-mls/web/hande/room.js`(수신·이력·지연 로드), `relay.js`(`blob()`), 이력 `history-store.js` 종류 `file-v2`.
- 릴레이: `archive/native-mls/server/blobs.go`.
- 안드로이드: `archive/native-mls/android/app/src/main/kotlin/com/seoyoon_family/hande/core/FileV2.kt`(설명자 엄격 검증·수신 분류, 테스트
  `FileV2Test.kt`). 정상 설명자 → 이력 kind `file-v2`(본문 = 「📎 첨부(n B)」 자리 표시, attachment 칸 = 설명자), 잘못된 설명자 →
  `undecryptable`(평문 버림). blob 받기·열기는 v1 첨부 미리보기와 함께 C 단계. 웹보다 엄격한 점: 중복 키·앞머리 BOM 거부.
- 봇: `archive/native-mls/bot/src/responder.rs` — `file-v2-` 첨부를 에이전트 턴으로 넘기지 않음(#514).
- iOS: 2단계 후속 PR(이 문서를 따른다).
