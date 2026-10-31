# 한데 고유 UI 아이콘 세트 (2차-B B2)

24 뷰박스 · 선 1.6 · 둥근 끝/모서리 · `fill="none" stroke="currentColor"`. `data-role` 채움은 테마 토큰으로 칠한다
(`ember` #F59E42 / `ember-deep` #E8833A / `person` 크림 #FFD79A / `agent` 파랑 #61A6FA / `ink`; 낮불은 ember·ember-deep·person·ink = 먹 #1A1510, agent #2F6FC4).
불 세기: 켜진 갈래 = 채움, 꺼진 갈래 = 선만(`data-role="unlit"`, 밤 35% / 낮불 먹 선). 1 = 가운데, 2 = 가운데+왼쪽, 3 = 모두.
낮불 `seat`의 에이전트 점은 ◆(회전 네모)로 바꿔 그린다.

| id | 뜻 | iOS | Android |
|---|---|---|---|
| flame-1/2/3 | 불 세기 | `FlameIcon(level:)` | `FlameIcon(level)` |
| embers-out | 꺼진 자리 | `LogIcon` | `LogIcon` |
| keeper | 불지기 | — | — |
| fingerprint-rows | 지문(대조) | — | — |
| device-iphone/android/pc/web | 기기 | — | — |
| seat | 자리 | — | — |
| invite-bell | 초대 벨 | 목록 벨 | — |
| reorder | 순서 편집 | 목록 순서 | — |
| cover | 덮어 두기 | — | — |

SF Symbols ↔ Material Symbols(한데 고유가 아닌 것): 뒤로 chevron.left/arrow_back · 닫기 xmark/close · 더보기 ellipsis/more_vert · 첨부 plus/add ·
보내기 arrow.up/arrow_upward · 사진 photo/image · 파일 doc/description · 복사 doc.on.doc/content_copy · 공유 square.and.arrow.up/share ·
고정 pin/push_pin · 연결되면 보냄 clock/schedule · 다시 보내기 arrow.clockwise/refresh · 다음 chevron.right/chevron_right · 설정 gearshape/settings ·
주의 exclamationmark.circle/error · 맞춤 표시 checkmark/check.
