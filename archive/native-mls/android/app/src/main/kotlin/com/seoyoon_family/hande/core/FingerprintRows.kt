// 지문 hex → 화면 행(한데 디자인 2차-A §A1 ①): 4자 묶음을 둘씩 짝지어 「xxxx xxxx」 — 64 hex 면 8행. iOS `FingerprintRows.make` 와 같은 규칙.
// 이 기기 등록 화면(표시 없음)과 새 기기 승인 화면(행마다 표시)이 **같은 행·같은 번호**를 보여야 눈으로 한 줄씩 맞출 수 있다.
// android.*·Compose 없음 → JVM 단위 테스트(`FingerprintRowsTest`)로 고정한다.
package com.seoyoon_family.hande.core

object FingerprintRows {
    /** 한 묶음의 글자 수(`SelfService.groupedFingerprint` 와 같은 4). */
    const val GROUP = 4
    /** 한 행의 묶음 수 — 393pt 폭에 승인 버튼까지 들어가게 둘씩. */
    const val PER_ROW = 2

    /**
     * 공백·줄바꿈을 걷어낸 뒤 4자씩 묶고 둘씩 한 행으로. 짧은 입력은 있는 만큼만(채우지 않는다) — 빈 입력은 빈 목록.
     * `groupedFingerprint` 결과를 넣어도 같은 행이 나온다(공백을 먼저 걷어내므로).
     */
    fun make(hex: String): List<String> {
        val clean = hex.filterNot { it.isWhitespace() }
        if (clean.isEmpty()) return emptyList()
        return clean.chunked(GROUP).chunked(PER_ROW).map { it.joinToString(" ") }
    }

    /** 행을 다시 한 줄 hex 로(진단 기록·테스트). */
    fun join(rows: List<String>): String = rows.joinToString("") { it.replace(" ", "") }
}
