# Matrix 연결부의 수신·응답 저장 기반

`python3 -m unittest discover -s tests -v`로 기존 검사와 함께 검증한다.
`scripts/fleet_core.py`는 네트워크/AI 호출 없이 사용할 수 있는 기반 모듈이다.
아직 상시 실행 Matrix 브리지나 전체 플릿 배포를 제공하지 않는다.

## 호출 계약

1. SDK가 Matrix 서버의 이벤트를 인증·복호화한다. `Policy.admit`의 `decrypted`는
   메시지 JSON에서 읽지 말고 SDK의 검증 결과에서 전달한다. 허용 방·발신자 목록은
   운영자 설정이며 메시지 내용으로 변경하지 않는다. 개인방 구성원 검증과 봇의 초대 수락은 adapter 책임이다.
2. 계정마다 별도 0700 디렉터리의 `Store` 하나를 실행 기간 내내 유지한다.
   SQLite와 잠금 파일은 0600이고 두 번째 프로세스는 잠금을 획득하지 못하면 종료한다.
   상태에는 복호화된 요청/답변이 저장되므로 일반 로그로 복사하지 않는다. 백업은 암호화한다.
3. 승인된 이벤트 목록과 해당 `/sync` 응답의 next_batch를 `accept_batch`로 함께 커밋한다.
   실패하면 SDK의 메모리 sync 위치를 그대로 다음 요청에 사용하지 말고 Store의 마지막 token으로 재시도한다.
   SDK 암호화 to-device 상태와 동기화 위치를 어떻게 결합할지는 다음 transport 구현에서 검증한다.
4. `claim`으로 실행을 확정한 뒤 AI를 호출한다. 같은 계정·방·발신자의 이전 결과가 전달되기 전에는
   다음 요청을 시작하지 않는다. 다른 대화는 독립적으로 claim할 수 있다.
5. `finish`는 최종 답변과 provider 세션 ID를 함께 기록한다. outbox의 안정된 txn_id로 Matrix 응답을
   보낸 뒤 성공 응답을 확인한 경우에만 `delivered`를 호출한다. pending outbox가 있으면 access token/device
   교체를 금지한다. 이 단계의 문자열 상한은 답변 64KiB이며 UI 분할은 별도 구현 대상이다.
6. 중단된 running 항목은 재개 시 uncertain으로 바뀐다. 실행 결과를 확인한 후 명시적으로
   `resolve_uncertain`로 안내를 남긴다. 이 메서드는 재실행을 허용하지 않는다.

같은 event ID의 서로 다른 본문/발신자는 오류다. 이미 처리한 이벤트를 다시 받아도 실행하지 않는다.
수신 대기 한도는 계정 128개·대화 32개(설정 가능), 요청은 UTF-8 16KiB다. 큐 포화 시 배치 전체와
sync token이 롤백된다. 완료 이력은 중복 방지를 위해 보존하며 자동 삭제하지 않는다.
운영 전에 보관 용량 경보와 보존/아카이브 정책을 연결해야 한다.

## 아직 구현해야 할 경계

E2EE device trust·키 복구, room membership 변화, sync gaps/backfill, to-device 재복호화,
장기 작업 중 승인/거절/취소의 별도 입력 경로, 첨부 전송, provider 호출 및 실행 정책,
오류/backoff·health·배포 수명주기는 #1602/#10의 다음 단계다. 일반 텍스트 요청만 이 모듈의 범위이며
미구현 메시지 종류를 실행 요청으로 해석하지 않는다. E2EE/권한 경계를 검증하기 전 운영 봇에 적용하지 않는다.
