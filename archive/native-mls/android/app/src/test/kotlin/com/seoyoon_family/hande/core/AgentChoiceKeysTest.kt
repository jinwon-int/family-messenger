// agent-choices-v1 §3.1(#629 · Android #833): 선택지 카드 키보드 단축키 — 공유 벡터 `keys`(웹 `choiceKeyAction`·iOS `AgentChoiceKeysTests` 와 같은 답).
// JSON 읽개는 AgentChoicesTest 의 [MiniJson](org.json 은 JVM 단위 테스트에서 Android 스텁이다).
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.fail

class AgentChoiceKeysTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/agent-choices-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("agent-choices-vectors.json not found above ${File(".").absolutePath}")
    }

    private fun flag(raw: Any?): Boolean = raw as Boolean? ?: false

    private fun input(raw: Map<*, *>, name: String): AgentChoiceKeys.Input {
        val key = when (val k = raw["key"] as String?) {
            "digit" -> AgentChoiceKeys.Key.Digit(((raw["digit"] as Long?) ?: fail("$name: input.digit")).toInt())
            "enter" -> AgentChoiceKeys.Key.Enter
            "other" -> AgentChoiceKeys.Key.Other
            else -> fail("$name: unknown key $k")
        }
        return AgentChoiceKeys.Input(
            key, alt = flag(raw["alt"]), ctrl = flag(raw["ctrl"]), meta = flag(raw["meta"]), shift = flag(raw["shift"]),
            composing = flag(raw["composing"]),
        )
    }

    private fun card(raw: Any?, name: String): AgentChoiceKeys.Card? {
        if (raw == null) return null
        raw as Map<*, *>
        val selected = (raw["selected"] as List<*>? ?: emptyList<Any>()).map { (it as Long).toInt() }.toSet()
        return AgentChoiceKeys.Card(((raw["count"] as Long?) ?: fail("$name: card.count")).toInt(), selected, flag(raw["enabled"]))
    }

    private fun expected(raw: Any?, name: String): AgentChoiceKeys.Action? {
        if (raw == null) return null
        raw as Map<*, *>
        return when (raw["action"] as String?) {
            "toggle" -> AgentChoiceKeys.Action.Toggle(((raw["number"] as Long?) ?: fail("$name: expected.number")).toInt())
            "send" -> AgentChoiceKeys.Action.Send
            else -> fail("$name: unknown expected action")
        }
    }

    @Test fun keyVectors() {
        val vectors = fixture["keys"] as List<*>
        assertEquals(18, vectors.size)
        for ((i, raw) in vectors.withIndex()) {
            raw as Map<*, *>
            val name = raw["name"] as String? ?: "keys[$i]"
            val pressed = input(raw["input"] as Map<*, *>, name)
            assertEquals(expected(raw["expected"], name), AgentChoiceKeys.decide(pressed, card(raw["card"], name)), name)
        }
    }

    @Test fun digitOutsideOneToNineIsNotIntercepted() {
        val card = AgentChoiceKeys.Card(count = 9, selected = emptySet(), enabled = true)
        assertNull(AgentChoiceKeys.decide(AgentChoiceKeys.Input(AgentChoiceKeys.Key.Digit(0), alt = true), card))
        assertNull(AgentChoiceKeys.decide(AgentChoiceKeys.Input(AgentChoiceKeys.Key.Digit(10), alt = true), card))
    }
}
