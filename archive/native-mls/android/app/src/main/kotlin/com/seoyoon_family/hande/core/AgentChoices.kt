// agent-choices(#620 · v2 #671): 에이전트가 명시한 번호 선택지 판정 — 규격 `archive/native-mls/AGENT-CHOICES-V1.md` 그대로(웹·iOS 와 같은 공유 벡터
// `tests/fixtures/agent-choices-vectors.json`). 숫자는 ASCII 0-9 만, 공백(\s)은 스페이스·탭·줄바꿈만 — 플랫폼 정규식 차이를 없애려고 문자 묶음을 직접 쓴다.
// android.* 없이 JVM 에서 돈다. 상태(open/answered/closed)는 타임라인에서 계산하고 저장하지 않는다.
// v2(#671, 같은 규격 §5): 에이전트가 `[답변 필요]` 머리줄로 명시한 블록을 카드로 만든다.
// §6(#671 PR D): 명시 블록만 카드가 된다 — 머리줄 없는 끝 목록을 단서어로 추측하던 v1 판정은 없앴다.
package com.seoyoon_family.hande.core

import java.util.Locale

/** 선택지 하나: 번호(1..k) + 라벨(`**`·`__`·`` ` `` 지움, 연속 공백 한 칸, 양끝 공백 제거). */
data class AgentChoiceItem(val number: Int, val label: String)

/**
 * 판정 결과: 항목(번호 1..k 연속 — 명시 블록 1~9개) + 권장 번호(없으면 null).
 * §5: `mode`(머리줄의 `하나만`·`one` → ONE, 아니면 MANY)·`explicit`(명시 블록이면 true — `parse` 결과는 언제나 true, §6).
 * §1.7 `recommendedNumbers`: 권장 번호 모두(오름차순·중복 없음, 없으면 빈 목록) — 메시지의 `권장 N번`(1..k) ∪ 라벨에 `권장` 이 든
 * 모든 항목(접두 `N. (권장) …` 여럿 가능). 주지 않으면 `recommended` 하나(또는 빈 목록) — 옛 생성자 호출 그대로.
 */
data class AgentChoices(
    val items: List<AgentChoiceItem>,
    val recommended: Int?,
    val mode: Mode = Mode.MANY,
    val explicit: Boolean = false,
    val recommendedNumbers: List<Int> = listOfNotNull(recommended),
) {
    /** 선택 모드(규격 §5.2). ONE 은 라디오 카드·한 개만 답(§5.1, #671 PR B), MANY 는 복수 선택(#624). */
    enum class Mode { ONE, MANY }

    /** 번호의 라벨(없으면 null). */
    fun labelOf(number: Int): String? = items.firstOrNull { it.number == number }?.label

    /** 선택지 카드의 상태(규격 §2). */
    sealed class State {
        object Open : State()
        /** 내 바로 다음 글이 고른 번호들(오름차순·중복 없음·비어 있지 않음, #624 복수 선택). */
        data class Answered(val numbers: List<Int>) : State()
        object Closed : State()
    }

    /** 말풍선 아래 그릴 카드: 선택지 + 상태. `closed` 는 만들지 않는다(카드 없음). */
    data class Card(val choices: AgentChoices, val state: State)

    companion object {
        private const val WS = "[ \\t\\n]"
        // `.` 대신 줄 끝 문자를 뺀 묶음 — JVM `.`/`$` 의 줄 끝 규칙(마지막 \r 앞에서 `$` 일치 등)이 웹·iOS 와 달라지지 않게 matchEntire 로 쓴다.
        private val ITEM = Regex("^ {0,3}([0-9]{1,2})[.)][ \\t]+([^ \\t\\n\\r\\u2028\\u2029][^\\n\\r\\u2028\\u2029]*)$")
        private val RECOMMENDED = Regex("권장$WS*[:：]?$WS*([0-9]{1,2})$WS*번")
        private val SPACES = Regex("[ \\t]+")

        private fun spaceChar(c: Char) = c == ' ' || c == '\t'
        private fun blankLine(line: String) = line.all { spaceChar(it) }
        private fun indentedLine(line: String) = line.startsWith("\t") || line.startsWith("  ")

        private fun cleanLabel(raw: String): String =
            raw.replace("**", "").replace("__", "").replace("`", "").replace(SPACES, " ").trim { it == ' ' || it == '\t' }

        private const val MAX_ITEMS = 9
        private val HEADERS = listOf("[답변 필요]", "[answer needed]") // 영문은 소문자로 비교

        private fun isFenceLine(line: String) = line.trimStart { it == ' ' || it == '\t' }.startsWith("```")
        private fun asciiAlnum(c: Char) = c in 'a'..'z' || c in '0'..'9'

        /** 단어 `one`: 앞뒤가 ASCII 소문자·숫자가 아니다(이미 소문자로 바꾼 줄에서 본다 — JS `(^|[^a-z0-9])one([^a-z0-9]|$)`). */
        private fun hasWordOne(lower: String): Boolean {
            var at = lower.indexOf("one")
            while (at >= 0) {
                val before = at == 0 || !asciiAlnum(lower[at - 1])
                val after = at + 3 >= lower.length || !asciiAlnum(lower[at + 3])
                if (before && after) return true
                at = lower.indexOf("one", at + 1)
            }
            return false
        }

        /** 규격 §5.1·§5.2: v2 머리줄이면 모드, 아니면 null. */
        private fun headerMode(line: String): Mode? {
            val clean = line.replace("**", "").replace("__", "").replace("`", "")
            val lower = clean.lowercase(Locale.ROOT)
            if (HEADERS.none { it in lower }) return null
            return if ("하나만" in clean || hasWordOne(lower)) Mode.ONE else Mode.MANY
        }

        /** 권장 번호(규격 §1.7): 메시지 전체의 `권장 N번`(1..k) → 라벨에 `권장` 이 든 첫 항목 → null. */
        private fun recommendedOf(normalized: String, items: List<AgentChoiceItem>): Int? {
            val k = items.size
            val fromPattern = RECOMMENDED.find(normalized)?.groupValues?.get(1)?.toInt()?.takeIf { it in 1..k }
            return fromPattern ?: items.firstOrNull { "권장" in it.label }?.number
        }

        /**
         * 권장 번호 모두(규격 §1.7): 메시지 전체의 `권장 N번` 첫 일치(1..k 일 때) ∪ 라벨에 `권장` 이 든 모든 항목 — 오름차순·중복 없음.
         * 접두 `N. (권장) …`·접미 `… (권장)` 어느 쪽이든 라벨에 `권장` 이 들어 있으면 된다.
         */
        private fun recommendedNumbersOf(normalized: String, items: List<AgentChoiceItem>): List<Int> {
            val named = RECOMMENDED.find(normalized)?.groupValues?.get(1)?.toInt()
            // items 는 1..k 오름차순이라 거르기만 하면 오름차순·중복 없음이다.
            return items.filter { it.number == named || "권장" in it.label }.map { it.number }
        }

        /** v2 명시 블록 하나(판정 중). `mode` 가 null 이면 머리줄이 없는 블록. */
        private class ExplicitBlock(val items: MutableList<AgentChoiceItem>, val mode: Mode?) {
            var invalid = false
        }

        /**
         * 규격 §5: `[답변 필요]` 머리줄이 붙은 블록 — 위치·뒤 줄 수·단서어는 보지 않는다.
         * 머리줄 = 펜스 밖, 블록 첫 항목 바로 위의 비어 있지 않은 줄. 마지막 유효 명시 블록(항목 1~9)이 결과.
         * 닫힌 블록은 뒤의 번호 줄로 무효가 되지 않는다(무효는 열린 블록만).
         */
        private fun parseExplicit(normalized: String, lines: List<String>): AgentChoices? {
            var found: ExplicitBlock? = null
            var block: ExplicitBlock? = null // 열린 블록(닫히면 null)
            var prevText: String? = null // 바로 앞의 비어 있지 않은 줄
            var prevFenced = false // 그 줄이 펜스 줄·펜스 안 줄인가
            var fenced = false
            fun finish() {
                val b = block
                if (b != null && !b.invalid && b.mode != null && b.items.size <= MAX_ITEMS) found = b
                block = null
            }
            for (line in lines) {
                if (isFenceLine(line)) {
                    fenced = !fenced
                    finish(); prevText = line; prevFenced = true
                    continue
                }
                if (fenced) {
                    finish()
                    if (!blankLine(line)) { prevText = line; prevFenced = true }
                    continue
                }
                val item = ITEM.matchEntire(line)
                if (item != null) {
                    val number = item.groupValues[1].toInt()
                    val label = cleanLabel(item.groupValues[2])
                    val current = block
                    val header = prevText
                    when {
                        number == 1 -> {
                            finish()
                            block = ExplicitBlock(
                                mutableListOf(AgentChoiceItem(1, label)),
                                if (header != null && !prevFenced) headerMode(header) else null,
                            )
                        }
                        current != null && number == current.items.last().number + 1 -> { current.items += AgentChoiceItem(number, label) }
                        current != null -> { current.invalid = true; finish() }
                    }
                    prevText = line; prevFenced = false
                    continue
                }
                if (blankLine(line)) continue
                if (block != null && indentedLine(line)) continue // 이어지는 줄(라벨엔 넣지 않는다)
                finish(); prevText = line; prevFenced = false
            }
            finish()
            val f = found ?: return null
            val items = f.items.toList()
            return AgentChoices(
                items, recommendedOf(normalized, items), f.mode ?: Mode.MANY, explicit = true,
                recommendedNumbers = recommendedNumbersOf(normalized, items),
            )
        }

        /**
         * 규격 §5·§6: 에이전트 텍스트 본문 → 선택지(아니면 null). `[답변 필요]` 머리줄로 명시한 블록만 카드가 된다 —
         * 머리줄 없는 번호 목록은 끝에 있어도 null(§6, #671 PR D — v1 단서어 추측은 쓰지 않는다).
         */
        fun parse(text: String): AgentChoices? {
            val normalized = text.replace("\r\n", "\n")
            return parseExplicit(normalized, normalized.split("\n"))
        }

        private fun trimChar(c: Char) = c == ' ' || c == '\t' || c == '\n' || c == '\r'
        private fun digit(c: Char) = c in '0'..'9'
        private const val SEPARATORS = ",，、/+→" // 한 글자 구분자(`->` 는 따로 본다)

        /**
         * 규격 §2 「답 판정」(#624): 먼저 A. 번호 나열(`1` · `1, 3` …), 아니면 B. 줄 형식(`1. 라벨` 줄들 — compose 결과).
         * 번호가 모두 1..count 이면 오름차순·중복 없는 목록, 아니면 null.
         */
        fun reply(text: String, count: Int): List<Int>? = replyNumbers(text, count) ?: replyLines(text, count)

        /**
         * 답 판정 A: 정규식 대신 차례로 읽는다. 번호(ASCII 1~2자, 뒤에 [공백+]`번` 이 있으면 소비) 와
         * 구분자(공백 + `,` `，` `、` `/` `+` `→` `->` 중 하나(선택) + 공백 — 한 글자 이상, 글 끝이 아니어야 함)가 번갈아 온다.
         */
        private fun replyNumbers(text: String, count: Int): List<Int>? {
            var t = text.trim { trimChar(it) }
            if (t.endsWith('.')) t = t.dropLast(1).trimEnd { trimChar(it) }
            if (t.isEmpty()) return null
            val n = t.length
            val picked = sortedSetOf<Int>()
            var i = 0
            while (true) {
                // 번호: ASCII 숫자 1~2자(3자 이상이면 null).
                val start = i
                while (i < n && digit(t[i])) i++
                if (i - start !in 1..2) return null
                val number = t.substring(start, i).toInt()
                if (number !in 1..count) return null
                picked += number
                // 뒤에 (스페이스·탭 +) `번` 이 있을 때만 거기까지 소비 — 없으면 공백은 구분자 몫.
                var j = i
                while (j < n && spaceChar(t[j])) j++
                if (j < n && t[j] == '번') i = j + 1
                if (i == n) break
                // 구분자: 공백 → (한 글자 구분자 또는 `->`) → 공백. 한 글자도 못 먹었거나 뒤가 글 끝이면 null.
                val sepStart = i
                while (i < n && spaceChar(t[i])) i++
                if (i < n && t[i] in SEPARATORS) i++
                else if (t.startsWith("->", i)) i += 2
                while (i < n && spaceChar(t[i])) i++
                if (i == sepStart || i == n) return null
            }
            return picked.toList()
        }

        /**
         * 답 판정 B: 공백뿐인 줄(스페이스·탭·\r)을 버린 뒤 남은 **모든** 줄이 §1 항목 줄(`ITEM`)이어야 한다. 라벨 글은 비교하지 않는다.
         */
        private fun replyLines(text: String, count: Int): List<Int>? {
            val lines = text.replace("\r\n", "\n").split("\n").filterNot { line -> line.all { spaceChar(it) || it == '\r' } }
            if (lines.isEmpty()) return null
            val picked = sortedSetOf<Int>()
            for (line in lines) {
                val number = ITEM.matchEntire(line)?.groupValues?.get(1)?.toInt() ?: return null
                if (number !in 1..count) return null
                picked += number
            }
            return picked.toList()
        }

        /**
         * 규격 §5.1 「고르기」(#671 PR B): 고른 번호 + 행 하나 탭 → 새 선택(오름차순·중복 없음).
         * MANY: 그 번호를 켜고 끈다(#624). ONE: 그 번호 하나로 바꾼다 — 이미 그것만 골랐으면 비운다(남은 복수 선택 기억도 버린다).
         */
        fun toggle(selected: List<Int>, number: Int, mode: Mode): List<Int> {
            val current = selected.toSortedSet()
            if (mode == Mode.ONE) return if (current.size == 1 && current.first() == number) emptyList() else listOf(number)
            if (!current.remove(number)) current += number
            return current.toList()
        }

        /**
         * 규격 §2 「답 판정」 + §5.1: 내 답 → 고른 번호. ONE 선택지에 번호가 둘 이상이면 답이 아니다(null → closed).
         */
        fun answer(choices: AgentChoices, text: String): List<Int>? {
            val numbers = reply(text, choices.items.size) ?: return null
            return if (choices.mode == Mode.ONE && numbers.size > 1) null else numbers
        }

        /** 라벨이 비었을 때 보낼 글에 쓰는 자리 글. */
        const val EMPTY_LABEL = "(내용 없음)"

        /**
         * 규격 §2 「보낼 글」: 고른 번호 → 오름차순·중복 제거 후 줄마다 `N. 라벨`(§1.6 정리된 라벨, 비었으면 `(내용 없음)`)을 `\n` 으로 잇는다.
         * `labels[i]` 는 번호 `i + 1` 의 라벨(보통 `choices.items.map { it.label }`). 결과는 답 판정 B 로 같은 집합이 된다(왕복).
         */
        fun compose(numbers: Collection<Int>, labels: List<String>): String =
            numbers.toSortedSet().joinToString("\n") { n ->
                val label = labels.getOrNull(n - 1)?.let { cleanLabel(it) }.orEmpty()
                "$n. " + label.ifEmpty { EMPTY_LABEL }
            }

        /**
         * 에이전트 또는 알림 전용 서비스 봇(§6.1 — 플릿 알림 ok/hold)이 보낸 텍스트 글인가(내 글·첨부·사람 글은 선택지를 판정하지 않는다).
         * 카드는 명시 블록만이라(§6) 블록을 쓰지 않는 다른 서비스 봇에는 영향이 없다.
         */
        fun isAgentText(m: MessageUi): Boolean =
            !m.mine && !m.attachment && (AgentActors.isAgentDevice(m.sender) || AgentActors.isServiceDevice(m.sender))

        /**
         * 규격 §2: `messages`(저장된 글, seq 순 — status 임시 줄 없음)의 `index` 번째 글의 상태. 선택지가 아니면 null.
         * 뒤에 글이 없으면 open, 바로 다음 글이 내 것이고 답 판정(`answer` — ONE 에 번호 여럿이면 아님)이 맞으면 answered(번호 목록), 그 밖은 closed.
         */
        fun stateAt(messages: List<MessageUi>, index: Int, choices: AgentChoices): State {
            val next = messages.getOrNull(index + 1) ?: return State.Open
            if (next.mine && !next.attachment) {
                answer(choices, next.text)?.let { return State.Answered(it) }
            }
            return State.Closed
        }

        /** 타임라인 전체 → 글마다 카드(없거나 closed 면 null). 결과 크기 = `messages.size`. */
        fun cards(messages: List<MessageUi>): List<Card?> = messages.mapIndexed { i, m ->
            if (!isAgentText(m)) return@mapIndexed null
            val choices = parse(m.text) ?: return@mapIndexed null
            when (val s = stateAt(messages, i, choices)) {
                State.Closed -> null
                else -> Card(choices, s)
            }
        }
    }
}
