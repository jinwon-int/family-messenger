// 메시지 보관 스키마(#338 B2 결정): iOS `FamilyMLSCore/Store/MessageRecord.swift` 의 **동결 DDL v1 을 글자 그대로** 쓴다 — 두 플랫폼이 같은
// `messages.db` 모양을 가진다(C 단계 화면·내보내기 규칙을 한 번만 정한다). CI `scripts/check-ddl-sync.sh` 가 두 파일의 DDL 을 비교한다.
// Android 가 실제로 쓰는 표는 `rooms`·`messages` 뿐이다 — `outbox`·`cursors` 는 Rust 코어가 `<room>.sync` 에 가지고 있다(HOST-CONTRACT §1).
// 빈 표로 두는 것이 스키마 공유보다 싸다. 바꾸려면 iOS 와 함께 `schema_version` 을 올리고 마이그레이션을 쓴다.
package com.seoyoon_family.hande.core

object MessageSchema {
    const val VERSION = 1

    // ddl-sync-begin
    val ddl = """
    CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS rooms (
      room TEXT PRIMARY KEY,
      epoch INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 0,
      halted_reason TEXT,
      display_order INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS messages (
      room TEXT NOT NULL,
      seq INTEGER NOT NULL,
      sender_device TEXT NOT NULL,
      client_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      body TEXT NOT NULL,
      attachment BLOB,
      received_at REAL NOT NULL,
      decrypted_by TEXT NOT NULL,
      PRIMARY KEY (room, seq)
    );
    CREATE TABLE IF NOT EXISTS outbox (
      room TEXT NOT NULL,
      client_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      epoch INTEGER NOT NULL,
      bytes BLOB NOT NULL,
      sha256 TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at REAL NOT NULL,
      PRIMARY KEY (room, client_id)
    );
    CREATE TABLE IF NOT EXISTS cursors (room TEXT PRIMARY KEY, seq INTEGER NOT NULL);
    """
    // ddl-sync-end

    // `messages.kind` 값(DDL 밖 — 스키마 버전과 무관). text·attachment·undecryptable 은 iOS `MessageRecord.Kind` 와 같은 말,
    // file-v2 는 웹 이력(`history-store.js`)과 같은 말이다(#499 — body 는 자리 표시, attachment 칸 = 설명자 바이트).
    const val KIND_TEXT = "text"
    const val KIND_ATTACHMENT = "attachment"
    const val KIND_FILE_V2 = "file-v2"
    const val KIND_UNDECRYPTABLE = "undecryptable"

    /** 기기 ID 의 actor(첫 `-` 앞, 없으면 ID 전체) — iOS `MessageRecord.actor(of:)`. */
    fun actor(device: String): String = device.substringBefore('-')

    /** 내 글인가 — 같은 사람(actor)이면 **다른 기기에서 보낸 글도 내 글**(오너 결정 2026-10-20, iOS `isMine` 과 같은 규칙). 빈 기기 ID 는 아무것도 내 글이 아니다. */
    fun isMine(senderDevice: String, myDevice: String?): Boolean =
        !myDevice.isNullOrEmpty() && actor(senderDevice) == actor(myDevice)
}
