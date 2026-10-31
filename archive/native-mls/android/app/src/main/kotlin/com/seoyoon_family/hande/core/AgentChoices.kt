// agent-choices-v1(#620): 에이전트 글 끝의 번호 선택지 판정 — 규격 `archive/native-mls/AGENT-CHOICES-V1.md` 그대로(웹·iOS 와 같은 공유 벡터
// `tests/fixtures/agent-choices-vectors.json`). 숫자는 ASCII 0-9 만, 공백(\s)은 스페이스·탭·줄바꿈만 — 플랫폼 정규식 차이를 없애려고 문자 묶음을 직접 쓴다.
// android.* 없이 JVM 에서 돈다. 상태(open/answered/closed)는 타임라인에서 계산하고 저장하지 않는다.
package com.seoyoon_family.hande.core

/** 선택지 하나: 번호(1..k) + 라벨(`**`·`__`·`` ` `` 지움, 연속 공백 한 칸, 양끝 공백 제거). */
data class AgentChoiceItem(val number: Int, val label: String)

/** 판정 결과: 항목 2~9개(번호 1..k 연속) + 권장 번호(없으면 null). */
data class AgentChoices(val items: List<AgentChoiceItem>, val recommended: Int?) {
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
        private val CUES = listOf(
            "?", "？", "권장", "선택", "골라", "고르", "답해", "원하시", "할까요", "하시겠", "정해", "다음 액션", "다음 단계", "옵션",
            "choose", "option", "recommend",
        )

        private fun spaceChar(c: Char) = c == ' ' || c == '\t'
        private fun blankLine(line: String) = line.all { spaceChar(it) }
        private fun indentedLine(line: String) = line.startsWith("\t") || line.startsWith("  ")
        private fun hasCue(s: String): Boolean {
            val lower = s.lowercase()
            return CUES.any { it in lower }
        }

        private fun cleanLabel(raw: String): String =
            raw.replace("**", "").replace("__", "").replace("`", "").replace(SPACES, " ").trim { it == ' ' || it == '\t' }

        /** 규격 §1: 에이전트 텍스트 본문 → 선택지(아니면 null). */
        fun parse(text: String): AgentChoices? {
            val normalized = text.replace("\r\n", "\n")
            val lines = normalized.split("\n")

            var inFence = false
            var block: MutableList<AgentChoiceItem>? = null
            var open = false
            var invalid = false
            var blockStart = -1 // 블록 첫 항목 줄
            var blockEnd = -1 // 마지막 항목 줄 또는 그 이어지는 줄

            for ((i, line) in lines.withIndex()) {
                val fenceLine = line.trimStart { it == ' ' || it == '\t' }.startsWith("```")
                val item = if (inFence || fenceLine) null else ITEM.matchEntire(line)
                if (fenceLine) inFence = !inFence
                when {
                    item != null -> {
                        val number = item.groupValues[1].toInt()
                        val label = cleanLabel(item.groupValues[2])
                        val current = block
                        when {
                            number == 1 -> {
                                block = mutableListOf(AgentChoiceItem(1, label))
                                open = true; invalid = false; blockStart = i; blockEnd = i
                            }
                            open && current != null && number == current.last().number + 1 -> {
                                current += AgentChoiceItem(number, label)
                                blockEnd = i
                            }
                            else -> { invalid = true; open = false }
                        }
                    }
                    // 펜스 줄과 펜스 안의 줄은 항목이 될 수 없는 일반 줄(펜스 줄은 블록을 닫는다).
                    fenceLine -> open = false
                    blankLine(line) -> Unit
                    indentedLine(line) -> if (open) blockEnd = i
                    else -> open = false
                }
            }

            val items = block ?: return null
            if (invalid) return null
            if (items.size !in 2..9) return null
            val trailing = lines.subList(blockEnd + 1, lines.size).filterNot { blankLine(it) }
            if (trailing.size > 3) return null
            val above = lines.subList(0, blockStart).lastOrNull { !blankLine(it) }
            val cue = (above != null && hasCue(above)) || trailing.any { hasCue(it) } || items.any { hasCue(it.label) }
            if (!cue) return null

            val k = items.size
            val fromPattern = RECOMMENDED.find(normalized)?.groupValues?.get(1)?.toInt()?.takeIf { it in 1..k }
            val recommended = fromPattern ?: items.firstOrNull { "권장" in it.label }?.number
            return AgentChoices(items, recommended)
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

        /** 에이전트가 보낸 텍스트 글인가(내 글·첨부·사람 글은 선택지를 판정하지 않는다). */
        fun isAgentText(m: MessageUi): Boolean = !m.mine && !m.attachment && AgentActors.isAgentDevice(m.sender)

        /**
         * 규격 §2: `messages`(저장된 글, seq 순 — status 임시 줄 없음)의 `index` 번째 글의 상태. 선택지가 아니면 null.
         * 뒤에 글이 없으면 open, 바로 다음 글이 내 것이고 답 판정이 맞으면 answered(번호 목록), 그 밖은 closed.
         */
        fun stateAt(messages: List<MessageUi>, index: Int, choices: AgentChoices): State {
            val next = messages.getOrNull(index + 1) ?: return State.Open
            if (next.mine && !next.attachment) {
                reply(next.text, choices.items.size)?.let { return State.Answered(it) }
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
