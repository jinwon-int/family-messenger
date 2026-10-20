// 화면 문구 — iOS `FamilyChat/App/Strings.swift` 와 같은 말을 쓴다(가족이 두 플랫폼에서 같은 안내를 본다).
package com.seoyoon_family.hande.ui

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

    const val loginTitle = "세션이 필요합니다"
    const val loginBody = "릴레이가 로그인을 요구합니다(401). 운영자용 세션 값을 입력하세요. Google 로그인은 다음 단계(C)에서 붙습니다."
    const val loginButton = "연결"

    const val roomsTitle = "대화"
    const val noRooms = "아직 대화방이 없습니다. 아래 「참여 요청」을 누르고, 운영자가 초대하면 여기 나타납니다."
    const val requestJoin = "참여 요청"
    const val lobbyKeys = "로비 키"
    const val notJoined = "초대를 기다려 주세요"
    const val halted = "정지됨"
    const val keyCustody = "키 보관"

    const val composerPlaceholder = "메시지"
    const val sendButton = "보내기"
    const val back = "뒤로"
}
