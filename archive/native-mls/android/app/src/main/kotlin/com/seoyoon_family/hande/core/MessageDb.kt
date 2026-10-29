// 메시지 보관 `messages.db`(#338 B2 — 정식 저장소). 프레임워크 `SQLiteOpenHelper`, **의존 0**(Room·rusqlite 채택 안 함 — android/README 「B2 결정」).
// 스키마는 iOS 와 같은 동결 DDL v1(`MessageSchema.ddl`). MLS 는 같은 메시지를 다시 복호화할 수 없으므로 복호화한 쪽(앱 프로세스 1개)이 여기에 쓰고,
// 화면은 여기서만 읽는다. 보호: 앱 전용 디렉터리(Android 파일 기반 암호화) + `allowBackup=false` — iOS `messages.db` 의 Data Protection 과 같은 수준
// (B1 임시 JSONL 은 Keystore 로 봉인했지만, 살아 있는 SQLite 파일은 통째로 봉인할 수 없다 → #338 §2 "SQLCipher 불요 — 파일 레벨 암호화").
// 단일 연결·단일 작성자: 모든 접근을 `lock` 으로 직렬화한다(HOST-CONTRACT §1).
package com.seoyoon_family.hande.core

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import org.json.JSONObject
import java.io.File

data class MessageUi(val seq: Long, val sender: String, val text: String, val mine: Boolean, val attachment: Boolean = false)

class MessageDb(context: Context, private val myDevice: () -> String?) : SQLiteOpenHelper(context, DB_NAME, null, MessageSchema.VERSION) {
    private val lock = Any()
    private val appContext: Context = context.applicationContext

    /** 이 기기 지우기(#584): 연결을 닫고 `messages.db`(저널 포함)를 지운다. 다음 접근 때 `SQLiteOpenHelper` 가 빈 파일을 새로 만든다. */
    fun wipe(): Boolean = synchronized(lock) {
        close()
        appContext.deleteDatabase(DB_NAME)
    }

    override fun onCreate(db: SQLiteDatabase) {
        createSchema(db)
        db.execSQL("INSERT INTO schema_version (version) VALUES (?)", arrayOf(MessageSchema.VERSION))
    }

    /** 동결 v1 — 올릴 일이 생기면 iOS 와 함께 마이그레이션을 쓴다. 지금은 알 수 없는 버전이면 실패시킨다(조용한 손상 금지). */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        error("messages.db schema $oldVersion → $newVersion: no migration (frozen v1)")
    }

    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        error("messages.db schema downgrade $oldVersion → $newVersion refused")
    }

    override fun onOpen(db: SQLiteDatabase) {
        createSchema(db) // IF NOT EXISTS — iOS 와 같은 규칙: 열 때마다 DDL 을 실행하고 version 을 검증한다.
        val v = db.rawQuery("SELECT version FROM schema_version LIMIT 1", null).use { if (it.moveToFirst()) it.getInt(0) else null }
        when (v) {
            null -> db.execSQL("INSERT INTO schema_version (version) VALUES (?)", arrayOf(MessageSchema.VERSION))
            MessageSchema.VERSION -> {}
            else -> error("messages.db schema_version $v != ${MessageSchema.VERSION}")
        }
    }

    private fun createSchema(db: SQLiteDatabase) {
        for (stmt in MessageSchema.ddl.split(';')) {
            val sql = stmt.trim()
            if (sql.isNotEmpty()) db.execSQL(sql)
        }
    }

    // ---- rooms ----

    fun upsertRoom(room: String) = synchronized(lock) {
        writableDatabase.execSQL("INSERT OR IGNORE INTO rooms (room) VALUES (?)", arrayOf(room))
    }

    fun setHalted(room: String, reason: String?) = synchronized(lock) {
        writableDatabase.execSQL("UPDATE rooms SET halted_reason = ? WHERE room = ?", arrayOf(reason, room))
    }

    // ---- messages ----

    /** 같은 (room, seq) 는 한 번만 — 재시작·재동기화로 같은 글이 다시 와도 중복되지 않는다(iOS `insert` 의 PRIMARY KEY 규칙). */
    fun insert(room: String, seq: Long, senderDevice: String, clientId: String, kind: String, body: String, attachment: ByteArray?, receivedAt: Double = now()) =
        synchronized(lock) {
            val v = ContentValues().apply {
                put("room", room); put("seq", seq); put("sender_device", senderDevice); put("client_id", clientId); put("kind", kind)
                put("body", body); put("attachment", attachment); put("received_at", receivedAt); put("decrypted_by", "app")
            }
            writableDatabase.insertWithOnConflict("messages", null, v, SQLiteDatabase.CONFLICT_IGNORE)
            Unit
        }

    /** 방의 글 전부(seq 순). C 단계에서 페이지 단위로 바꾼다. */
    fun messages(room: String): List<MessageUi> = synchronized(lock) {
        val me = myDevice()
        readableDatabase.rawQuery("SELECT seq, sender_device, kind, body FROM messages WHERE room = ? ORDER BY seq", arrayOf(room)).use { c ->
            val out = ArrayList<MessageUi>(c.count)
            while (c.moveToNext()) {
                val sender = c.getString(1)
                val attachment = c.getString(2).let { it == KIND_ATTACHMENT || it == MessageSchema.KIND_FILE_V2 }
                out += MessageUi(c.getLong(0), sender, c.getString(3), mine = MessageSchema.isMine(sender, me), attachment = attachment)
            }
            out
        }
    }

    /**
     * B1 임시 저장(`<room>.messages`, Keystore 봉인 JSONL: seq · sender · text · mine · attachment)을 한 번 옮기고 파일을 지운다.
     * 시각은 알 수 없으므로 옮긴 순간을 둔다(iOS 의 "그 전에 저장된 행" 과 같은 뜻). 봉인 해제 실패는 건너뛰고 로그만 남긴다(키 소실 = 설계대로 복구 불가).
     */
    fun migrateLegacy(dir: File, open: (ByteArray) -> ByteArray) {
        val files = dir.listFiles { _, n -> n.endsWith(LEGACY_SUFFIX) }.orEmpty()
        for (f in files) {
            val room = f.name.removeSuffix(LEGACY_SUFFIX)
            val opened = runCatching { String(open(f.readBytes()), Charsets.UTF_8) }
            val text = opened.getOrNull()
            if (text == null) {
                Log.w(TAG, "legacy $room: cannot open (${opened.exceptionOrNull()?.javaClass?.simpleName}) — skipped")
                continue
            }
            var n = 0
            synchronized(lock) {
                val db = writableDatabase
                db.beginTransaction()
                try {
                    db.execSQL("INSERT OR IGNORE INTO rooms (room) VALUES (?)", arrayOf(room))
                    for (line in text.lineSequence()) {
                        if (line.isBlank()) continue
                        val o = runCatching { JSONObject(line) }.getOrNull() ?: continue
                        val attachment = o.optBoolean("attachment", false)
                        val v = ContentValues().apply {
                            put("room", room); put("seq", o.getLong("seq")); put("sender_device", o.getString("sender"))
                            put("client_id", ""); put("kind", if (attachment) KIND_ATTACHMENT else KIND_TEXT); put("body", o.getString("text"))
                            put("received_at", now()); put("decrypted_by", "app")
                        }
                        if (db.insertWithOnConflict("messages", null, v, SQLiteDatabase.CONFLICT_IGNORE) != -1L) n += 1
                    }
                    db.setTransactionSuccessful()
                } finally {
                    db.endTransaction()
                }
            }
            f.delete()
            File(dir, f.name + ".tmp").delete()
            Log.i(TAG, "legacy $room: $n rows → messages.db, file removed")
        }
    }

    companion object {
        const val DB_NAME = "messages.db"
        private const val TAG = "hande.db"
        const val KIND_TEXT = MessageSchema.KIND_TEXT
        const val KIND_ATTACHMENT = MessageSchema.KIND_ATTACHMENT
        private const val LEGACY_SUFFIX = ".messages"
        private fun now() = System.currentTimeMillis() / 1000.0
    }
}
