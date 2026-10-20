// #366 3b · #338 스파이크 A 2차 — JVM(Linux) 왕복: Kotlin 바인딩(`MlsRoom`) + 호스트 어댑터(`FileRoomStore`) + in-memory 릴레이로
// `ios-ffi/tests/room_host.rs` 와 같은 시나리오를 돈다. 외부 테스트 프레임워크 없이 `main` 하나(JUnit 의존 0). 실패면 exit 1.
// 실행: android/scripts/jvm-roundtrip.sh (KOTLINC · JNA_JAR · BINDINGS_DIR · FFI_LIB_DIR).
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.MlsLobbySlot
import com.seoyoon_family.hande.mls.MlsLobby
import com.seoyoon_family.hande.mls.MlsRoom
import com.seoyoon_family.hande.mls.RoomEvent
import com.seoyoon_family.hande.mls.RoomException
import com.seoyoon_family.hande.mls.SendResult
import java.io.File
import java.nio.file.Files
import kotlin.system.exitProcess

private const val BASE = "http://relay.test"
private val failures = mutableListOf<String>()

private fun check(cond: Boolean, what: String) { if (!cond) { failures += what; println("  FAIL $what") } else println("  ok   $what") }

/** 한 기기 = 방 하나의 `MlsRoom` + 파일 저장소(임시 디렉터리) + 수신 기록. */
private class Device(val identity: String, relay: InMemoryRelay, dir: File) {
    val events = mutableListOf<RoomEvent>()
    val texts = mutableListOf<Triple<Long, String, String>>()
    val store = FileRoomStore(dir, "room-a", onEvent = { events += it }, onMessage = { seq, sender, _, pt -> texts += Triple(seq, sender, String(pt)) })
    var room: MlsRoom = MlsRoom(identity, "room-a", BASE, relay, store)

    /** 영속된 쌍으로 새 인스턴스를 만든다(재시작 대역). */
    fun restart(relay: InMemoryRelay) {
        val (state, sync) = store.load() ?: error("nothing persisted for $identity")
        room.close()
        room = MlsRoom.`import`(identity, "room-a", state, sync, BASE, relay, store)
    }
}

/** owner 가 방을 만들고 peer 를 초대(`invite`, 로컬 merge) → Welcome 게시 → peer 가 poll 로 join. */
private fun founded(relay: InMemoryRelay, tmp: File): Pair<Device, Device> {
    val owner = Device("owner-phone", relay, File(tmp, "owner"))
    val peer = Device("owner-pc", relay, File(tmp, "peer"))
    peer.room.poll()
    check(peer.events.isEmpty(), "404 no_such_room before the room exists is not an event")
    owner.room.dispatch("create", ByteArray(0))
    val kp = peer.room.dispatch("key_package", ByteArray(0))
    val welcome = owner.room.dispatch("invite", kp)
    val posted = owner.room.postWelcome(welcome, listOf("owner-pc"))
    check(posted.seq == 1L && !posted.duplicate, "welcome posted at seq 1")
    return owner to peer
}

private fun scenarioRoundtrip(tmp: File) {
    println("① two devices roundtrip")
    val relay = InMemoryRelay(BASE)
    val (owner, peer) = founded(relay, File(tmp, "s1"))
    val sent = owner.room.send("hello pc".toByteArray())
    check(sent is SendResult.Sent && sent.seq == 2L, "owner send → Sent seq 2 ($sent)")
    val id = (sent as SendResult.Sent).clientId
    check(id.startsWith("owner-phone-") && id.length == "owner-phone-".length + 8 && !id.contains("-echo-"), "dedup client_id <identity>-<8 hex>: $id")
    peer.room.poll()
    check(peer.events.any { it is RoomEvent.Joined }, "peer joined from the Welcome")
    check(peer.texts == listOf(Triple(2L, "owner-phone", "hello pc")), "peer decrypted the owner's message (${peer.texts})")
    val sync = peer.room.syncState()
    check(sync.cursor == 2L && sync.joined && sync.acked == 2L, "persisted after the page: cursor 2, acked == cursor")
    val back = peer.room.send("hello phone".toByteArray())
    check(back is SendResult.Sent && back.seq == 3L, "peer send → seq 3")
    owner.room.poll()
    check(owner.texts.lastOrNull() == Triple(3L, "owner-pc", "hello phone"), "owner decrypted the reply")
    check(owner.events.any { it is RoomEvent.OwnEvent && it.seq == 2L }, "own echo reported as OwnEvent")
    val persist = relay.trace.indexOfFirst { it.startsWith("POST application owner-phone-") }
    val stateFile = File(tmp, "s1/owner/room-a.state")
    check(persist > 0 && stateFile.exists(), "state file written before the first POST (B-H2)")
    peer.room.poll()
    check(relay.trace.any { it == "GET owner-pc after=2 ack=2" }, "next GET acks the persisted cursor (${relay.trace.filter { it.startsWith("GET owner-pc") }})")
}

private fun scenarioConflict(tmp: File) {
    println("② 409 cas_mismatch → queued → replayed after the next poll")
    val relay = InMemoryRelay(BASE)
    val (owner, peer) = founded(relay, File(tmp, "s2"))
    peer.room.poll()
    relay.bumpEpoch("room-a")
    val queued = owner.room.send("late".toByteArray())
    check(queued is SendResult.Queued, "send into a moved room → Queued ($queued)")
    check(owner.events.lastOrNull() is RoomEvent.Conflict, "Conflict event")
    check(relay.rows("room-a").none { it.kind == "application" }, "nothing stored on 409")
    owner.room.poll()
    val replayed = owner.events.filterIsInstance<RoomEvent.Replayed>().firstOrNull()
    check(replayed != null && replayed.epoch == 1L && replayed.clientId != (queued as SendResult.Queued).clientId, "replayed at epoch 1 with a fresh dedup key ($replayed)")
    peer.room.poll()
    check(peer.texts.lastOrNull()?.third == "late", "peer reads the replayed message")
}

private fun scenarioRestart(tmp: File) {
    println("③ restart from FileRoomStore (import) resumes at the cursor")
    val relay = InMemoryRelay(BASE)
    val (owner, peer) = founded(relay, File(tmp, "s3"))
    owner.room.send("one".toByteArray())
    peer.room.poll()
    check(peer.texts.map { it.third } == listOf("one"), "read one")
    val (_, sync) = peer.store.load()!!
    check(sync.cursor == 2L && sync.joined && sync.sends == 0UL, "sync file round-trips (cursor 2, joined, sends 0)")
    peer.restart(relay)
    owner.room.send("two".toByteArray())
    peer.room.poll()
    check(peer.texts.map { it.third } == listOf("one", "two"), "after restart only what came after the cursor (${peer.texts.map { it.third }})")
    val sent = peer.room.send("back".toByteArray())
    check(sent is SendResult.Sent, "the restored ratchet still encrypts ($sent)")
    val wrong = try { MlsRoom.`import`("owner-pc", "room-b", peer.store.load()!!.first, peer.store.load()!!.second, BASE, relay, peer.store); null } catch (e: RoomException) { e }
    check(wrong is RoomException.Host, "state bound to its room: import for another room is a Host error ($wrong)")
}

private fun scenarioTransientAndGap(tmp: File) {
    println("④ transport failure is transient · pruned history halts the room")
    val relay = InMemoryRelay(BASE)
    val (owner, peer) = founded(relay, File(tmp, "s4"))
    peer.room.poll()
    relay.down = true
    val err = try { owner.room.poll(); null } catch (e: RoomException) { e }
    check(err is RoomException.Relay && (err as RoomException.Relay).transient, "relay down → Relay(transient=true) ($err)")
    relay.down = false
    owner.room.poll()
    for (t in listOf("a", "b", "c")) owner.room.send(t.toByteArray())
    relay.pruneBefore("room-a", 4)
    peer.room.poll()
    check(peer.store.isHalted() && peer.store.haltReason() == "history_gap", "gap → halted marker 'history_gap' (${peer.store.haltReason()})")
    check(peer.room.syncState().cursor == 1L && peer.texts.isEmpty(), "nothing of the page moved")
    val before = relay.trace.count { it.startsWith("GET owner-pc") }
    peer.room.poll()
    check(relay.trace.count { it.startsWith("GET owner-pc") } == before, "a halted room is never fetched again")
    peer.restart(relay)
    check(peer.room.syncState().halted, "halt survives a restart via the persisted sync")
}

/** #366 3c — 기기 수준 객체 `MlsLobby`: 로비 key package 보충·Welcome 받아들이기(`MlsRoom.adopt`)·방 목록·방 닫기·푸시 등록. */
private fun scenarioLobby(tmp: File) {
    println("⑤ lobby: replenish → steward invites with a lobby package → adopt → rooms · close · push")
    val relay = InMemoryRelay(BASE)
    val dir = File(tmp, "s5")
    val lobbyStore = FileLobbyStore(File(dir, "phone"))
    var lobby = MlsLobby("owner-phone", BASE, relay, lobbyStore)
    check(lobbyStore.load()?.published?.isEmpty() == true, "the seed is persisted before anything else")
    val first = lobby.replenish(3u)
    check(first.minted == 3u && first.pruned == 0u && first.live == 3u && relay.lobbyLive("owner-phone") == 3, "replenish(3) → minted 3, live 3 ($first)")
    val persistIdx = relay.trace.indexOfFirst { it.startsWith("POST lobby owner-phone n=3") }
    check(persistIdx > 0 && File(dir, "phone/lobby.slot").exists(), "slot file written before the lobby POST")
    check(lobby.replenish(3u).minted == 0u, "steady state mints nothing")

    // 재시작 대역: 슬롯으로 복원해도 장부·비밀이 남는다.
    lobby.close()
    lobby = MlsLobby.`import`("owner-phone", lobbyStore.load()!!, BASE, relay, lobbyStore)
    check(lobby.publishedCount() == 3u, "import restores the ledger (${lobby.publishedCount()})")

    // steward 가 room-b 를 만들고 로비 키로 초대한다(봇 `invite` 로비 폴백).
    val stewardStore = FileRoomStore(File(dir, "steward"), "room-b", onMessage = { _, _, _, _ -> })
    val steward = MlsRoom("bot-steward", "room-b", BASE, relay, stewardStore)
    steward.dispatch("create", ByteArray(0))
    val kp = relay.consumeLobby("owner-phone", "bot-steward", "room-b") ?: error("no lobby package")
    val welcome = steward.dispatch("invite", kp)
    val posted = steward.postWelcome(welcome, listOf("owner-phone"))
    val pending = lobby.welcomes()
    check(pending.size == 1 && pending[0].room == "room-b" && pending[0].seq == posted.seq, "welcomes lists room-b at seq ${posted.seq} ($pending)")

    // adopt: 로비 상태로 방 엔진을 만들고 커서를 Welcome 앞에 둔다 → poll 이 join.
    val texts = mutableListOf<String>()
    val phoneStore = FileRoomStore(File(dir, "phone"), "room-b", onMessage = { _, _, _, pt -> texts += String(pt) })
    val phone = MlsRoom.adopt("owner-phone", "room-b", lobby.seedState(), posted.seq - 1, BASE, relay, phoneStore)
    check(phoneStore.load() != null, "adopt persists the pair before any network")
    phone.poll()
    check(phone.syncState().joined, "joined room-b from the lobby Welcome")
    steward.send("welcome aboard".toByteArray())
    phone.poll()
    check(texts == listOf("welcome aboard"), "decrypted with the adopted ratchet ($texts)")
    check(phone.send("thanks".toByteArray()) is SendResult.Sent, "the adopted room sends")
    phone.poll()
    check(lobby.welcomes().isEmpty(), "ack past the Welcome clears the pending listing")
    val rooms = lobby.rooms()
    check(rooms.size == 1 && rooms[0].room == "room-b" && rooms[0].member && !rooms[0].closed, "rooms lists room-b as a membership ($rooms)")
    val after = lobby.replenish(3u)
    check(after.pruned == 1u && after.minted == 1u, "the consumed package is pruned and replaced ($after)")

    // 방 닫기: 멤버 전원 410 room_closed. 없는 방은 false.
    check(steward.closeRoom(), "steward closes room-b")
    val closed = try { phone.poll(); null } catch (e: RoomException) { e }
    check(closed is RoomException.Relay && !closed.transient && closed.reason.contains("room_closed"), "closed room → Relay(room_closed) ($closed)")
    val never = MlsRoom("owner-phone", "room-z", BASE, relay, FileRoomStore(File(dir, "phone"), "room-z", onMessage = { _, _, _, _ -> }))
    check(!never.closeRoom(), "closing an unknown room is false, not an error")

    // 푸시 등록 왕복.
    val token = ByteArray(32) { 0xAB.toByte() }
    lobby.registerPush(token, "com.seoyoon_family.familychat")
    check(relay.pushRows.size == 1 && relay.pushRows[0].token.contentEquals(token) && relay.pushRows[0].topic == "com.seoyoon_family.familychat", "push token registered")
    lobby.unregisterPush()
    check(relay.pushRows.isEmpty(), "push token unregistered")

    // 회수(#389): 서버 풀과 로컬 비밀을 함께 비운다.
    check(lobby.withdraw() == 3uL && relay.lobbyLive("owner-phone") == 0 && lobby.publishedCount() == 0u, "withdraw empties the pool and the ledger")
    check(lobby.replenish(8u).minted == 8u, "all local secrets were freed (8 fresh possible)")
    val slot: MlsLobbySlot = lobbyStore.load()!!
    check(slot.published.size == 8, "slot file follows the ledger (${slot.published.size})")
}

fun main() {
    val tmp = Files.createTempDirectory("hande-jvm-roundtrip").toFile()
    try {
        scenarioRoundtrip(tmp)
        scenarioConflict(tmp)
        scenarioRestart(tmp)
        scenarioTransientAndGap(tmp)
        scenarioLobby(tmp)
    } catch (e: Throwable) {
        failures += "exception: $e"
        e.printStackTrace()
    } finally {
        tmp.deleteRecursively()
    }
    if (failures.isEmpty()) {
        println("ROUNDTRIP PASS (5 scenarios)")
    } else {
        println("ROUNDTRIP FAIL ${failures.size}: $failures")
        exitProcess(1)
    }
}
