// 누가 에이전트(불지기)인가 — 웹 `hande/strings.js` 의 `AGENT_ACTORS`·`agentNames`·`actorOf`·`isAgentDevice` 를 그대로 옮긴 순수 판정(한데 디자인 1차).
// 명시 목록이 정본이고 ID 모양으로 추측하지 않는다(iOS `FC_AGENT_ACTORS`·웹 `participants.js` 와 같은 원칙). android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

object AgentActors {
    /**
     * 에이전트 노드 이름 → 보여 줄 이름 = Matrix 닉네임과 동일(결정 2026-10-19 ③, #422 — 한글 + 계정 마커).
     * 정본은 Matrix profile displayname. 바뀌면 웹 `agentNames`·iOS `Strings.agentNames` 와 함께 고친다.
     */
    val NAMES: Map<String, String> = mapOf(
        "bangtong" to "방통✳️", "daegyo" to "대교✴️", "dungae" to "등애✳️", "gongmyoung" to "공명✴️", "gongyung" to "공융✴️", "gwakga" to "곽가✳️",
        "jingun" to "진군✳️", "nosuk" to "노숙✳️", "seoseo" to "서서✴️", "sogyo" to "소교✴️", "soonwook" to "순욱✴️", "yukson" to "육손✳️",
    )

    /** 에이전트(봇) actor — 기기 ID 첫 마디. 옛 `bot-<node>` 와 새 `<node>-<suffix>`(#422) 둘 다(웹 `AGENT_ACTORS` 와 같은 목록). */
    val ACTORS: Set<String> = setOf("bot") + NAMES.keys

    /** 사람 actor → 보여 줄 이름(웹 `peopleNames`). 오너는 「진원」(오너 결정 2026-10-21). 그 밖은 actor 그대로. */
    private val PEOPLE: Map<String, String> = mapOf("owner" to "진원", "jungin" to "쩡이🍎")

    /** 기기 ID 의 첫 마디(첫 `-` 앞). `-` 가 없으면 전체. */
    fun actorOf(device: String): String = device.substringBefore('-')

    fun isAgentDevice(device: String): Boolean = actorOf(device) in ACTORS

    /** 봇 기기 → 노드 이름. 옛 `bot-<node>` 는 둘째 마디, 새 `<node>-<suffix>` 는 actor. 노드를 모르면 "". */
    fun agentNode(device: String): String {
        val actor = actorOf(device)
        if (actor != "bot") return actor
        return device.substringAfter('-', "").substringBefore('-')
    }

    /**
     * 보낸 이 라벨(기기 종류 없이 — 웹 `participantName`): 에이전트는 노드 닉네임(모르면 노드 이름, 노드도 모르면 「봇」),
     * 사람은 닉네임(모르면 actor). 빈 기기 ID 는 "".
     */
    fun displayName(device: String): String {
        if (device.isEmpty()) return ""
        if (isAgentDevice(device)) {
            val node = agentNode(device)
            return if (node.isEmpty()) "봇" else NAMES[node] ?: node
        }
        val actor = actorOf(device)
        return PEOPLE[actor] ?: actor
    }
}
