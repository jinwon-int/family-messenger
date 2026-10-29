// 화면 문구 — iOS `FamilyChat/App/Strings.swift` 와 같은 말을 쓴다(가족이 두 플랫폼에서 같은 안내를 본다).
package com.seoyoon_family.hande.ui

import com.seoyoon_family.hande.core.AppLogin

object Strings {
    const val appName = "한데"
    const val starting = "준비 중…"
    const val connecting = "연결 중입니다…"

    const val setupTitle = "처음 설정"
    const val relayField = "릴레이 주소"
    const val relayHint = "가족 운영자가 알려 준 주소(https://…)."
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
