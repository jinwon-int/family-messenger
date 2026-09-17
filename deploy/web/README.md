# deploy/web — 패밀리챗 웹 앱 서빙 (1단계, Element 병행)

`web/app`의 dist 번들을 루프백으로 서빙하는 systemd 유닛이다. 터널(Cloudflare)이 유일한
노출 경로이며, 홈서버 API는 `matrix.<도메인>`(CORS `*` 허용, 2026-09-16 실측)을 그대로
쓴다. Element(`chat.<도메인>`)와 별개 구성 — 오너 결정(#92, 2026-09-16)에 따라 전환 승인
시점까지 Element가 운영 클라이언트로 유지된다.

| 파일 | 용도 |
|---|---|
| `family-chat-web.service` | `web/app/serve.mjs`로 dist 서빙(127.0.0.1:8090, 터널 전용 — 바인딩은 루프백 고정) |
| `build.sh` | `npm install` + `npm run build`(Node >= 22). 설치·갱신 때마다 실행 |

설치(예시 — 실제 경로·호스트명은 노드에 맞춘다):

```bash
bash deploy/web/build.sh
install -m 0644 deploy/web/family-chat-web.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now family-chat-web
curl -s http://127.0.0.1:8090/ | grep -o "<title>[^<]*"        # 껍데기 응답 확인
```

갱신: `git pull` → `bash deploy/web/build.sh` → `systemctl restart family-chat-web`.

설정(선택): `web/app/config.json`(git-ignored, `config.example.json` 참고)에 `homeserverUrl`을 적으면 로그인 화면이 홈서버 주소를 미리 채우고 "고급"으로 접어 두어 가족은 아이디·비밀번호만 입력한다(펼쳐서 바꿀 수 있음). 파일보관함 URL을 적으면 빌드가
`dist/config.json`으로 싣고 앱 오른쪽 보관함 pane에 "파일보관함" 탭(iframe)이 생긴다. 파일이 없으면 첨부 탭만
보인다. 임베드 대상 호스트는 이 앱 오리진의 프레임 삽입을 허용해야 하고(`frame-ancestors`), 접근 통제(예: Cloudflare
Access)가 있으면 가족 계정이 허용 목록에 있어야 한다 — 첫 로그인은 "새 창에서 열기"로 한다.

터널 hostname 라우팅(예시: `app.<도메인>` → `http://127.0.0.1:8090`)은 Cloudflare 쪽
설정이며, 이 저장소는 도메인·터널 ID를 갖지 않는다.
