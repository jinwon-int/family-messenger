// All user-facing strings live here. The product language is Korean
// (roadmap stage 1: 한국어 우선). Keep views free of literal copy so the
// wording stays reviewable in one place.

export const strings = {
  appName: '패밀리챗',
  login: {
    title: '가족 계정으로 로그인',
    hint: '가족 관리자가 발급한 계정으로 시작합니다.',
    homeserverLabel: '홈서버 주소',
    homeserverPlaceholder: 'https://<homeserver>',
    userLabel: '사용자 이름',
    userPlaceholder: '예: minseo',
    passwordLabel: '비밀번호',
    passwordPlaceholder: '비밀번호',
    submit: '로그인',
    submitting: '접속 중…',
    error: '로그인에 실패했습니다. 주소와 계정을 다시 확인하세요.',
  },
  rooms: {
    title: '대화',
    loading: '대화 목록을 불러오는 중…',
    empty: '아직 참여한 대화가 없습니다. 가족에게 초대를 요청하세요.',
    syncError: '연결이 끊겼습니다. 자동으로 다시 접속을 시도합니다.',
    familyBadge: '가족방',
    privateBadge: '개인방',
    otherBadge: '다른 방',
    unnamed: '이름 없는 대화',
    memberCount: (n) => `멤버 ${n}명`,
  },
  chat: {
    messagePlaceholder: '메시지 입력',
    send: '보내기',
    attachPhoto: '사진 보내기',
    attachVideo: '영상 보내기',
    attachFile: '파일 보내기',
    encrypted: '이 대화는 종단간 암호화됩니다.',
    sending: '보내는 중…',
    sendFailed: '전송에 실패했습니다. 다시 시도하세요.',
    decryptFailed: '메시지를 열 수 없습니다. 이 기기가 아직 암호화 기록을 받지 못했을 수 있습니다.',
    unreadable: '표시할 수 없는 메시지입니다.',
    historyLoading: '이전 대화를 불러오는 중…',
  },
  participants: {
    aiBadge: 'AI',
    aiTitle: 'AI 에이전트입니다. 명시적으로 부를 때만 응답합니다.',
    humanTitle: '가족 참여자',
    youLabel: '나',
  },
  verification: {
    title: '기기 검증',
    intro: '가족 기기를 검증하면 메시지를 안전하게 주고받을 수 있습니다.',
    start: '이 기기 검증 시작',
    compareHeading: '두 화면에 같은 이모지가 보이는지 비교하세요.',
    waiting: '상대 기기의 확인을 기다리는 중…',
    same: '네, 같습니다',
    different: '다릅니다',
    done: '기기가 검증되었습니다.',
    mismatchTitle: '이모지가 일치하지 않습니다',
    mismatchBody: '검증을 중단했습니다. 이 기기의 연결이 바뀌었을 수 있습니다. 가족과 직접 확인한 뒤 다시 시도하세요.',
    cancelled: '검증이 취소되었습니다.',
    close: '닫기',
  },
  recovery: {
    title: '복구 키',
    intro: '기기를 잃어버려도 복구 키가 있으면 대화 기록을 되찾을 수 있습니다.',
    generate: '복구 키 만들기',
    generating: '만드는 중…',
    showOnceHeading: '지금 한 번만 표시됩니다',
    showOnceBody: '이 키를 종이에 적어 가족과 정한 안전한 곳에 보관하세요. 스크린샷이나 메모 앱에 두지 마세요.',
    keyLabel: '복구 키',
    copied: '복사되었습니다.',
    confirmLabel: '복구 키를 다시 입력해 확인하세요',
    confirmPlaceholder: '복구 키 입력',
    confirm: '확인',
    mismatch: '일치하지 않습니다. 키를 다시 확인하세요.',
    done: '복구 키 확인이 끝났습니다. 이 화면에서는 다시 표시되지 않습니다.',
    privacy: '복구 키는 이 기기 밖으로 전송되지 않습니다. 서버가 수집하지 않습니다.',
  },
  media: {
    photo: '사진',
    video: '영상',
    file: '파일',
    tooLarge: '파일이 너무 큽니다. 최대 90 MB까지 보낼 수 있습니다.',
    unsupported: '이 형식은 아직 지원하지 않습니다.',
  },
  install: {
    hint: '설치하면 앱처럼 켤 수 있습니다.',
    dismiss: '다음에',
  },
  errors: {
    plaintextRefused: '암호화되지 않은 전송은 거부되었습니다. 이 방은 암호화가 켜져 있어야 합니다.',
    generic: '문제가 생겼습니다. 잠시 후 다시 시도하세요.',
  },
};

/** True when every leaf string in the table is a non-empty value. */
export function allStringsFilled(node = strings) {
  if (typeof node === 'string') return node.length > 0;
  if (typeof node === 'function') return true;
  return Object.values(node).every(allStringsFilled);
}
