// HOST-CONTRACT §2b `LobbyObserver` — 로비 슬롯(서명키 시드 + 로비 key package 비밀 + 게시 장부)의 원자 영속(`FileRoomStore` 와 같은
// tmp → fsync → rename → 디렉터리 fsync). 앱은 `seal`/`open` 에 Keystore 봉인(EncryptedFile 상당)을 끼운다. 한 파일(`lobby.slot`)에
// `u32 n ‖ u32 len ‖ state ‖ (u32 len ‖ package)*n`(big-endian, DataOutputStream) — 상태와 장부는 한 `persist` 에서 온 쌍이라 함께 쓴다.
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.LobbyObserver
import com.seoyoon_family.hande.mls.LobbySlot
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

class FileLobbyStore(
    private val dir: File,
    private val seal: (ByteArray) -> ByteArray = { it },
    private val open: (ByteArray) -> ByteArray = { it },
) : LobbyObserver {
    init { dir.mkdirs() }

    private val slotFile get() = File(dir, "lobby.slot")

    /** 돌아오기 전에는 key package 가 릴레이로 나가지 않는다 — 정말로 디스크에 닿아야 한다. */
    override fun persist(slot: LobbySlot) {
        writeAtomic(slotFile, seal(encode(slot)))
    }

    /** `MlsLobby.import` 에 넣을 슬롯. 없으면 null(새 기기 → `MlsLobby(identity, …)`). */
    fun load(): LobbySlot? = if (slotFile.exists()) decode(open(slotFile.readBytes())) else null

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
        fun encode(slot: LobbySlot): ByteArray {
            val buf = ByteArrayOutputStream()
            DataOutputStream(buf).use { out ->
                out.writeInt(slot.published.size)
                out.writeInt(slot.state.size)
                out.write(slot.state)
                for (kp in slot.published) {
                    out.writeInt(kp.size)
                    out.write(kp)
                }
            }
            return buf.toByteArray()
        }

        fun decode(bytes: ByteArray): LobbySlot {
            DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                val n = input.readInt()
                val state = ByteArray(input.readInt()).also { input.readFully(it) }
                val published = List(n) { ByteArray(input.readInt()).also { input.readFully(it) } }
                return LobbySlot(state, published)
            }
        }
    }
}
