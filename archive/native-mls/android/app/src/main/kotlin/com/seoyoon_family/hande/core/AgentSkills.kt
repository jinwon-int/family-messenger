// 에이전트 답 끝의 사용 스킬 줄(`📘 gh-pr-flow · wiki-record`) → 본문 + 칩 이름(#887 3단계, 줄 형식은 #834).
// 봇이 브리지 `result.skills`(ccc-node#2833)로 붙이는 줄이다(native-mls bot `skills_footer`).
// 규칙은 웹 `web/hande/agent-markdown.js` `splitSkills` 를 그대로 옮겼다(iOS `FamilyMLSCore/Agent/AgentSkills.swift` 와 같은 뜻):
// 빈 줄 바로 뒤의 **마지막 줄**이 `📘 ` + 이름 1~8개(` · ` 로 구분)이고, 이름이 모두 식별자 모양이며, 앞에 본문이 있을 때만 뗀다.
// 아니면 글 그대로(skills 빈 목록). 받은 글은 신뢰하지 않는다 — 칩에 들어가는 것은 이 규칙이 거른 식별자뿐이다.
// android.* · Compose 없음 → JVM 테스트(`AgentSkillsTest`, 공유 벡터 `tests/fixtures/agent-markdown-vectors.json` 의 `skills`).
package com.seoyoon_family.hande.core

object AgentSkills {
    /** 한 답에 담기는 스킬 이름 수 상한(봇 `MAX_REPLY_SKILLS` · 웹 `MAX_SKILLS` 와 같다). */
    const val MAX_SKILLS = 8
    private const val PREFIX = "📘 "
    private const val SEPARATOR = " · "
    private const val MAX_NAME_LENGTH = 64

    /** 본문(스킬 줄을 뗀 글)과 칩 이름(첫 등장 순, 중복 없음). 스킬 줄이 없으면 `Split(text, 빈 목록)`. */
    data class Split(val body: String, val skills: List<String>)

    private fun isBlankish(c: Char) = c == ' ' || c == '\t' || c == '\r' || c == '\n'

    /**
     * 웹의 `/\n[ \t]*\n📘 ([^\n]+?)[ \t\r\n]*$/` 와 같은 판정을 정규식 없이 한다(기기의 정규식 엔진 차이·`$` 의 줄 끝 해석에 기대지 않게):
     * 끝의 공백·줄바꿈을 건너뛴 마지막 줄이 `📘 ` 로 시작하고, 그 줄 바로 앞이 「줄바꿈 + 공백·탭만 + 줄바꿈」(빈 줄 하나)일 때.
     */
    fun split(source: String?): Split {
        val text = source ?: ""
        val unchanged = Split(text, emptyList())
        var end = text.length
        while (end > 0 && isBlankish(text[end - 1])) end -= 1
        val lineStart = text.lastIndexOf('\n', end - 1) + 1
        if (lineStart < 2 || !text.startsWith(PREFIX, lineStart)) return unchanged
        // 스킬 줄 바로 앞: text[lineStart - 1] 은 줄바꿈. 그 앞으로 공백·탭만 지나 다시 줄바꿈이어야 한다.
        var blank = lineStart - 2
        while (blank >= 0 && (text[blank] == ' ' || text[blank] == '\t')) blank -= 1
        if (blank < 0 || text[blank] != '\n') return unchanged
        // 이름이 한 글자도 없으면(`📘 ` 뒤가 공백뿐) 스킬 줄이 아니다 — 끝 공백은 위에서 이미 건너뛰었다.
        val namesStart = lineStart + PREFIX.length
        if (namesStart >= end) return unchanged
        val names = text.substring(namesStart, end).split(SEPARATOR)
        if (names.size > MAX_SKILLS || !names.all(::isSkillName)) return unchanged
        val body = text.substring(0, blank).trimEnd { isBlankish(it) }
        if (body.isEmpty()) return unchanged
        return Split(body, names.distinct())
    }

    /** 식별자 모양 스킬 이름 — 브리지·봇·웹과 같은 규칙(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`). */
    fun isSkillName(name: String): Boolean {
        if (name.isEmpty() || name.length > MAX_NAME_LENGTH || !isAlnum(name[0])) return false
        return name.all { isAlnum(it) || it == '.' || it == '_' || it == ':' || it == '-' }
    }

    private fun isAlnum(c: Char) = c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9'
}
