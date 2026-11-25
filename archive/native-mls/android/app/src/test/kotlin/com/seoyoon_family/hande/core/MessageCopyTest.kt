// 말풍선 꾹 누르기 메뉴 대상 글 — iOS `MessageCopy.text(of:)` 와 같은 규칙.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MessageCopyTest {
    private fun row(text: String, attachment: Boolean = false, undecryptable: Boolean = false) =
        MessageUi(seq = 1, sender = "dev", text = text, mine = false, attachment = attachment, undecryptable = undecryptable)

    @Test
    fun plainTextIsCopiedAsIs() {
        assertEquals("내일 몇 시에 와?\n7시쯤", MessageCopy.text(row("내일 몇 시에 와?\n7시쯤")))
    }

    @Test
    fun replyDropsQuoteHead() {
        val body = ReplyQuote.compose(name = "엄마", seq = 12, original = "내일 몇 시에 와?", reply = "7시쯤!")
        assertEquals("7시쯤!", MessageCopy.text(row(body)))
    }

    @Test
    fun attachmentUndecryptableAndBlankHaveNoMenu() {
        assertNull(MessageCopy.text(row("📎 사진.jpg", attachment = true)), "첨부 자리 표시 글")
        assertNull(MessageCopy.text(row("열 수 없는 파일", undecryptable = true)), "복호화 실패 행")
        assertNull(MessageCopy.text(row("  \n\t")), "빈 글")
    }
}
