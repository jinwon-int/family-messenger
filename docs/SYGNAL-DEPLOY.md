# Sygnal 푸시 게이트웨이 — 배포·운영 런북

배포 파일은 [`deploy/sygnal/`](../deploy/sygnal/). 이 문서는 절차와 검증 기준이다.
관련 이슈: [#166](https://github.com/jinwon-int/family-messenger/issues/166)(이 패키지) ·
[#167](https://github.com/jinwon-int/family-messenger/issues/167)(웹앱 측) ·
[#165](https://github.com/jinwon-int/family-messenger/issues/165)(네이티브 iOS).

> **실제 도메인·이메일·키·터널 ID는 이 저장소에 쓰지 않는다.** `<>`는 배포 시 치환한다.

## 0. 전제

- 홈서버(Tuwunel)가 이미 운영 중이고, 게이트웨이로 아웃바운드 HTTP를 낼 수 있다.
- 컨테이너 런타임(podman 권장, docker 가능)이 있다.
- **게이트웨이만으로는 알림이 오지 않는다.** 웹앱이 pusher를 등록하고 서비스워커가
  `push` 이벤트를 처리해야 한다(#167). 두 쪽이 다 끝나야 알림 1건이 도착한다.

## 1. 사용자·디렉터리

sygnal은 컨테이너 **안에서** 비권한 사용자로 돌고, podman 자체는 root로 실행한다.
rootless podman을 쓰지 않는 이유는 `deploy/sygnal/sygnal.service` 상단 주석에 있다
(요약: `useradd --system`은 subuid를 할당하지 않고, 유닛 하드닝과 rootless podman이 서로를 깨뜨린다).

```bash
groupadd --system sygnal
useradd --system --gid sygnal --home-dir /nonexistent --shell /usr/sbin/nologin sygnal
install -d -o root -g sygnal -m 0750 /etc/sygnal

# 유닛의 SYGNAL_UID 에 넣을 값 — 컨테이너 안에서 이 UID:GID로 떨어뜨린다.
echo "SYGNAL_UID=$(id -u sygnal):$(id -g sygnal)"
```

설정과 키는 `/etc/sygnal`에 둔다(컨테이너 안에서는 `/sygnal`, 읽기 전용 마운트).
**서비스 사용자의 홈 디렉터리 안에 두지 않는다** — podman 저장소와 섞이면 안 된다.

## 2. 이미지 — 반드시 root로, digest로 당긴다

태그는 이동할 수 있다. `deploy/sygnal/sygnal.pins.json`의
`image.platform_digests["linux/amd64"]`를 쓴다.

> ⚠ **pull과 유닛이 같은 저장소를 봐야 한다.** `podman image exists`는 podman을 실행하는
> 사용자의 저장소를 본다. 유닛이 root로 돌므로 **pull도 반드시 root로** 한다.
> 다른 사용자로 받으면 `ExecStartPre`가 항상 실패해 서비스가 뜨지 않는다.

```bash
DIGEST=$(python3 -c 'import json;print(json.load(open("deploy/sygnal/sygnal.pins.json"))["image"]["platform_digests"]["linux/amd64"])')
sudo podman image pull "docker.io/matrixdotorg/sygnal@${DIGEST}"
sudo podman image exists "docker.io/matrixdotorg/sygnal@${DIGEST}" && echo "이미지 확보"
```

핀을 올릴 때는 **`sygnal.pins.json`과 `sygnal.service`의 `SYGNAL_IMAGE`를 함께** 바꾸고 PR로 기록한다.
`tests/test_sygnal_deploy_package.py`가 이 동기화를 검사한다.

## 3. VAPID 키 생성

```bash
sudo ./deploy/sygnal/gen-vapid-key.sh /etc/sygnal
sudo chown root:sygnal /etc/sygnal/vapid_* && sudo chmod 0640 /etc/sygnal/vapid_private_key.pem
```

컨테이너가 root로 키를 만들기 때문에(이미지에 `USER` 지시자가 없다) **root로 실행한다.**
비-root로 돌리면 스크립트가 개인키 권한을 0600으로 바꾸지 못하고 그 사실을 알린 뒤 중단한다.

산출물 3개:

| 파일 | 성격 | 쓰임 |
|---|---|---|
| `vapid_private_key.pem` | **비밀** — 생성 시 0600, 배포 시 `root:sygnal 0640`(컨테이너가 그룹으로 읽는다) | `sygnal.yaml`의 `vapid_private_key` |
| `vapid_public_key.pem` | 공개 | 보관 |
| `vapid_application_server_key.txt` | 공개 | 웹앱 `config.json` → `PushManager.subscribe({applicationServerKey})` |

**비밀 취급**: 개인키를 로그·이슈·채팅·저장소에 넣지 않는다. 노출되면 교체가 유일한 대응이다.
스크립트는 기존 키가 있으면 **덮어쓰지 않고 중단**한다 — 덮어쓰면 가족 전원의 구독이 죽기 때문이다.

**생성 직후 백업한다.** sygnal은 무상태라 정기 백업 대상이 아니지만, VAPID 개인키만은 예외다.
**키를 잃으면 폭발 반경이 키 교체와 같다** — 가족 전원이 알림을 다시 켜야 한다.
운영 호스트 밖에 암호화해 1부 보관하고, 보관 위치를 운영 기록에 남긴다(값이 아니라 위치만).

### 키 교체 (계획된 작업으로만)

키를 바꾸면 **기존 구독이 전부 무효**가 되어 가족 전원이 알림을 다시 켜야 한다. 순서:

1. 가족에게 사전 공지
2. 기존 키 백업(운영 호스트 밖, 암호화 보관)
3. 옛 키 파일 이동 → `gen-vapid-key.sh` 재실행
4. 웹앱 `config.json`의 Application Server Key 갱신·배포
5. 각 기기에서 알림 끄고 다시 켜기(구독 재생성) — 이 단계를 빠뜨리면 그 기기는 조용히 알림이 끊긴다

## 4. 설정

```bash
sudo cp deploy/sygnal/sygnal.yaml.example /etc/sygnal/sygnal.yaml
sudo chown root:sygnal /etc/sygnal/sygnal.yaml && sudo chmod 0640 /etc/sygnal/sygnal.yaml
```

치환할 것: `com.example.familychat.web`(app_id) · `<admin-email>` · `allowed_endpoints`.

⚠ **`vapid_contact_email`은 치환을 잊어도 기동이 성공한다.** sygnal은 "비어 있지 않은 문자열"만
확인하므로 `vapid_private_key`와 달리 fail-closed가 아니다. 플레이스홀더가 그대로 남으면
VAPID JWT의 `sub`가 `mailto:<admin-email>`로 나가 푸시 서비스가 거부할 수 있다.
§7.1 체크리스트에서 반드시 확인한다.

**app_id는 리터럴로 둔다.** 글로브를 쓰면 `find_pushkins`가 2개 이상 매칭될 때
pushkey를 rejected로 반환하고 홈서버가 pusher를 삭제한다.

## 5. 유닛 설치

```bash
sudo cp deploy/sygnal/sygnal.service /etc/systemd/system/

# ⚠ SYGNAL_UID 는 비어 있는 채로 배포된다. 반드시 채운다 —
#    비우면 컨테이너가 root로 돌아 --user 의 의미가 사라진다.
sudo sed -i "s|^Environment=SYGNAL_UID=$|Environment=SYGNAL_UID=$(id -u sygnal):$(id -g sygnal)|" \
  /etc/systemd/system/sygnal.service
grep -E '^Environment=SYGNAL_(UID|IMAGE)=' /etc/systemd/system/sygnal.service   # 둘 다 값이 있어야 한다

sudo systemctl daemon-reload
sudo systemctl enable --now sygnal
systemctl status sygnal --no-pager
```

## 6. Ingress

`deploy/sygnal/cloudflare-ingress.example.json` 참조. `POST /_matrix/push/v1/notify` 하나만 노출한다.
기존 family-messenger 터널에 합쳐도 되며, 그 경우 matrix/chat 규칙보다 뒤·404 앞에 둔다.
`/health`는 노출하지 않는다.

## 7. 검증 체크리스트

배포가 끝났다고 말하려면 아래를 **전부** 통과해야 한다.

### 7.1 게이트웨이 단독

- [ ] `systemctl is-active sygnal` = active
- [ ] 로컬 헬스: `curl -fsS http://127.0.0.1:5000/health`
- [ ] 기동 로그에 `PushkinSetupException` 없음 (VAPID 키 경로·이메일 미설정이면 여기서 죽는다)
- [ ] 로그에 webpush 앱이 로드된 기록이 있음
- [ ] 외부에서 `/health`가 **404** (노출하지 않았으므로)
- [ ] 외부에서 `POST /_matrix/push/v1/notify`가 sygnal에 도달 (400/빈 요청 응답이라도 도달 자체를 확인)

### 7.2 왕복 (웹앱 #167 필요)

- [ ] 데스크톱 Chrome/Firefox: 앱을 닫은 채 알림 수신 1건
- [ ] **iOS 홈화면 PWA 실기기에서 앱을 완전히 닫은 채 알림 수신** ← 진짜 게이트.
      headless·데스크톱 통과는 로드맵 #92 규칙대로 인정하지 않는다
- [ ] 알림 지연 측정치 기록 (Urgency가 `normal` 고정인 영향)
- [ ] 한국어 **439자 이상** 메시지에서 본문 없는 대체 알림으로 폴백하는 것 (암호문이 버려지는 경계)

### 7.3 실패 경로가 실제로 보이는가

- [ ] sygnal 4xx/5xx가 로그에 남고 Telegram으로 도달
- [ ] **`allowed_endpoints`에서 의도적으로 Apple을 빼고 조용한 유실을 한 번 재현** —
      아래 8절의 진단 절차가 실제로 작동하는지 확인한다

## 8. 알림이 안 올 때 — 조용한 유실 진단

홈서버는 정상으로 보이는데 알림만 사라지는 경로가 넷이다. **위에서부터** 배제한다.

| # | 증상 | 확인 | 원인 |
|---|---|---|---|
| 1 | sygnal 로그에 `not in allowed_endpoints, blocking request` | `allowed_endpoints`에 해당 브라우저의 푸시 호스트가 있는가 | 차단. `return []`만 하고 pushkey를 reject하지 않아 홈서버는 정상으로 안다 |
| 2 | 로그에 4xx(특히 413) 경고 | 메시지가 긴가 | 페이로드 4KB 초과. 필드별 자르기만 있고 전체 크기 검사가 없다 |
| 3 | 기기가 오래 잠든 뒤에만 누락 | `ttl` | 기본 900초 초과 미배달 폐기. 상향 검토 |
| 4 | 전반적으로 지연 | — | Urgency가 `normal` 고정. 설정 키가 없어 코드 수정 없이는 못 바꾼다 |

그 밖에:

- **pusher가 사라졌다** → 404/410은 정상 동작(구독 만료 시 pushkey reject → 홈서버가 pusher 정리).
  웹앱에서 알림을 다시 켜면 된다
- **한 기기에서 계정을 바꾼 뒤 앞사람 알림이 끊겼다** → 웹앱이 `append: true` 없이 pusher를 등록했다(#167).
  서비스워커/origin당 구독이 하나라 계정이 달라도 pushkey(p256dh)가 같다
- **"site has been updated in the background"가 뜬다** → pusher `data`에 `events_only: true`가 없다.
  event_id 없는 정리용 푸시를 서비스워커가 표시하지 않아 브라우저가 대신 띄운 것이다.
  **iOS에서는 알림을 안 띄우면 Safari가 푸시 권한을 박탈**하므로 그냥 두면 안 된다
- **홈서버 쪽 확인** → Tuwunel은 게이트웨이 응답의 `rejected` 목록을 보고 pusher를 삭제한다.
  pusher가 계속 사라지면 sygnal이 pushkey를 reject하고 있는지 로그를 본다

## 9. 업그레이드

1. 새 버전의 index digest와 linux/amd64 digest를 확인
2. `sygnal.pins.json`과 `sygnal.service`의 `SYGNAL_IMAGE`를 **함께** 갱신 → PR
3. 머지 후 배포: `sudo podman image pull <new digest>` → `sudo systemctl restart sygnal`
   (pull은 §2와 같은 이유로 **반드시 root**)
4. 7.1 재실행. 왕복(7.2)은 기기 1대로 축약 가능
5. 롤백은 이전 digest로 `SYGNAL_IMAGE`를 되돌리고 재시작

**upstream 변경 관찰 포인트**: webpush 푸시킨은 실질 기능 변경이 2021-12 이후 없다.
버전이 올라도 webpush 동작이 바뀔 가능성은 낮지만, `MAX_CIPHERTEXT_LENGTH`·`DEFAULT_TTL`·
Urgency 결정 로직이 바뀌면 위 4절·8절의 수치가 함께 바뀐다. 업그레이드 시 확인한다.
