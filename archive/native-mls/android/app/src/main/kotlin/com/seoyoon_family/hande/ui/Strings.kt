// 화면 문구 — iOS `FamilyChat/App/Strings.swift` 와 같은 말을 쓴다(가족이 두 플랫폼에서 같은 안내를 본다).
package com.seoyoon_family.hande.ui

import com.seoyoon_family.hande.core.AppLogin

object Strings {
    const val appName = "한데"
    const val starting = "준비 중…"
    const val connecting = "연결 중입니다…"

    const val setupTitle = "처음 설정"
    // 서버 선택(#584 PR 3): 도메인만 적으면 `.well-known/hande` 로 릴레이를 찾는다. 릴레이 주소(https://…)를 그대로 적는 옛 길도 된다.
    const val serverField = "서버 주소(도메인 또는 URL)"
    const val serverHint = "가족 운영자가 알려 준 도메인(예: family.example)만 적어도 됩니다. 릴레이 주소(https://…)를 그대로 적어도 됩니다."
    const val findServer = "서버 찾기"
    const val findingServer = "서버 찾는 중…"
    const val serverUnnamed = "이름 없는 서버"
    const val serverViaWellKnown = "서버 정보(.well-known/hande)로 찾았습니다."
    const val serverDirect = "서버 정보가 없어 입력한 주소를 릴레이로 바로 씁니다."
    const val serverGated = "릴레이가 로그인 뒤에 있습니다(엣지 인증) — 저장 뒤 가족 로그인으로 이어집니다."
    const val serverBadInput = "주소를 읽을 수 없습니다 — 도메인(family.example) 또는 https:// 주소를 적어 주세요(http 는 localhost 만)."
    fun serverTooOld(required: String, current: String) = "이 서버는 앱 $required 이상이 필요합니다(지금 $current). 앱을 업데이트해 주세요."
    fun serverUnreachable(base: String, detail: String) = "$base 에서 릴레이 응답이 없습니다($detail). 주소를 확인해 주세요."
    const val actorTitle = "이 기기 사용자"
    const val actorField = "이름(영문 소문자)"
    const val actorHint = "가족 운영자가 정해 준 영문 이름을 입력하세요(예: mom, dad, jiyu). 소문자로 시작하는 영문 소문자·숫자 2~16자. 이 기기의 ID가 이 이름으로 만들어지며, 한 번 정하면 바꿀 수 없습니다."
    const val actorInvalid = "이름 형식이 맞지 않습니다 — 소문자로 시작하는 영문 소문자·숫자 2~16자(하이픈·공백 불가)."
    const val tokenField = "세션 값(운영자용, 선택)"
    const val tokenHint = "PC 브라우저의 세션 값(CF_Authorization)을 붙여넣는 운영자용 방법입니다."
    const val save = "확인"

    const val enrollTitle = "이 기기 등록"
    const val enrollBody = "아래 지문과 등록 정보를 가족 운영자에게 전달하면 운영자가 기기를 체인에 올립니다."
    const val fingerprintLabel = "이 기기의 지문"
    const val copyRegistration = "등록 정보 복사"
    const val copied = "복사했습니다"
    const val enrolledButton = "등록 확인"
    const val waitingOperator = "운영자 등록 대기 중 (403 device_subject_mismatch)"

    // 기기 셀프서비스(#574, 웹 `strings.js` enroll/candidates/devices 와 같은 말)
    const val enrollSiblingTitle = "다른 기기에서 승인해 주세요"
    const val enrollSiblingBody = "이미 쓰고 있는 내 기기(PC 웹·iPhone·다른 Android)의 「새 기기 승인」에서 이 지문을 견주어 보고 승인하면 이 기기가 등록됩니다."
    fun enrollSiblingExpires(at: String) = "승인 요청은 $at 까지 유효합니다(그 전에 자동으로 다시 올립니다)."
    const val enrollIdTaken = "이 기기 ID 는 예전에 쓰였거나 폐기되어 다시 쓸 수 없습니다. 「이 기기 지우기」로 새 ID 를 만들어 다시 시작하세요(운영자 등록 정보는 아래)."
    const val enrollOperatorOnly = "첫 기기(또는 셀프서비스가 없는 릴레이)는 운영자가 등록합니다."
    const val showOperatorInfo = "운영자 등록 정보 보기"
    const val hideOperatorInfo = "운영자 등록 정보 닫기"
    const val enrolledNow = "이 기기가 등록되었습니다."
    fun siblingWelcome(from: String, room: String) = "내 기기 $from 가 $room 대화방에 초대했습니다 — 자동으로 참여합니다."

    const val candidatesTitle = "새 기기 승인"
    const val candidatesHint = "새 기기 화면의 지문과 아래 지문이 같은지 눈으로 견준 뒤 승인하세요. 다르면 승인하지 마세요."
    const val approveButton = "지문 비교 후 승인"
    const val ignoreButton = "무시"
    const val approving = "승인 중…"
    fun candidateExpires(at: String) = "$at 까지"
    fun candidateNew(id: String) = "새 기기 승인 요청: $id"
    fun candidateApproved(id: String) = "$id 를 등록했습니다. 내가 있는 대화방에 초대합니다."
    const val candidateMismatch = "지문이 서명 키와 맞지 않아 승인하지 않았습니다."
    const val candidateNoRevision = "릴레이가 정책 revision 을 알려 주지 않아 서명할 수 없습니다."
    fun candidateRejected(detail: String) = "릴레이가 승인을 거절했습니다: $detail"
    fun candidateFailed(reason: String) = "승인하지 못했습니다: $reason"
    fun siblingInvited(target: String, room: String) = "$target 를 $room 에 초대했습니다."
    fun siblingFailed(target: String, room: String, reason: String) = "$target 를 $room 에 초대하지 못했습니다: $reason"
    fun siblingGaveUp(target: String) = "$target 초대를 30분 동안 하지 못해 그만둡니다. 「참여 요청」 뒤 운영자에게 초대를 부탁하세요."

    const val devicesTitle = "내 기기"
    const val devicesButton = "내 기기"
    const val devicesEmpty = "릴레이가 기기 목록을 주지 않습니다(옛 릴레이이거나 로그인이 필요합니다)."
    const val devicesHint = "등록 기기(registrar)만 새 기기를 승인할 수 있습니다. 마지막 등록 기기는 해제할 수 없습니다 — 먼저 다른 기기에 부여하세요."
    const val thisDevice = "이 기기"
    const val registrarPill = "등록 기기"
    const val statusActive = "활성"
    const val statusRevoked = "폐기"
    const val grantButton = "등록 기기로"
    const val releaseButton = "등록 기기 해제"
    const val lastRegistrarNote = "마지막 등록 기기"
    fun devicesUnknown(id: String) = "$id 는 내 기기 목록에 없습니다."
    fun rolesDone(id: String, grant: Boolean) = if (grant) "$id 를 등록 기기로 지정했습니다." else "$id 의 등록 기기 역할을 해제했습니다."
    fun rolesRejected(detail: String) = "릴레이가 역할 변경을 거절했습니다: $detail"
    fun rolesFailed(reason: String) = "역할을 바꾸지 못했습니다: $reason"

    // 로그인(§12-C A, iOS LoginView · AppLogin.swift 와 같은 말)
    const val loginTitle = "가족 로그인"
    const val loginGoogle = "Google 계정으로 로그인"
    const val loginHint = "가족 운영자가 허용한 Google 계정으로 로그인합니다. 로그인 창은 이 기기의 브라우저가 열고, 비밀번호는 앱에 전달되지 않습니다. 로그인이 끝나면 이 앱으로 자동으로 돌아옵니다."
    const val loginManualTitle = "직접 입력(운영자용)"
    const val loginManualHint = "PC 브라우저의 세션 값(CF_Authorization)을 붙여넣는 운영자용 방법입니다. 가족은 위의 로그인 버튼을 쓰세요."
    const val loginField = "세션 값"
    const val loginButton = "연결"
    fun loginFailed(reason: String) = "로그인하지 못했습니다: $reason"
    fun loginFailure(e: AppLogin.Failure): String = when (e) {
        AppLogin.Failure.BadRelayUrl -> loginFailed("릴레이 주소가 설정되지 않았거나 올바르지 않습니다.")
        AppLogin.Failure.CannotStart -> loginFailed("로그인 창을 열 수 없습니다(브라우저 없음).")
        AppLogin.Failure.NotCallback -> loginFailed("릴레이의 응답 주소가 예상과 다릅니다.")
        AppLogin.Failure.StateMismatch -> loginFailed("이 요청의 응답이 아닙니다(state 불일치). 다시 시도해 주세요.")
        AppLogin.Failure.MissingToken -> loginFailed("릴레이가 세션을 돌려주지 않았습니다(릴레이가 아직 앱 로그인을 지원하지 않을 수 있습니다).")
        AppLogin.Failure.MalformedToken -> loginFailed("세션 형식이 올바르지 않습니다.")
    }

    const val roomsTitle = "대화"
    const val noRooms = "아직 대화방이 없습니다. 아래 「참여 요청」을 누르고, 운영자가 초대하면 여기 나타납니다."
    const val requestJoin = "참여 요청"
    const val lobbyKeys = "로비 키"
    const val notJoined = "초대를 기다려 주세요"
    const val halted = "정지됨"
    const val keyCustody = "키 보관"
    /** 대화방 목록의 안 읽음 표시(#571 후속, 웹 N 배지와 같은 뜻 — 개수 대신 「새 글」). */
    const val unread = "새 글"

    // 첨부 자리 표시(v1·v2 같은 모양 — 파일 열기는 C 단계). 설명자가 잘못된 file-v2 는 웹 `fileV2Invalid` 와 같은 뜻.
    fun attachmentPlaceholder(bytes: Long) = "📎 첨부($bytes B)"
    const val fileV2Invalid = "⚠ 첨부 정보가 올바르지 않아 열 수 없음"

    const val composerPlaceholder = "메시지"
    const val sendButton = "보내기"
    const val back = "뒤로"
}
