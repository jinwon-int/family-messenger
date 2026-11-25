// 스킬 줄 → 칩 이름(#887 3단계) — 웹과 같은 공유 벡터(`archive/native-mls/tests/fixtures/agent-markdown-vectors.json` 의 `skills`)를 그대로 돌린다.
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

class AgentSkillsTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/agent-markdown-vectors.json")
            if (f.isFile) return@lazy (MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>)["skills"] as Map<*, *>
            dir = dir.parentFile
        }
        fail("agent-markdown-vectors.json not found above ${File(".").absolutePath}")
    }

    @Test fun limitMatchesTheSharedVectors() {
        assertEquals((fixture["max_skills"] as Number).toInt(), AgentSkills.MAX_SKILLS)
    }

    @Test fun splitVectors() {
        val cases = fixture["cases"] as List<*>
        assertTrue(cases.size >= 25)
        var chips = 0
        for (c in cases) {
            c as Map<*, *>
            val name = c["name"] as String
            val got = AgentSkills.split(c["text"] as String)
            assertEquals(c["body"] as String, got.body, name)
            assertEquals((c["skills"] as List<*>).map { it as String }, got.skills, name)
            // 떼지 않은 글은 한 글자도 바뀌지 않는다(복사·답장 인용이 기대는 성질).
            if (got.skills.isEmpty()) assertEquals(c["text"] as String, got.body, name) else chips += 1
        }
        assertTrue(chips >= 8, "vectors must hold both outcomes")
    }

    @Test fun nullAndNamesRule() {
        assertEquals(AgentSkills.Split("", emptyList()), AgentSkills.split(null))
        for (ok in listOf("a", "gh-pr-flow", "plugin:skill", "A.b_c-9", "9lives", "x".repeat(64))) assertTrue(AgentSkills.isSkillName(ok), ok)
        for (bad in listOf("", "-lead", ".dot", "bad name", "스킬", "a/b", "a\nb", "x".repeat(65), "a·b")) assertFalse(AgentSkills.isSkillName(bad), bad)
    }

    @Test fun chipNamesAreAlwaysIdentifiers() {
        // 받은 글이 무엇이든 칩에 들어가는 것은 식별자 모양 이름뿐이다 — 서식·주소·줄바꿈이 섞이면 줄 전체를 그대로 둔다.
        for (line in listOf(
            "📘 <b>x</b>", "📘 [a](https://evil.example/x)", "📘 a · https://evil.example", "📘 `a`", "📘 **a**", "📘 a\u0000b", "📘 a · b ·",
        )) {
            val text = "답\n\n$line"
            assertEquals(AgentSkills.Split(text, emptyList()), AgentSkills.split(text), line)
        }
        val split = AgentSkills.split("답\n\n📘 gh-pr-flow · wiki-record")
        assertTrue(split.skills.all(AgentSkills::isSkillName))
    }

    @Test fun longInputIsLinear() {
        // 끝에서부터 한 번만 훑는다: 빈 줄·📘 줄이 수없이 반복돼도 마지막 줄만 본다.
        val text = "답\n\n📘 a\n".repeat(30_000) + "\n📘 last"
        val started = System.nanoTime()
        val got = AgentSkills.split(text)
        assertEquals(listOf("last"), got.skills)
        assertTrue(got.body.endsWith("📘 a"))
        assertTrue((System.nanoTime() - started) / 1_000_000 < 2_000)
    }
}
