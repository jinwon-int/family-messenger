# 한데 스토어 자산 (3차-B)

원본: Claude Design 「한데앱 및 웹 디자인 개선 – Hande 3차-B.html」(파일보관함, sha256 `a528b823…`). 정본 마크 `../icons/hande-mark-master.svg`(점 크림3·파랑3 교대).

| 파일 (`out/`) | 용도 | 규격 |
|---|---|---|
| `play-icon-512.png` | Play 아이콘 | 512×512 RGB, 알파 없음, 사각형 꽉 채움(모서리는 Play가 깎음) |
| `play-feature-1024x500.png` | Play 피처 그래픽 | 왼쪽 전경 마크 300 + 워드마크 96 · 부제 30/600 · 보조 20, 좌우 여백 96, 가운데 아래 1/3 글자 없음 |
| `og-1200x630.png` | OG(정책 사이트·소개) | 가운데 630×630 안에 마크·워드마크·부제, 하단 모노 URL |
| `play-0N-template.png` | Play 스크린샷 틀 ×5 | 1080×1920, 캡션 76/700 + 44, 위 여백 104, 기기 너비 73%, 테두리 20 #23283C |
| `iphone-0N-template.png` | iPhone 6.9″ 스크린샷 틀 ×5 | 1320×2868, 위 여백 150, 기기 너비 76% |

스크린샷 5장 순서·캡션: ① 서버 찾기 「가입 없이, 가족 서버로」 ② 대화 목록 「오늘 밤, 모닥불에 한데 모여」 ③ 대화(불지기 답장·허락 카드) 「불지기는 먼저 허락을 구해요」 ④ 새 기기 승인 「새 기기는 내 기기에서 승인」 ⑤ 설정 「밤에도, 밝은 곳에서도」.

## 만들기 / 합성
```bash
python3 make-assets.py                               # 아이콘·피처·OG·틀 10장 → out/
python3 make-assets.py --shot play 3 capture.png     # 실기기 캡처를 틀 3번에 합성 → out/play-03.png
python3 make-assets.py --shot iphone 4 capture.png   # → out/iphone-04.png
```
headless Chrome 필요. 워드마크 글꼴은 `fonts/questrial-latin.woff2`(Questrial, OFL — 캔버스 내장본, 워드마크 전용).

촬영 체크리스트(디자이너): 밤 테마 · 상태 막대 9:41·배터리 가득 · 예시 이름만(실명·실제 번호 금지) · 잠금화면 미리보기 경고 안 뜬 상태 · 지문은 예시 값 · 허락 카드는 대상·내용·영향 3줄 다 보이게 · 키보드 내림 · Android는 제스처 막대 보이게. 캡처는 기기 안쪽 칸에 가로 맞춤.

문구: `store-listing.md`.
