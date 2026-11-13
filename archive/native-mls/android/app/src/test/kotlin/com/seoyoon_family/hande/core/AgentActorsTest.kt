// 에이전트(불지기) 판정 고정(한데 디자인 1차) — 웹 `strings.test.mjs` 의 actorOf/isAgentDevice/participantName 과 같은 경우들. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

class AgentActorsTest {
    // #422 공유 벡터 — 웹 strings.test.mjs·봇 responder.rs·iOS AgentConversationTests 와 같은 답.
    private val vectors: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/agent-actors-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("agent-actors-vectors.json not found above ${File(".").absolutePath}")
    }

    @Test fun sharedAgentActorVectors() {
        assertEquals((vectors["agent_actors"] as List<*>).map { it as String }.toSet(), AgentActors.ACTORS)
        val cases = vectors["cases"] as List<*>
        assertTrue(cases.size >= 20)
        for (c in cases) {
            c as Map<*, *>
            val device = c["device"] as String
            assertEquals(c["agent"] as Boolean, AgentActors.isAgentDevice(device), device)
        }
        // `bot*` 접두는 봇의 루프 방지 규칙일 뿐 — 클라이언트는 명시 목록만.
        for (d in (vectors["bot_prefix_only"] as Map<*, *>)["devices"] as List<*>) assertFalse(AgentActors.isAgentDevice(d as String), d)
    }

    @Test fun actorIsTheFirstDashSegment() {
        assertEquals("seoseo", AgentActors.actorOf("seoseo-iphone"))
        assertEquals("jinon", AgentActors.actorOf("jinon-ipad-1a2b3c"))
        assertEquals("bot", AgentActors.actorOf("bot-dungae"))
        assertEquals("plain", AgentActors.actorOf("plain"), "하이픈이 없으면 전체가 actor")
        assertEquals("", AgentActors.actorOf(""))
    }

    @Test fun agentDevicesAreTheExplicitListOnly() {
        assertTrue(AgentActors.isAgentDevice("seoseo-iphone"))
        assertTrue(AgentActors.isAgentDevice("gongmyoung-a1b2c3"))
        assertTrue(AgentActors.isAgentDevice("bot-dungae"), "옛 bot-<node> 도 에이전트")
        assertFalse(AgentActors.isAgentDevice("jinon-ipad"))
        assertFalse(AgentActors.isAgentDevice("mom-iphone-aaaaaa"))
        assertFalse(AgentActors.isAgentDevice("card-bot"), "알림 서비스 봇은 에이전트가 아니다(웹 serviceNames)")
        assertFalse(AgentActors.isAgentDevice(""))
        assertEquals(13, AgentActors.ACTORS.size, "bot + 노드 12")
        assertEquals(12, AgentActors.NAMES.size)
    }

    @Test fun displayNameUsesNicknames() {
        assertEquals("공명✴️", AgentActors.displayName("gongmyoung-a1b2c3"))
        assertEquals("서서✴️", AgentActors.displayName("seoseo-iphone"))
        assertEquals("등애✳️", AgentActors.displayName("bot-dungae"), "옛 bot-<node> 는 둘째 마디가 노드")
        assertEquals("봇", AgentActors.displayName("bot"), "노드를 모르는 봇")
        assertEquals("진원", AgentActors.displayName("owner-android-bbbbbb"))
        assertEquals("mom", AgentActors.displayName("mom-iphone-aaaaaa"), "모르는 사람은 actor 그대로")
        assertEquals("", AgentActors.displayName(""))
    }

    // 방 이름 = iOS `Strings.roomNames`·웹 `roomNames` 와 같은 표(오너 2026-11-06: 「대화방명 닉네임도 아이폰이랑 맞춰줘」).
    @Test fun roomLabelMatchesIosAndWeb() {
        assertEquals("🏠 가족", AgentActors.roomLabel("family"))
        assertEquals("공명✴️", AgentActors.roomLabel("family-acc"))
        assertEquals("💳 가족 카드 알림", AgentActors.roomLabel("family-card"))
        assertEquals("🔔 플릿 알림", AgentActors.roomLabel("fleet-alerts"))
        assertEquals("⚡ 번개장터 알림", AgentActors.roomLabel("bunjang-alerts"))
        assertEquals("📷 인스타 새 글", AgentActors.roomLabel("insta-news"))
        // 노드 개인방(ID = 노드 이름)은 그 노드 닉네임
        assertEquals("순욱✴️", AgentActors.roomLabel("soonwook"))
        assertEquals("등애✳️", AgentActors.roomLabel("dungae"))
        // 모르는 방은 ID 그대로
        assertEquals("lobby-test", AgentActors.roomLabel("lobby-test"))
    }

    @Test fun serviceBotsShowTheirAlertName() {
        assertEquals("💳 카드 알림", AgentActors.displayName("card-bot"))
        assertEquals("🔔 플릿 알림", AgentActors.displayName("fleet-bot"))
        assertEquals("⚡ 번개장터 알림", AgentActors.displayName("bunjang-bot"))
        assertEquals("📷 인스타 알림", AgentActors.displayName("insta-bot"))
        // 사람·에이전트는 그대로
        assertEquals("진원", AgentActors.displayName("owner-android-55f1ba"))
        assertEquals("순욱✴️", AgentActors.displayName("soonwook-bot"))
    }
}
