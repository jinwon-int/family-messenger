// 말풍선 꾹 누르기 메뉴(답장·복사·선택해서 복사·공유)와 키보드 선택 모드가 다루는 글 — iOS `MessageCopy.text(of:)` 와 같은 규칙.
// android.* 없이 JVM 에서 돈다(MessageCopyTest).
package com.seoyoon_family.hande.core

object MessageCopy {
    /**
     * 복사·공유할 글. 사람·에이전트·서비스 봇의 글만 — 첨부(설명자·파일 키)·복호화 실패 행·빈 글은 null(메뉴 없음, #499 원칙).
     * 답장 글은 인용 머리를 빼고 내 글만(보이는 본문 기준 — `ReplyQuote.visibleText`).
     */
    fun text(m: MessageUi): String? {
        if (m.attachment || m.undecryptable) return null
        return ReplyQuote.visibleText(m.text).takeIf { it.isNotBlank() }
    }
}
