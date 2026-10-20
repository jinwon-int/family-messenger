// 방별 메시지 기록(B1 임시): JSON Lines 한 줄 = 메시지 하나(seq · sender · text · ts · mine). 평문이므로 Keystore 로 봉인해 쓴다.
// 정식 저장소(#338 §2 "Rust 우선 검토: rusqlite vs Room")는 B2 에서 결정 — 이 파일 형식은 그때 이관한다.
package com.seoyoon_family.hande.core

import org.json.JSONObject
import java.io.File

data class MessageUi(val seq: Long, val sender: String, val text: String, val mine: Boolean, val attachment: Boolean = false)

class MessageLog(private val file: File, private val seal: (ByteArray) -> ByteArray, private val open: (ByteArray) -> ByteArray) {
    private val lock = Any()
    private val items = mutableListOf<MessageUi>()

    init {
        if (file.exists()) {
            val text = runCatching { String(open(file.readBytes()), Charsets.UTF_8) }.getOrDefault("")
            for (line in text.lineSequence()) {
                if (line.isBlank()) continue
                runCatching {
                    val o = JSONObject(line)
                    items += MessageUi(o.getLong("seq"), o.getString("sender"), o.getString("text"), o.getBoolean("mine"), o.optBoolean("attachment", false))
                }
            }
        }
    }

    fun all(): List<MessageUi> = synchronized(lock) { items.toList() }

    fun append(m: MessageUi) {
        synchronized(lock) {
            if (items.any { it.seq == m.seq && it.sender == m.sender }) return
            items += m
            items.sortBy { it.seq }
            val text = items.joinToString("\n") { i ->
                JSONObject().put("seq", i.seq).put("sender", i.sender).put("text", i.text).put("mine", i.mine).put("attachment", i.attachment).toString()
            } + "\n"
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(seal(text.toByteArray(Charsets.UTF_8)))
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        }
    }
}
