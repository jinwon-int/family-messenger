// 에이전트(불지기) 판정 고정(한데 디자인 1차) — 웹 `strings.test.mjs` 의 actorOf/isAgentDevice/participantName 과 같은 경우들. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AgentActorsTest {
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
}
