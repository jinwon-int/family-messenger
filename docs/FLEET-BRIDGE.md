# 전체 플릿의 가족 메신저 참여

**개발 방향 변경:** [자체 메신저 계획](OWN-SYSTEM.md)에 따라 새 메시징 프로토콜로
12개 플릿을 연결한다. 아래 Matrix ID·중앙 연결부 구성은 이전 설계이며 확대 실행은 보류했다.
노드별 신원·운영자 권한·승인/취소·불확실 작업·12개 실제 응답의 검증 요구는 재사용한다.

2026-09-08 운영자 요청으로 연결 대상을 서서 단독에서 공식 플릿 12개로 확장한다.
이 문서는 구현 요구와 검증 기준이며 **현재 봇 연결이 배포되었다는 뜻이 아니다**.
구현 추적: [ccc-node #1602](https://github.com/jinwon-int/ccc-node/issues/1602).

## 참여 계정

| 이름 | 노드 | 예정 Matrix ID |
|---|---|---|
| 서서 | seoseo | @seoseo:matrix.seoyoon-family.com |
| 등애 | dungae | @dungae:matrix.seoyoon-family.com |
| 소교 | sogyo | @sogyo:matrix.seoyoon-family.com |
| 노숙 | nosuk | @nosuk:matrix.seoyoon-family.com |
| 방통 | bangtong | @bangtong:matrix.seoyoon-family.com |
| 육손 | yukson | @yukson:matrix.seoyoon-family.com |
| 순욱 | soonwook | @soonwook:matrix.seoyoon-family.com |
| 곽가 | gwakga | @gwakga:matrix.seoyoon-family.com |
| 진군 | jingun | @jingun:matrix.seoyoon-family.com |
| 공명 | gongmyoung | @gongmyoung:matrix.seoyoon-family.com |
| 공융 | gongyung | @gongyung:matrix.seoyoon-family.com |
| 대교 | daegyo | @daegyo:matrix.seoyoon-family.com |

계정은 일반 사용자 권한으로 생성하고 기존 동명 계정을 자동 인수하지 않는다.
노드 목록은 운영 배포 설정으로 주입하며 ccc-node 코어에 이 명단을 고정하지 않는다.
기존 가족방에 12개 봇을 자동으로 초대하지 않는다.

## 대화와 권한

- 운영자와 각 에이전트의 비공개 개인방: 해당 노드가 응답한다.
- 별도 플릿 공용방: Matrix mention으로 지목된 노드만 응답한다. 모든 노드가 응답하는 호출은 초기 버전에서 제공하지 않는다.
- 봇이 참여한 암호화 방의 내용은 그 봇이 복호화할 수 있다. 지목 여부는 응답 조건이지 열람 권한을 나누는 경계가 아니다.
- 초기 작업 실행 허용자는 운영자 `@jinon86:matrix.seoyoon-family.com`만. 가족 계정 발급과 서버 작업 권한은 별도로 관리한다.
- 봇끼리 자동 응답을 이어가지 않는다. 방 이름·표시 이름이 아니라 검증된 계정 ID와 허용된 room ID로 판단한다.
- 노드·방·발신자별 세션을 분리한다. Telegram 대화 기록을 자동 이관하지 않는다.
- E2EE 키는 영구 장치별로 보관·백업한다. 사용자의 복구 키를 수집하지 않으며 복호화 실패를 평문 전환으로 숨기지 않는다.

## 연결 구조

우선 검증할 구조는 **육손의 Matrix 연결부 + 각 노드의 ccc-node 실행부**다.
육손에서 나머지 11개 노드에 기존 SSH 경로로 BatchMode 접속이 성공했다(2026-09-08).
이는 연결 가능성 점검이며 provider 응답이나 채널 동작을 증명하지 않는다.

연결부는 노드별 Matrix 계정·암호화 장치·수신 진행 위치를 관리한다.
작업은 해당 노드의 provider/model·작업 경로·OS 사용자로 실행한다.
AI/GitHub 자격 증명은 원래 노드에 유지한다. 고정된 호출 규약으로 요청을 전달하고
메시지나 첨부파일명을 SSH 셸 명령에 삽입하지 않는다.

ccc-node의 AgentRuntime/AgentSession과 ProjectChatHandler는 재사용 후보지만,
현재 TelegramBot/bot_ports에는 Telegram 타입 결합이 남아 있다. 승인·취소·중간 응답·
파일 전송·메모리 경계를 보존하는 transport를 먼저 구현하고 검증한다.

노드별 작업 대기열·동시 실행 상한·오류 상태를 분리해 한 노드가 끊겨도 다른 노드가 응답하도록 한다.
Matrix long polling과 오류 시 backoff를 사용한다. 이벤트 ID와 전송 transaction ID를 영구 기록해
재접속 때 같은 요청/답변이 반복되지 않도록 한다. 실행 도중 연결이 끊겨 결과가 불확실한 작업은
상태 확인 없이 자동 재실행하지 않는다. 승인·중단 요청은 긴 작업 뒤에 대기시키지 않는다.

사진·영상·일반 파일은 인증된 Matrix 미디어 API로 전달한다. 암호화 무결성·크기 제한·
파일명/경로를 검증하며 임의 URL을 내려받거나 실행하지 않는다. 통화는 기존과 같이 범위 밖이다.
에이전트가 답변을 생성하는 데 필요한 내용은 해당 AI 제공업체에 전달될 수 있다.

## 적용과 완료 기준

1. 서서 전용 시험방에서 실제 provider 텍스트·암호화·첨부·승인/거절·취소를 검증한다.
2. Linux 노드를 확대 적용하고 공융·대교의 Android 실행 환경을 별도로 검증한다.
3. 12개 노드별 실제 응답과 두 기기 암호화 왕복, 비허용 발신자 차단, 이벤트 중복,
   재시작 복구, 노드 단절, 첨부 왕복, 장치 키 복구를 기록한다.
4. 기존 Telegram 채널은 검증 기간의 예비 통로로 유지한다. 알림 이중 발송 방지와
   진행 중 작업 인계까지 확인한 후 주 채널을 전환한다.

계정 생성·방 초대·온라인 표시만으로 노드 연결 완료를 선언하지 않는다.
휴대폰 푸시·Element 앱 호환성은 기존 모바일 과제와 함께 검증한다.
