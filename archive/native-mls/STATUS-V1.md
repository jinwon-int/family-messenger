# status-v1 — 에이전트 작업 상태 말풍선 (family-messenger#560)

매트릭스 브리지는 `⏳ Working — 10s | Bash: …` 한 줄을 **같은 메시지에 10초마다 덧써** 보여 주고 답이
오면 지운다. 한데 포트에는 메시지 편집이 없으므로 같은 UX를 **append-only** 로 만든다: 봇이
`status` 종류의 메시지를 계속 보내고, 앱은 그 종류를 **보낸이별 임시 말풍선 하나** 로 취급해
최신 것만 최하단에 그리며(새 status 가 오면 이전 것은 사라진다), 보낸이의 다음 일반 메시지(답)가
오면 지운다. 내용은 MLS 안(E2EE) — 도구 명령 조각이 릴레이에 평문으로 가지 않는다.

## 1. 와이어

| 층 | 규칙 |
|---|---|
| FLEET-WORKER 포트 (브리지 → 봇) | `{"type":"interim","turn_id":"t-12","text":"⏳ Working — 10s \| Bash: …","kind":"status"}` — `kind` 가 없으면 지금과 같은 일반 `interim`. 봇은 모르는 `kind` 를 일반 interim 으로 취급한다(옛 봇 호환: 그래서 브리지는 봇이 교체된 뒤에만 `status_frames` 를 켠다). |
| FLEET-WORKER 포트 — turn 밖 (ccc-node#2590) | `{"type":"notice","room":"dungae","text":"⏳ 대기 중 · PR #603 CI","kind":"status"}` — 턴이 끝난 뒤 남은 백그라운드 대기 줄. 봇은 같은 `status-<uuid>` 메시지로 게시한다(아래 행). 브리지는 대기가 남은 동안 ≤2분마다 다시 보낸다(앱 5분 만료 전에). 모르는 `kind` 는 일반 notice(옛 봇 호환 → 봇 교체 뒤에 브리지 설정을 켠다). |
| 릴레이 이벤트 (봇 → 앱) | application 이벤트, 바깥 `client_id` = **`status-<uuid v4 소문자>`** (`^status-[a-f0-9-]{36}$`; `file-v2-<uuid>` 와 같은 전례). 평문 = status 본문 UTF-8(그 자체가 사람이 읽는 한 줄). AAD/`client_id` 의 MLS 측 의미는 그대로(발신 기기 ID). |
| 릴레이 푸시 | `status-` client_id 의 application 이벤트는 **푸시하지 않는다**(APNs/NSE 가 5초마다 깨지 않도록). 저장·커서·보존 규칙은 다른 이벤트와 같다(보존 만료로 회수). |

## 2. 봇 (`native-mls-bot`)

- `interim` + `kind:"status"` → `Outbound::Status { seq, text }` → `client_id = status-<uuid>` 로 전송
  (echo 카운터 `<device>-echo-<n>` 는 건드리지 않는다). 저널 `agent_outbound` `kind=status`.
- 턴당 상한 `DEFAULT_STATUS_MAX`(720 ≈ 5초 주기 1시간) — `interim_max`(40) 와 **별도**. 넘으면 조용히 버린다.
- 수신 측 루프 가드: `status-` client_id 메시지는 **turn 으로 만들지 않는다**(첨부 `file-v1-/file-v2-` 와
  같은 자리, `is_attachment_client_id` 옆). 다른 봇의 status 가 peer turn 을 일으키면 안 된다.
- 답(`reply`)이 나가면 status 시퀀스는 끝난다 — 별도 clear 프레임은 없다(앱이 답을 보고 지운다).
- `notice` + `kind:"status"`(ccc-node#2590) → `Outbound::StatusNotice { room, text }` → 같은 `status-<uuid>` 전송.
  turn 이 없어도(대기 줄은 턴이 끝난 뒤에 온다), 있어도 게시한다. agent 방만(alert 방 제외). 방마다 20초에 1건
  (`DEFAULT_STATUS_NOTICE_MIN_SECS`), 넘으면 `Suppressed{kind:"status_notice_rate"}` — `notice_per_min` 과 별개.
  앱은 바뀌지 않는다: 보낸이(봇 기기)별 임시 말풍선·목록 줄 규칙 그대로(다음 일반 메시지·5분 무갱신에 사라짐).

## 3. 앱 (웹 한데 / iOS / Android)

- 분류: `client_id` 가 `status-` 접두 → kind `status`. **저장하지 않는다**(히스토리·DB 밖), 커서/ack 는 정상 전진.
- 표시: 방 타임라인 **맨 아래** 에 보낸이별 임시 말풍선 하나(흐린 톤, `⏳` 그대로). 같은 보낸이의 새 status 가
  오면 본문만 바뀐다(= "갱신"). 보낸이의 **다음 일반 메시지**(답·첨부)가 오면 말풍선을 지운다.
- 안전망: 마지막 status 가 **5분** 넘게 갱신되지 않으면 지운다(턴이 `uncertain` 으로 끝나 답이 없는 경우).
- **방 목록**: 말풍선이 떠 있는 동안 그 방 줄의 미리보기 자리에 최신 status 줄을 에이전트 색으로 보인다 — 목록에서 어느
  에이전트가 일하는 중인지 알 수 있게(오너 결정 2026-10-30). 답이 오거나 5분 만료로 말풍선이 사라지면 원래 미리보기로 돌아간다.
  목록 정렬·안 읽음은 바꾸지 않는다.
- 제외: 읽지 않음 표시, 「생각하는 중」 추정, 알림(NSE/푸시), 「내 마지막 말」 바, 대화 기록.
- 모양: 흐리게(반투명) 두지 않는다 — 에이전트 색 바탕·점선 테두리로 일반 말풍선과 구분만 한다(오너 2026-10-30).
- 옛 앱: `status-` 를 모르면 일반 글로 보인다(지금의 interim 과 같음) — 깨지지 않는다.

## 4. 브리지 (ccc-node `core/hande`)

- 설정 `status_frames: true` (기본 false, `interim_frames` 와 독립) → `TurnSink.status(text)` 의 `⏳` 줄을
  매트릭스 cadence(5초)로 `kind:"status"` interim 프레임으로 보낸다. `status_interims`(스로틀한 일반 interim,
  임시 조치)보다 우선한다. `None` 은 프레임 없음.
- 켜는 순서: 릴레이(푸시 예외) → 봇 교체 → 앱 배포 → 브리지 `status_frames`. 순서가 바뀌면 "일반 글"로
  5초마다 쌓인다(옛 봇/앱의 폴백).

## 5. 수용 기준

1. 한데 방에서 긴 작업 중 `⏳ Working — Ns | <도구>` 말풍선이 **하나** 보이고 제자리(최하단)에서 갱신된다(웹·iOS).
2. 답이 오면 사라진다. 일하는 동안 방 목록 줄에 status 줄이 보이고 답이 오면 원래 미리보기로 돌아간다. 안 읽음·알림에는 나타나지 않는다.
3. 릴레이는 status 이벤트에 푸시를 보내지 않는다(테스트).
4. 옛 봇/옛 앱이 섞여도 오류 없이 일반 글로 폴백한다.
