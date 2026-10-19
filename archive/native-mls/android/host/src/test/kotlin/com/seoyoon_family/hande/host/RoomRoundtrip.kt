// #366 3b · #338 스파이크 A 2차 — JVM(Linux) 왕복: Kotlin 바인딩(`MlsRoom`) + 호스트 어댑터(`FileRoomStore`) + in-memory 릴레이로
// `ios-ffi/tests/room_host.rs` 와 같은 시나리오를 돈다. 외부 테스트 프레임워크 없이 `main` 하나(JUnit 의존 0). 실패면 exit 1.
// 실행: android/scripts/jvm-roundtrip.sh (KOTLINC · JNA_JAR · BINDINGS_DIR · FFI_LIB_DIR).
package com.seoyoon_family.hande.host

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

fun main() {
    val tmp = Files.createTempDirectory("hande-jvm-roundtrip").toFile()
    try {
        scenarioRoundtrip(tmp)
        scenarioConflict(tmp)
        scenarioRestart(tmp)
        scenarioTransientAndGap(tmp)
    } catch (e: Throwable) {
        failures += "exception: $e"
        e.printStackTrace()
    } finally {
        tmp.deleteRecursively()
    }
    if (failures.isEmpty()) {
        println("ROUNDTRIP PASS (4 scenarios)")
    } else {
        println("ROUNDTRIP FAIL ${failures.size}: $failures")
        exitProcess(1)
    }
}
