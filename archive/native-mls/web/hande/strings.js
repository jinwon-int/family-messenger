// 한데(hande) 웹 — 사용자 문구 단일 출처(패밀리챗 web/app strings.js 규칙 승계, iOS Strings*.swift 문구 재사용).
// 순수 모듈: DOM 없음. 검증 정규식·시간·지문·이름 도우미도 여기 둔다(tests/strings.test.mjs).

/** 사용자 이름(actor): 소문자로 시작, 영문 소문자·숫자 2~16자. */
export const ACTOR = /^[a-z][a-z0-9]{1,15}$/;
/** 대화방 ID: 영문 소문자·숫자로 시작, 소문자·숫자·하이픈 최대 48자. */
export const ROOM = /^[a-z0-9][a-z0-9-]{0,47}$/;
/** 기기 ID(릴레이 validIdentifier): 영문·숫자·`-`·`_` 1~64자. */
export const DEVICE = /^[A-Za-z0-9_-]{1,64}$/;

/**
 * 에이전트 노드 이름 → 보여 줄 이름 = **Matrix 닉네임과 동일**(결정 2026-10-19 ③, #422 — 한글 + 계정 마커).
 * 정본은 Matrix profile displayname(2026-10-21 실측). 바뀌면 iOS Strings.agentNames 와 함께 고친다.
 */
export const agentNames = {
  bangtong: '방통✳️', daegyo: '대교✴️', dungae: '등애✳️', gongmyoung: '공명✴️', gongyung: '공융✴️', gwakga: '곽가✳️',
  jingun: '진군✳️', nosuk: '노숙✳️', seoseo: '서서✴️', sogyo: '소교✴️', soonwook: '순욱✴️', yukson: '육손✳️',
};
/** 에이전트(봇) actor — 기기 ID 첫 마디. 옛 `bot-<node>` 와 새 `<node>-<suffix>`(#422) 둘 다(iOS FC_AGENT_ACTORS 와 같은 목록). */
export const AGENT_ACTORS = new Set(['bot', ...Object.keys(agentNames)]);
/** 사람 actor → 보여 줄 이름 = Matrix 닉네임과 동일(iOS Strings.peopleNames). */
export const peopleNames = { owner: 'jinon86', jungin: '쩡이🍎' };
/**
 * 대화방 ID → 보여 줄 방 이름 = Matrix 방 이름과 동일. 노드 개인방(ID = 노드 이름)은 그 노드 닉네임.
 * `family-acc` 는 오너 ↔ 공명 에이전트 방(Matrix 의 공명 개인방).
 */
export const roomNames = { family: '가족', 'family-acc': '공명✴️', 'family-card': '💳 가족 카드 알림', 'fleet-alerts': '🔔 플릿 알림' };
/**
 * 알림 전용 서비스 봇 actor → 보여 줄 이름(사람도 에이전트도 아님 — 🤖 표시·에이전트 동작 없음, iOS Strings.serviceNames).
 * `card` = 카드 결제 알림 봇(기기 `card-bot`, 방 `family-card` — Matrix 「💳 가족 카드 알림」과 같은 알림).
 */
export const serviceNames = { card: '💳 카드 알림', fleet: '🔔 플릿 알림' };
// `fleet` = 플릿 알림 봇(기기 `fleet-bot`, 방 `fleet-alerts` — Matrix 「🔔 플릿 알림」과 같은 알림, 노드 알림을 relay host가 전달; ccc-node #2413 · #460).
/** 기기 종류(기기 ID 둘째 마디) → 표시. 웹은 PC 판이므로 "PC". */
export const deviceKinds = { iphone: '아이폰', ipad: '아이패드', pc: 'PC', web: 'PC', android: '안드로이드', mac: '맥' };

export function actorOf(device) {
  const text = String(device ?? '');
  const dash = text.indexOf('-');
  return dash < 0 ? text : text.slice(0, dash);
}

export function isAgentDevice(device) {
  return AGENT_ACTORS.has(actorOf(device));
}

/** 봇 기기 → 노드 이름. 옛 `bot-<node>` 는 둘째 마디, 새 `<node>-<suffix>` 는 actor. 노드를 모르면 ''. */
function agentNode(device) {
  const text = String(device ?? '');
  const actor = actorOf(text);
  if (actor !== 'bot') return actor;
  const rest = text.slice(actor.length + 1);
  return rest ? rest.split('-')[0] : '';
}

/** 참여자 열쇠: 사람은 actor(여러 기기도 한 명), 봇은 노드(옛·새 기기 ID 도 한 명). */
export function participantOf(device) {
  return isAgentDevice(device) ? `agent:${agentNode(device)}` : actorOf(device);
}

/** 1:1 대화방인가 — 참여자(사람·봇 노드)가 둘 이하. roster 를 아직 모르면(빈 목록) false. */
export function isOneToOne(roster) {
  const devices = Array.isArray(roster) ? roster.filter(Boolean) : [];
  if (devices.length === 0) return false;
  return new Set(devices.map(participantOf)).size <= 2;
}

/** 내 글인가 — 같은 사람(actor)이면 다른 기기에서 보낸 글도 내 글(iOS MessageRecord.isMine). actor 를 아직 모르면 기기 일치로. */
export function isMine(sender, {device, actor}) {
  if (!sender) return false;
  if (actor) return actorOf(sender) === actor;
  return Boolean(device) && sender === device;
}

/** 기기 종류(둘째 마디, 소문자). 없으면 null. */
export function deviceKind(device) {
  const parts = String(device ?? '').split('-');
  if (parts.length < 2) return null;
  const kind = parts[1].toLowerCase();
  return kind ? kind : null;
}

/** 대화방 ID → 보여 줄 방 이름(Matrix 방 이름과 동일). 모르는 방은 ID 그대로. */
export function roomLabel(room) {
  const id = String(room ?? '');
  return roomNames[id] ?? agentNames[id] ?? id;
}

/**
 * 보여 줄 이름: 사람은 「jinon86 · PC」(닉네임 + 기기 종류), 봇은 「등애✳️」(노드 닉네임, 🤖 접두 없음 — 2026-10-26 오너). 모르는 actor 는 그대로.
 * 옛 봇 기기 `bot-<node>` 는 둘째 마디, 새 봇 기기 `<node>-<suffix>` 는 actor 가 노드 이름.
 * iOS AgentRoster.displayName + Strings.senderLabel 과 같은 결.
 */
export function displayName(device) {
  const text = String(device ?? '');
  if (!text) return '';
  const actor = actorOf(text);
  if (isAgentDevice(text)) {
    const node = agentNode(text);
    return node ? agentNames[node] ?? node : '봇';
  }
  const name = peopleNames[actor] ?? serviceNames[actor] ?? actor;
  const kind = deviceKind(text);
  const kindLabel = kind ? deviceKinds[kind] : null;
  return kindLabel ? `${name} · ${kindLabel}` : name;
}

const pad2 = (n) => String(n).padStart(2, '0');

/** 말풍선 시각 HH:MM(현지 시간). 모르면 빈 문자열. */
export function formatTime(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const d = new Date(ms);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/**
 * 목록 행의 거친 상대 시각: 방금 / N분 전 / N시간 전 / 어제 / M.D. — 패밀리챗 rooms.js relativeTime 이식(#480 A).
 * 한 시간 아래는 분 단위라 8초 틱이 실제 분 경계에서만 라벨을 바꾼다.
 * @param {number|null|undefined} ts epoch ms
 * @param {number} now epoch ms
 */
export function relativeTime(ts, now, labels = strings.rooms) {
  if (!Number.isFinite(ts) || ts <= 0) return '';
  const diff = Math.max(0, now - ts);
  const minute = 60_000;
  if (diff < minute) return labels.justNow;
  if (diff < 60 * minute) return labels.minutesAgo(Math.floor(diff / minute));
  if (diff < 24 * 60 * minute) return labels.hoursAgo(Math.floor(diff / (60 * minute)));
  const d = new Date(ts);
  const n = new Date(now);
  const startOfToday = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
  if (ts >= startOfToday - 24 * 60 * minute) return labels.yesterday;
  return `${d.getMonth() + 1}.${d.getDate()}.`;
}

/** 동기화 상태줄 HH:MM:SS. */
export function formatClock(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const d = new Date(ms);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

const WEEKDAYS = ['일', '월', '화', '수', '목', '금', '토'];

/** 날짜 구분선: "2026년 10월 19일 (월)". */
export function dayLabel(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const d = new Date(ms);
  return `${d.getFullYear()}년 ${d.getMonth() + 1}월 ${d.getDate()}일 (${WEEKDAYS[d.getDay()]})`;
}

/** 같은 현지 날짜인가 — 구분선을 넣을지 판단. */
export function dayKey(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** 지문 hex 를 4자리씩 띄운다: "abcd efgh …". */
export function groupFingerprint(hex) {
  const clean = String(hex ?? '').replace(/\s+/g, '');
  return clean.match(/.{1,4}/g)?.join(' ') ?? '';
}

/** 사람이 읽는 크기: 1,234 B · 12.3 KB · 1.2 MB. */
export function humanSize(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** 목록 미리보기 한 줄: 줄바꿈·마크다운 기호(**, `, 줄 앞 #·>·|)는 걷어 낸다(iOS previewLine). */
export function previewLine(name, body) {
  const lines = String(body ?? '')
    .split('\n')
    .map((line) => line.trim().replace(/^[#>|\s]+/, '').trim())
    .filter(Boolean);
  const flat = lines.join(' ').replaceAll('**', '').replaceAll('`', '');
  return name ? `${name}: ${flat}` : flat;
}

/** ⛔ 정지 사유 토큰 → 쉬운 설명·다음 행동(iOS Strings+Halt haltGuidance). */
export function haltGuidance(reason, { removed = false } = {}) {
  const token = removed ? 'removed_from_room' : String(reason ?? '');
  switch (token) {
    case 'history_gap':
      return {
        what: '릴레이가 이 기기가 아직 읽지 않은 메시지를 지웠습니다. 앱이 오래 열리지 않았거나 기기가 오래 꺼져 있었을 때 생깁니다. 그 사이 메시지는 복구할 수 없습니다.',
        next: '운영자나 다른 가족 기기에서 이 기기를 다시 초대하면, 그때부터 새 메시지를 받습니다.',
      };
    case 'removed_from_room':
      return {
        what: '다른 기기가 이 기기를 대화방에서 내보냈습니다.',
        next: '의도한 일인지 운영자에게 확인하세요. 다시 들어가려면 「이 기기 지우기」 → 새 기기로 시작 → 운영자 등록 → 신뢰 기기의 재초대가 필요합니다.',
      };
    case 'room_closed':
      return {
        what: '운영자가 이 대화방을 닫았습니다.',
        next: '이 대화방은 더 쓸 수 없습니다. 새 대화방은 운영자가 만들고 초대합니다.',
      };
    case 'report_format':
    case 'roster_unavailable':
      return {
        what: '암호화 모듈이 예상과 다른 응답을 했습니다(앱 결함일 수 있습니다).',
        next: '페이지를 새로고침하고 운영자에게 알려 주세요. 그래도 같다면 재초대를 받습니다.',
      };
    default:
      return {
        what: '다른 기기가 올린 대화방 변경(초대·제거)이 규칙에 어긋나, 이 기기가 받아들이지 않고 안전을 위해 멈췄습니다.',
        next: '운영자에게 알려 원인을 확인받으세요. 운영자가 정리한 뒤 이 기기를 다시 초대하면 돌아갑니다. 이 기기가 그 변경을 받아들이는 방법은 없습니다.',
      };
  }
}

export const strings = {
  appName: '한데',
  wordmark: 'hande',
  subtitle: '오늘 밤, 모닥불에 한데 모여',
  close: '닫기',
  copy: '복사',
  confirm: '확인',
  cancel: '취소',
  retry: '다시 시도',

  actor: {
    title: '이 기기 사용자',
    field: '이름(영문 소문자)',
    hint: '가족 운영자가 정해 준 영문 이름을 입력하세요(예: mom, dad, jiyu). 소문자로 시작하는 영문 소문자·숫자 2~16자. 이 기기의 ID가 이 이름으로 만들어지며, 한 번 정하면 바꿀 수 없습니다(바꾸려면 이 기기를 지우고 새 기기로 다시 등록).',
    button: '확인',
    invalid: '이름 형식이 맞지 않습니다 — 소문자로 시작하는 영문 소문자·숫자 2~16자(하이픈·공백 불가).',
    busy: '만드는 중…',
  },

  fatal: {
    title: '앱을 시작할 수 없습니다',
    retry: '다시 시도',
    wipe: '이 기기 지우기',
  },

  enroll: {
    title: '이 기기 등록',
    body: "아래 지문과 등록 정보를 가족 운영자에게 전달하면 운영자가 기기를 체인에 올립니다. 다른 기기가 이미 있으면 그 기기에서 '신뢰 기기' 화면으로 지문을 비교해 승인합니다.",
    fingerprintLabel: '이 기기의 지문',
    deviceIdLabel: '기기 ID',
    actorLabel: '이름',
    subjectLabel: '로그인 주체(sub)',
    subjectUnknown: '아직 모름 — 운영자가 CF Access sub로 채웁니다',
    registrationLabel: '등록 정보(운영자에게 전달)',
    copyRegistration: '등록 정보 복사',
    waiting: '운영자 등록 대기 중 (403 device_subject_mismatch)',
    notWaiting: '릴레이 확인 중…',
    lastChecked: (t) => `마지막 확인 ${t}`,
    checkNow: '지금 확인',
    openApprove: '다른 기기 승인(신뢰 기기)',
    wipe: '이 기기 지우기',
  },

  box: {
    title: '파일보관함',
    toggle: '파일보관함',
    close: '닫기',
    refresh: '새로고침',
    newWindow: '새 창에서 열기',
    loginHint: '처음이면 새 창에서 로그인한 뒤 새로고침하세요.',
  },
  rooms: {
    title: '대화',
    empty: '아직 피운 모닥불이 없습니다',
    noRooms: '아직 대화방이 없습니다. 위의 + 로 참여를 요청하고, 운영자가 초대하면 여기 나타납니다.',
    closedPreview: '불이 꺼진 자리',
    noMessages: '아직 아무도 말하지 않았어요',
    selectHint: '왼쪽 목록에서 모닥불을 고르세요.',
    // 안 읽은 방 이름 옆 둥근 배지(패밀리챗과 같은 카카오톡식 N). 글자 N은 보조기기에서 숨기고 unreadLabel을 읽는다.
    unreadBadge: 'N',
    unreadLabel: '새 메시지',
    justNow: '방금',
    minutesAgo: (n) => `${n}분 전`,
    hoursAgo: (n) => `${n}시간 전`,
    yesterday: '어제',
    photoPreview: '[사진]',
    filePreview: '[파일]',
    orderEditIcon: '↕',
    orderEdit: '순서',
    orderEditLabel: '대화 순서 편집',
    orderDone: '완료',
    orderDoneLabel: '대화 순서 편집 완료',
    orderHint: '▲▼로 순서를 바꾸세요(PC는 끌어서 옮기기도 됩니다). 이 기기에만 저장됩니다.',
    moveUp: (name) => `${name} 위로 이동`,
    moveDown: (name) => `${name} 아래로 이동`,
    pending: '초대 대기',
    halted: '정지',
    closed: '닫힘',
    actions: '대화방',
    join: '참여 요청',
    create: '방 만들기',
    settings: '설정',
    listLabel: '대화 목록',
    deviceLabel: '이 기기',
  },

  sync: {
    synced: (t) => `동기화 ${t}`,
    offline: (t) => `연결 끊김 (${t})`,
    reconnecting: '연결 중…',
    never: '아직 동기화하지 않았습니다',
  },

  chat: {
    placeholder: '메시지',
    placeholderDisabled: '지금은 보낼 수 없습니다',
    send: '보내기',
    sending: '보내는 중…',
    back: '대화 목록으로',
    attach: '첨부',
    lastSent: {
      label: '내 마지막 말',
      region: '내 마지막 말 — 누르면 그 메시지로 이동',
      jump: '이 메시지로 이동',
      replies: (n) => (n > 0 ? `답장 ${n}` : '아직 답 없음'),
      collapse: '내 마지막 말 접기',
      expand: '내 마지막 말 펼치기',
      earlierRegion: '오늘 내 말 — 누르면 그 메시지로 이동',
      notLoaded: '화면에 불러온 대화 밖입니다',
      photo: '[사진]',
      file: '[파일]',
    },
    attachHint: '첨부는 5 MiB 까지입니다. 파일 이름은 보내지 않습니다(받는 쪽에는 종류와 크기만 보입니다).',
    empty: '아직 아무도 말하지 않았어요. 첫 인사를 보내 보세요.',
    newMessages: '새 메시지 ↓',
    timelineLabel: '대화 내용',
    undecryptable: '🔒 복호화하지 못한 메시지',
    notJoined: '아직 이 대화방에 참여하지 않았습니다. 초대를 기다려 주세요.',
    members: (n) => `멤버 ${n}`,
    membersButton: '멤버',
    invite: '초대',
    image: '사진',
    viewImage: '크게 보기',
    closeImage: '저장: 사진을 길게 누르거나 우클릭 · 닫기: 아무 곳이나 누르세요',
    // 파일 행(#544 C): 이름이 오면 「📎 이름 · 크기」, 없으면(file-v1 — 와이어에 이름이 없다) 「📎 파일 · 크기」.
    file: (size, name = null) => `📎 ${name || '파일'} · ${size}`,
    // 미리보기 실패(#544 B): 사진일 수 있는 첨부를 불러오지 못했을 때 파일 행 옆에 — 누르면 같은 load() 를 다시 부른다.
    previewFailed: '미리보기를 불러오지 못했습니다',
    previewRetry: '미리보기 다시 시도',
    previewRetrying: '불러오는 중…',
    download: '다운로드',
    downloading: '불러오는 중…',
    downloadFailed: '첨부를 가져오지 못했습니다. 다시 시도하세요.',
    replay: '다시 받음',
    resendTitle: '첨부 전송 결과를 확인하지 못했습니다',
    resendBody: (size) => `${size} 첨부의 전송이 끝났는지 알 수 없습니다. 다시 보내면 중복 없이 확인합니다.`,
    resend: '같은 첨부 다시 보내기',
    me: '나',
  },

  halt: {
    title: '⛔ 이 기기의 대화가 정지되었습니다',
    bannerBody: (reason, opts) => `${haltGuidance(reason, opts).what} 이 대화방의 보내기와 동기화는 멈춰 있습니다.`,
    reasonLabel: '사유 코드',
    detail: (seq, committer, at) => [seq != null ? `seq ${seq}` : null, committer || null, at || null].filter(Boolean).join(' · '),
  },

  join: {
    title: '대화방 참여 요청',
    field: '대화방 ID',
    hint: "운영자가 알려준 대화방 ID를 그대로 입력하세요(가족 대화방은 보통 family). 이 기기의 키 패키지(공개 정보)를 그 대화방에 게시합니다. 운영자가 다른 기기의 '초대'로 받아들이면 대화가 시작됩니다. 메시지나 비밀키는 보내지 않습니다.",
    button: '참여 요청',
    busy: '요청하는 중…',
    done: '참여를 요청했습니다. 운영자의 초대를 기다려 주세요.',
    failed: (reason) => `참여 요청에 실패했습니다: ${reason}`,
    invalid: '대화방 ID 형식이 맞지 않습니다 — 영문 소문자·숫자로 시작, 소문자·숫자·하이픈 최대 48자.',
  },

  create: {
    title: '대화방 만들기',
    field: '대화방 ID',
    hint: "이 기기에서 새 대화방을 만듭니다(영문 소문자·숫자·하이픈, 최대 48자). 릴레이에는 첫 초대 때 생깁니다 — 만든 뒤 방에 들어가 '초대'로 다른 기기를 들이세요.",
    button: '만들기',
    busy: '만드는 중…',
    done: "대화방을 만들었습니다. 방에 들어가 '초대'로 다른 기기를 들이세요.",
    invalid: '대화방 ID 형식이 맞지 않습니다 — 영문 소문자·숫자로 시작, 소문자·숫자·하이픈 최대 48자.',
  },

  invite: {
    title: '기기 초대',
    field: '초대할 기기 ID',
    hint: "상대 기기의 '설정 → 기기 ID'(예: mom-iphone-1a2b3c)를 입력하세요. 상대가 먼저 이 대화방에 '참여 요청'을 해 두었어야 합니다. 초대하면 이 방의 암호화 키가 바뀌고(새 epoch) 상대가 대화에 들어옵니다.",
    button: '초대',
    busy: '초대하는 중…',
    done: (device) => `${device} 기기를 초대했습니다. 상대 앱에서 목록을 새로고침하면 대화가 열립니다.`,
    self: '자기 자신은 초대할 수 없습니다.',
    invalid: '기기 ID 형식이 맞지 않습니다(영문·숫자·하이픈·밑줄, 최대 64자).',
    membersTitle: '멤버',
    membersEmpty: '아직 멤버가 없습니다.',
    remove: '제거',
    removeConfirm: (device) => `${device} 기기를 이 대화방에서 제거합니다. 정책 체인에서 이미 폐기된 기기만 제거할 수 있습니다. 계속할까요?`,
    thisDevice: '이 기기',
  },

  settings: {
    title: '설정',
    deviceIdLabel: '기기 ID',
    actorLabel: '이름',
    fingerprintLabel: '이 기기의 지문',
    subjectLabel: '로그인 주체(sub)',
    originLabel: '릴레이',
    copyRegistration: '등록 정보 복사',
    openApprove: '다른 기기 승인(신뢰 기기)',
    wipe: '이 기기 지우기',
    wipeHint: '이 기기의 암호화 상태(서명키)·대화 기록·기기 ID 를 모두 지우고 새 기기가 됩니다.',
  },

  wipe: {
    title: '이 기기 지우기',
    warning: '이 기기는 새 기기 ID 와 새 지문을 갖게 됩니다. 되돌릴 수 없습니다.\n• 지금 기기 ID 는 다시 쓸 수 없습니다. 운영자가 옛 ID 를 폐기하고 새 ID 를 다시 등록해야 합니다.\n• 모든 대화방에 다시 초대받아야 합니다.\n• 이 기기의 대화 기록과 암호화 이력은 복구할 수 없습니다(다른 기기의 기록은 그대로입니다).\n계속할까요?',
    confirm: '지우고 새 기기로 시작',
    done: '지웠습니다. 새 기기로 시작한 뒤 등록 정보를 운영자에게 다시 전달하세요.',
    failed: (reason) => `지우지 못했습니다: ${reason}. 탭을 모두 닫은 뒤 다시 시도하세요.`,
  },

  approve: {
    title: '신뢰 기기 승인',
    intro: '새 기기의 등록 정보(JSON)를 붙여 넣고 지문을 그 기기 화면과 직접 비교하세요. 같을 때만 승인합니다.',
    field: '새 기기의 등록 정보(JSON)',
    placeholder: '{ "device_id": "...", "signing_key": "..." }',
    show: '지문 보기',
    checking: '확인하는 중…',
    candidate: '승인할 기기',
    fingerprint: '그 기기의 지문',
    compare: '그 기기 화면의 지문과 한 자리씩 비교하세요.',
    accept: '이 지문이 맞습니다',
    reject: '거부',
    signing: '서명하는 중…',
    evidenceTitle: '승인 증거(운영자에게 전달)',
    evidenceHint: '아래 JSON 을 운영자에게 전달하면 운영자가 체인에 올립니다. 비밀키는 들어 있지 않습니다.',
    rejected: '승인하지 않았습니다. 그 기기의 등록 정보를 다시 확인하세요.',
  },

  menu: {
    title: '설정',
    open: '설정',
    join: '🔑 참여 요청',
    create: '🔥 방 만들기',
    settings: '설정',
    invite: '기기 초대 · 멤버',
    approve: '신뢰 기기 승인',
    sync: '지금 동기화',
    wipe: '이 기기 지우기',
  },
  // 로비 초대(#380 P5-3, iOS와 동일): 운영자/봇이 로비 키로 보낸 새 대화방 Welcome.
  lobby: {
    inviteSectionTitle: '새 대화방 초대',
    inviteBody: (room) => `운영자가 「${room}」 대화방에 이 기기를 초대했습니다. 수락하면 대화에 들어갑니다.`,
    accept: '수락',
    ignore: '무시',
    acceptFailed: (reason) => `초대를 받아들이지 못했습니다: ${reason}`,
    joined: (room) => `새 대화방 「${room}」에 들어왔습니다.`,
    keysLabel: '로비 키',
    keys: (live) => (live === null || live === undefined ? '확인 전' : `${live}개`),
    hint: '로비 키는 이 기기의 공개 키 패키지입니다. 운영자가 steward 봇에게 지시하면 이 키로 새 대화방에 초대됩니다(오너 기기는 자동 가입, 가족 기기는 수락 1탭). 앱을 열 때마다 모자란 만큼 채웁니다.',
  },
  // 🔔 알림(#521): 받은 초대와 그 처리 상태 — 오너 기기의 자동 참여가 실패해도 로그가 아니라 여기 남는다.
  notify: {
    title: '알림',
    button: (count) => (count > 0 ? `알림 ${count}건` : '알림'),
    empty: '새 알림이 없습니다. 받은 초대와 수락 상태가 여기 모입니다.',
    inviteNew: '새 대화방 초대',
    inviteBusy: '수락하는 중…',
    inviteFailed: (tries, reason) => `자동 수락 실패 ${tries}회${reason ? ` — ${reason}` : ''}`,
    hint: '수락은 이 기기의 로비 키로 보낸 Welcome 을 읽어 대화방에 들어가는 일입니다. 실패해도 키는 지워지지 않으니 「다시 시도」할 수 있습니다.',
    retry: '다시 시도',
    copyLogs: '진단 기록 복사',
  },

  errors: {
    generic: '문제가 생겼습니다. 잠시 후 다시 시도하세요.',
  },

  // 핵심 모듈(relay.js / room.js / app.js)이 쓰는 문구 — 코디네이터 지정.
  relay: {
    networkFailed: '연결 실패 — 페이지를 새로고침하고(필요하면 Cloudflare Access 로그인) 다시 시도해 주세요.',
    unauthorized: '로그인이 필요합니다(401). 페이지를 새로고침해 Cloudflare Access 로그인을 다시 해 주세요.',
  },
  room: {
    waitingOperator: '운영자 등록 대기 중 (403 device_subject_mismatch)',
    noRoomYet: '대화방이 아직 없습니다 — 첫 기기가 「방 만들기」를 하고 초대해야 합니다.',
    notJoined: '아직 이 대화방에 참여하지 않았습니다. 초대를 기다려 주세요.',
    welcomeSkipped: (seq) => `열 수 없는 Welcome(seq ${seq}) 은 건너뛴다 — 재초대 전의 것이면 뒤에 새 Welcome 이 온다`,
    pendingCommit: '내 변경이 아직 반영되지 않았습니다 — 동기화 뒤 다시 시도해 주세요.',
    alreadyInRoom: '이 기기는 이미 대화방(그룹)에 있습니다.',
    created: '대화방을 만들었습니다. 「초대」로 다른 기기를 들이세요.',
    keyPackagePublished: '참여를 요청했습니다. 운영자의 초대를 기다려 주세요.',
    noKeyPackage: (device) => `${device} 기기의 키 패키지가 없습니다 — 상대가 먼저 「참여 요청」을 했거나 로비 키를 올려 두었어야 합니다(앱을 한 번 열면 됩니다).`,
    inviteDone: (device) => `${device} 기기를 초대했습니다. 반영되면 Welcome을 보냅니다.`,
    removeDone: (device) => `${device} 기기 제거를 게시했습니다.`,
    notMember: (device, members) => `${device} 기기는 현재 멤버가 아닙니다 (멤버: ${members || '—'})`,
    removeSelf: '자기 자신은 제거할 수 없습니다 — 다른 신뢰 기기에서 제거하거나 「이 기기 지우기」를 쓰세요.',
    commitRaced: '대화방이 먼저 바뀌어 반영하지 못했습니다. 동기화 뒤 다시 시도해 주세요.',
    commitRefused: (reason) => `변경이 거절되었습니다: ${reason}`,
    sendFailed: (reason) => `보내지 못했습니다(${reason}). 동기화 뒤 다시 시도해 주세요.`,
    epochChanged: '암호화 키가 바뀌어 다시 암호화합니다.',
    haltRefused: (seq, committer, reason) => `⛔ seq ${seq} ${committer}의 변경을 거부했습니다 — ${reason}`,
    haltRemoved: (seq, committer) => `seq ${seq} ${committer}이(가) 이 기기를 대화방에서 제거했습니다`,
    haltBody: '이 기기는 그 변경을 적용하지 않았고 더 읽지 않습니다. 운영자에게 알리고 재초대/재등록을 기다려 주세요.',
    removedBody: '더 읽지 않습니다. 다시 들어오려면 「이 기기 지우기」 → 새 기기로 시작 → 운영자 등록 → 신뢰 기기의 재초대가 필요합니다.',
    historyRestored: (n, seq) => `[이 브라우저에 봉인 보관된 최근 ${n}건(seq ${seq}까지) — 릴레이는 평문을 보관하지 않습니다. 이 기기에서만 보이고 「이 기기 지우기」로 함께 지워집니다]`,
    historyNone: (seq) => `[seq ${seq}까지의 이전 대화는 이 브라우저에 보관 기록이 없어 다시 표시되지 않습니다. 새로 도착하는 메시지만 아래에 쌓입니다]`,
    historyGap: (from, to) => `릴레이가 seq ${from}~${to}를 이미 지웠습니다 — 재참여가 필요할 수 있습니다.`,
    resumed: (members, seq) => `참여 상태 복구 — 멤버 ${members}, 릴레이 커서 ${seq}부터 이어 읽습니다`,
    decryptFailed: (seq, device) => `해독 실패(seq ${seq}, ${device}) — 건너뛰지 않고 다음 동기화에서 다시 시도합니다`,
    fileV2Failed: (seq) => `첨부(seq ${seq})를 열 수 없음 — 다시 누르면 다시 받습니다:`,
    fileV2Invalid: (seq, device) => `첨부 정보가 올바르지 않아 열 수 없음(seq ${seq}, ${device})`,
    attachmentUnknown: '첨부 전송 결과를 확인하지 못했습니다. 「같은 첨부 다시 보내기」를 누르면 중복 없이 확인합니다.',
    attachmentSent: (seq, size) => `첨부를 보냈습니다(seq ${seq}, ${size.toLocaleString()}바이트)`,
    freshStore: (next) => `저장소가 비어 있어 새 기기(새 지문)로 시작합니다. 정책 체인은 같은 기기 ID를 다시 받지 않으므로 기기 ID를 ${next}로 바꿉니다. 운영자 등록과 재초대가 다시 필요합니다.`,
    wipeDone: (next) => `이 기기의 저장소를 지웠습니다. 다음 시작은 새 기기 ID(${next})입니다 — 운영자 등록과 재초대가 다시 필요합니다.`,
    candidateMissing: (key) => `등록 JSON에 ${key}가 없습니다`,
    candidateKeyInvalid: 'signing_key는 64자리 hex여야 합니다',
    approvalSigned: '승인 서명을 만들었습니다 — 아래 증거를 운영자에게 전달하세요(-add-device -input)',
  },
  app: {
    starting: '준비 중…',
    deriving: '저장소를 여는 중입니다 — 처음에는 몇 초 걸릴 수 있습니다.',
    fatalTitle: '앱을 시작할 수 없습니다',
    storageUnavailable: (detail) => `기기 저장소를 열 수 없습니다: ${detail}`,
    workerUnavailable: '이 브라우저에서 암호화 워커를 시작하지 못했습니다(Web Worker · WebAssembly · IndexedDB 필요). PC 크롬에서 열어 주세요.',
    subjectUnknown: '<운영자가 CF Access sub로 채움>',
    copied: '복사했습니다',
    copyFailed: '복사하지 못했습니다 — 직접 선택해 복사해 주세요',
  },
};

/** 표의 모든 잎이 비어 있지 않은가(테스트용). */
export function allStringsFilled(node = strings) {
  if (typeof node === 'string') return node.length > 0;
  if (typeof node === 'function') return true;
  return Object.values(node).every(allStringsFilled);
}
