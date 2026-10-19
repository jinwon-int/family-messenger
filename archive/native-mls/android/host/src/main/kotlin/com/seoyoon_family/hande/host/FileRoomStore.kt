// HOST-CONTRACT §3·§4 `RoomObserver` — 방 상태·동기화 위치의 원자 영속(tmp → fsync → rename → 디렉터리 fsync, 봇 `persist_state` 와 같은 규칙),
// 정지 마커, 이벤트·메시지 싱크. Android 앱은 `seal`/`open` 에 Keystore 키 봉인(EncryptedFile 상당)을 끼운다 — 파일 규칙은 그대로.
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.RoomEvent
import com.seoyoon_family.hande.mls.RoomObserver
import com.seoyoon_family.hande.mls.RoomSyncState
import java.io.File
import java.io.FileOutputStream
import java.io.StringReader
import java.io.StringWriter
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.Properties

class FileRoomStore(
    private val dir: File,
    private val room: String,
    private val seal: (ByteArray) -> ByteArray = { it },
    private val open: (ByteArray) -> ByteArray = { it },
    private val onEvent: (RoomEvent) -> Unit = {},
    private val onMessage: (seq: Long, sender: String, clientId: String, plaintext: ByteArray) -> Unit,
) : RoomObserver {
    init { dir.mkdirs() }

    private val stateFile get() = File(dir, "$room.state")
    private val syncFile get() = File(dir, "$room.sync")
    private val haltFile get() = File(dir, "$room.halted")

    /** 그룹 상태와 동기화 위치는 한 호출에서 온 쌍 — 둘 다 원자적으로. 돌아오기 전에는 바이트가 나가지 않는다(B-H2). */
    override fun persist(state: ByteArray, sync: RoomSyncState) {
        writeAtomic(stateFile, seal(state))
        writeAtomic(syncFile, encode(sync))
    }

    override fun event(event: RoomEvent) = onEvent(event)

    override fun application(seq: Long, sender: String, clientId: String, plaintext: ByteArray) =
        onMessage(seq, sender, clientId, plaintext)

    /** 정지는 최종: 마커가 있으면 재시작 뒤에도 `sync.halted` 로 복원된다(`load`). */
    override fun halted(reason: String, detail: String, sync: RoomSyncState) {
        writeAtomic(syncFile, encode(sync))
        writeAtomic(haltFile, "$reason\n$detail\n".toByteArray(Charsets.UTF_8))
    }

    /** `MlsRoom.import` 에 넣을 쌍. 없으면 null(새 방). 봉인 해제 실패는 throw(호스트 버그 또는 키 소실). */
    fun load(): Pair<ByteArray, RoomSyncState>? {
        if (!stateFile.exists() || !syncFile.exists()) return null
        return Pair(open(stateFile.readBytes()), decode(syncFile.readBytes()))
    }

    fun isHalted(): Boolean = haltFile.exists()
    fun haltReason(): String? = if (haltFile.exists()) haltFile.readText(Charsets.UTF_8).lineSequence().firstOrNull() else null

    private fun writeAtomic(target: File, bytes: ByteArray) {
        val tmp = File(dir, target.name + ".tmp")
        FileOutputStream(tmp).use { out ->
            out.write(bytes)
            out.fd.sync()
        }
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        try {
            FileChannel.open(dir.toPath(), StandardOpenOption.READ).use { it.force(true) }
        } catch (_: Exception) {
            // 일부 파일 시스템은 디렉터리 fsync 를 지원하지 않는다 — rename 자체는 원자적.
        }
    }

    companion object {
        fun encode(s: RoomSyncState): ByteArray {
            val p = Properties()
            p["room"] = s.room
            p["cursor"] = s.cursor.toString()
            p["epoch"] = s.epoch.toString()
            p["joined"] = s.joined.toString()
            p["joinable"] = s.joinable.toString()
            p["acked"] = s.acked.toString()
            p["ackSent"] = s.ackSent.toString()
            p["ackDisabled"] = s.ackDisabled.toString()
            p["halted"] = s.halted.toString()
            p["sends"] = s.sends.toString()
            val w = StringWriter()
            p.store(w, "hande room sync")
            return w.toString().toByteArray(Charsets.UTF_8)
        }

        fun decode(bytes: ByteArray): RoomSyncState {
            val p = Properties()
            p.load(StringReader(String(bytes, Charsets.UTF_8)))
            fun s(k: String) = p.getProperty(k) ?: throw IllegalStateException("sync file missing $k")
            return RoomSyncState(
                room = s("room"), cursor = s("cursor").toLong(), epoch = s("epoch").toLong(),
                joined = s("joined").toBoolean(), joinable = s("joinable").toBoolean(),
                acked = s("acked").toLong(), ackSent = s("ackSent").toLong(), ackDisabled = s("ackDisabled").toBoolean(),
                halted = s("halted").toBoolean(), sends = s("sends").toULong(),
            )
        }
    }
}
