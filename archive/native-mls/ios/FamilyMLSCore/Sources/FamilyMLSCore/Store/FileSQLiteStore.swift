// 계약 4 — 메시지 보관 `messages.db`(CONTRACTS.md §4). sqlite3 C API, **의존 0**.
//
// - Apple: SDK 의 `SQLite3` 모듈(자동 링크). Linux(swift-core-linux): 시스템 `libsqlite3` 를
//   dlopen — Package.swift 수정 없이 의존 0 계약을 지키는 유일한 경로다(이미지에 libsqlite3.so.0 이
//   기본 탑재되어 있음을 swift:5.9/6.1 컨테이너에서 실측). 그 외 사용 함수는 전부 C API 그대로다.
// - 스키마는 동결 DDL v1(`MessageSchema.ddl`) 그대로 실행하고 `schema_version` 을 검증한다.
// - `MessageStore`·`OutboxStore`·`CursorStore` 를 **하나의 DB·하나의 연결**에 둔다. 단일 연결이므로
//   모든 접근을 NSLock 으로 직렬화하고 busy_timeout 으로 프로세스 간 경합을 기다린다.
// - outbox.sha256: `OutboxEntry` 에 필드가 없어 L1 이 bytes 의 SHA-256 hex 를 넣는다
//   (Apple = CryptoKit, Linux = 시스템 libcrypto EVP_Digest — 직접 구현한 해시 없음).
import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

public final class FileSQLiteStore: MessageStore, OutboxStore, CursorStore {
    public let path: String
    private let db: SQLiteBridge.DB
    private let lock = NSLock()

    public init(path: String) throws {
        self.path = path
        db = try SQLiteBridge.DB(path: path)
        try db.busyTimeout(Int32(5_000))
        try db.exec(MessageSchema.ddl)
        try verifySchemaVersion()
        FileSQLiteStore.applyProtection(path)
    }

    public convenience init(directory: URL) throws {
        try self.init(path: directory.appendingPathComponent("messages.db").path)
    }

    #if canImport(Security)
    /// App Group 컨테이너의 `messages.db`(운영 진입점; MLS 상태와 같은 컨테이너·같은 보호 등급).
    public convenience init(appGroup: String) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw StateStoreError.io("app group container unavailable: \(appGroup)")
        }
        try self.init(path: container.appendingPathComponent("messages.db").path)
    }
    #endif

    deinit {
        try? db.close()
    }

    // MARK: - schema

    private func verifySchemaVersion() throws {
        let stmt = try db.prepare("SELECT version FROM schema_version LIMIT 1")
        defer { stmt.finalize() }
        if try stmt.step() {
            let version = stmt.columnInt64(0)
            guard version == Int64(MessageSchema.version) else {
                throw StateStoreError.io("messages.db schema version \(version) != \(MessageSchema.version)")
            }
            return
        }
        let insert = try db.prepare("INSERT INTO schema_version (version) VALUES (?)")
        defer { insert.finalize() }
        insert.bind(Int64(MessageSchema.version), at: 1)
        try insert.step()
    }

    // MARK: - MessageStore

    public func insert(_ record: MessageRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        INSERT INTO messages (room, seq, sender_device, client_id, kind, body, attachment, received_at, decrypted_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { stmt.finalize() }
        stmt.bindText(record.room, at: 1)
        stmt.bind(record.seq, at: 2)
        stmt.bindText(record.senderDevice, at: 3)
        stmt.bindText(record.clientId, at: 4)
        stmt.bindText(record.kind.rawValue, at: 5)
        stmt.bindText(record.body, at: 6)
        if let attachment = record.attachment {
            stmt.bind(attachment, at: 7)
        } else {
            stmt.bindNull(at: 7)
        }
        stmt.bind(record.receivedAt.timeIntervalSince1970, at: 8)
        stmt.bindText(record.decryptedBy.rawValue, at: 9)
        try stepOnce(stmt, context: "messages.insert")
    }

    public func messages(room: RoomID, after seq: Int64, limit: Int) throws -> [MessageRecord] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        SELECT room, seq, sender_device, client_id, kind, body, attachment, received_at, decrypted_by
        FROM messages WHERE room = ? AND seq > ? ORDER BY seq ASC LIMIT ?
        """)
        defer { stmt.finalize() }
        stmt.bindText(room, at: 1)
        stmt.bind(seq, at: 2)
        stmt.bind(Int64(limit), at: 3)
        var out: [MessageRecord] = []
        while try stmt.step() {
            out.append(MessageRecord(
                room: stmt.columnText(0),
                seq: stmt.columnInt64(1),
                senderDevice: stmt.columnText(2),
                clientId: stmt.columnText(3),
                kind: MessageRecord.Kind(rawValue: stmt.columnText(4)) ?? .system,
                body: stmt.columnText(5),
                attachment: stmt.columnBlobOpt(6),
                receivedAt: Date(timeIntervalSince1970: stmt.columnDouble(7)),
                decryptedBy: MessageRecord.DecryptedBy(rawValue: stmt.columnText(8)) ?? .app
            ))
        }
        return out
    }

    public func upsertRoom(_ room: RoomRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        INSERT INTO rooms (room, epoch, revision, halted_reason, display_order) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(room) DO UPDATE SET epoch = excluded.epoch, revision = excluded.revision,
          halted_reason = excluded.halted_reason, display_order = excluded.display_order
        """)
        defer { stmt.finalize() }
        stmt.bindText(room.room, at: 1)
        stmt.bind(room.epoch, at: 2)
        stmt.bind(room.revision, at: 3)
        if let halted = room.haltedReason { stmt.bindText(halted, at: 4) } else { stmt.bindNull(at: 4) }
        stmt.bind(Int64(room.displayOrder), at: 5)
        try stepOnce(stmt, context: "rooms.upsert")
    }

    public func rooms() throws -> [RoomRecord] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT room, epoch, revision, halted_reason, display_order FROM rooms ORDER BY display_order, room")
        defer { stmt.finalize() }
        var out: [RoomRecord] = []
        while try stmt.step() {
            out.append(RoomRecord(
                room: stmt.columnText(0),
                epoch: stmt.columnInt64(1),
                revision: stmt.columnInt64(2),
                haltedReason: stmt.columnTextOpt(3),
                displayOrder: Int(stmt.columnInt64(4))
            ))
        }
        return out
    }

    public func setHalted(room: RoomID, reason: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("UPDATE rooms SET halted_reason = ? WHERE room = ?")
        defer { stmt.finalize() }
        if let reason { stmt.bindText(reason, at: 1) } else { stmt.bindNull(at: 1) }
        stmt.bindText(room, at: 2)
        try stepOnce(stmt, context: "rooms.setHalted")
    }

    // MARK: - OutboxStore

    public func enqueue(_ entry: OutboxEntry) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        INSERT INTO outbox (room, client_id, kind, epoch, bytes, sha256, status, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { stmt.finalize() }
        stmt.bindText(entry.room, at: 1)
        stmt.bindText(entry.clientId, at: 2)
        stmt.bindText(entry.kind, at: 3)
        stmt.bind(entry.epoch, at: 4)
        stmt.bind(entry.bytes, at: 5)
        stmt.bindText(try Sha256Hex.of(entry.bytes), at: 6)
        stmt.bindText(entry.status.rawValue, at: 7)
        stmt.bind(entry.createdAt.timeIntervalSince1970, at: 8)
        try stepOnce(stmt, context: "outbox.enqueue")
    }

    public func pending(room: RoomID) throws -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        SELECT room, client_id, kind, epoch, bytes, status, created_at
        FROM outbox WHERE room = ? AND status = 'pending' ORDER BY created_at, rowid
        """)
        defer { stmt.finalize() }
        stmt.bindText(room, at: 1)
        var out: [OutboxEntry] = []
        while try stmt.step() {
            out.append(OutboxEntry(
                room: stmt.columnText(0),
                clientId: stmt.columnText(1),
                kind: stmt.columnText(2),
                epoch: stmt.columnInt64(3),
                bytes: stmt.columnBlob(4),
                status: OutboxEntry.Status(rawValue: stmt.columnText(5)) ?? .pending,
                createdAt: Date(timeIntervalSince1970: stmt.columnDouble(6))
            ))
        }
        return out
    }

    public func mark(room: RoomID, clientId: String, status: OutboxEntry.Status) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("UPDATE outbox SET status = ? WHERE room = ? AND client_id = ?")
        defer { stmt.finalize() }
        stmt.bindText(status.rawValue, at: 1)
        stmt.bindText(room, at: 2)
        stmt.bindText(clientId, at: 3)
        try stepOnce(stmt, context: "outbox.mark")
    }

    /// InMemory 참조 구현과 동일한 규율: pending 은 절대 지우지 않고, 완료(entry.status != .pending)
    /// 항목 중 최근 `keepingLast` 개만 남긴다(순서 = created_at, rowid).
    public func prune(room: RoomID, keepingLast: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT rowid, status FROM outbox WHERE room = ? ORDER BY created_at, rowid")
        stmt.bindText(room, at: 1)
        var doneRowIDs: [Int64] = []
        while try stmt.step() {
            if stmt.columnText(1) != OutboxEntry.Status.pending.rawValue {
                doneRowIDs.append(stmt.columnInt64(0))
            }
        }
        stmt.finalize()
        let remove = doneRowIDs.dropLast(max(0, keepingLast))
        guard !remove.isEmpty else { return }
        let del = try db.prepare("DELETE FROM outbox WHERE room = ? AND rowid = ?")
        defer { del.finalize() }
        for rowID in remove {
            del.reset()
            del.bindText(room, at: 1)
            del.bind(rowID, at: 2)
            try stepOnce(del, context: "outbox.prune")
        }
    }

    // MARK: - CursorStore

    public func cursor(room: RoomID) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("SELECT seq FROM cursors WHERE room = ?")
        defer { stmt.finalize() }
        stmt.bindText(room, at: 1)
        if try stmt.step() { return stmt.columnInt64(0) }
        return 0
    }

    public func setCursor(room: RoomID, seq: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare("""
        INSERT INTO cursors (room, seq) VALUES (?, ?)
        ON CONFLICT(room) DO UPDATE SET seq = excluded.seq
        """)
        defer { stmt.finalize() }
        stmt.bindText(room, at: 1)
        stmt.bind(seq, at: 2)
        try stepOnce(stmt, context: "cursors.setCursor")
    }

    // MARK: - 내부

    /// 테스트 전용(@testable): 파라미터 없는 SQL 첫 행 첫 열(Int64). 스키마·열 검증용.
    func debugScalar(_ sql: String) throws -> Int64? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        if try stmt.step() { return stmt.columnInt64(0) }
        return nil
    }

    private func stepOnce(_ stmt: SQLiteBridge.Stmt, context: String) throws {
        let hasRow = try stmt.step()
        guard !hasRow else {
            throw StateStoreError.io("\(context): unexpected row result")
        }
    }

    /// iOS Data Protection(파일 보호). 롤백 저널·WAL 부수 파일도 함께.
    static func applyProtection(_ path: String) {
        #if os(iOS)
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                FileStateStore.applyProtection(url)
            }
        }
        #endif
    }
}

// MARK: - sha256 hex (직접 구현 없음: CryptoKit 또는 시스템 libcrypto)

enum Sha256Hex {
    static func of(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        guard let digest = LibCrypto.sha256(data) else {
            throw StateStoreError.io("system libcrypto unavailable for sha256 (dlopen libcrypto.so.3)")
        }
        return digest.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

#if !canImport(CryptoKit)
/// Linux: 시스템 libcrypto 의 EVP_Digest(EVP_sha256) 한 번 호출. dlsym 만 사용(링크 플래그 불필요).
enum LibCrypto {
    private static let loaded: Bool = {
        for name in ["libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"] {
            if dlopen(name, RTLD_NOW | RTLD_LOCAL) != nil { return true }
        }
        return false
    }()

    static func sha256(_ data: Data) -> [UInt8]? {
        guard loaded else { return nil }
        guard let sha256Fn: (@convention(c) () -> UnsafeMutableRawPointer?) = sym("EVP_sha256"),
              let digestFn: (@convention(c) (UnsafeRawPointer?, Int, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt32>?, UnsafeRawPointer?, UnsafeRawPointer?) -> Int32) = sym("EVP_Digest"),
              let md = sha256Fn() else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        var outLen: UInt32 = 0
        let rc = data.withUnsafeBytes { buffer -> Int32 in
            digestFn(buffer.baseAddress, buffer.count, &out, &outLen, md, nil)
        }
        guard rc == 1, outLen == 32 else { return nil }
        return out
    }

    private static func sym<T>(_ symbol: String) -> T? {
        for soname in ["libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"] {
            if let handle = dlopen(soname, RTLD_NOW | RTLD_LOCAL), let p = dlsym(handle, symbol) {
                return unsafeBitCast(p, to: T.self)
            }
        }
        return nil
    }
}
#endif

// MARK: - sqlite3 브리지

/// sqlite3_column_text(UnsafePointer<UInt8>) 를 Swift String 으로.
private func utf8String(_ pointer: UnsafePointer<UInt8>) -> String {
    String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
}

enum SQLiteBridge {
    #if canImport(SQLite3)
    static let kSQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    #endif

    final class DB {
        #if canImport(SQLite3)
        private let handle: OpaquePointer
        #else
        private let handle: UnsafeMutableRawPointer
        #endif

        init(path: String) throws {
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            #if canImport(SQLite3)
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(path, &db, flags, nil)
            guard rc == SQLITE_OK, let opened = db else {
                sqlite3_close_v2(db)
                throw StateStoreError.io("sqlite open failed (rc \(rc)): \(path)")
            }
            handle = opened
            #else
            guard let openFn: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32, UnsafePointer<CChar>?) -> Int32) = SQLiteShim.fn("sqlite3_open_v2") else {
                throw StateStoreError.io("libsqlite3 not found (dlopen libsqlite3.so.0)")
            }
            var raw: UnsafeMutableRawPointer?
            let rc = openFn(path, &raw, flags, nil)
            guard rc == SQLITE_OK, let opened = raw else {
                throw StateStoreError.io("sqlite open failed (rc \(rc)): \(path)")
            }
            handle = opened
            #endif
        }

        func busyTimeout(_ ms: Int32) throws {
            #if canImport(SQLite3)
            sqlite3_busy_timeout(handle, ms)
            #else
            guard let fn: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32) = SQLiteShim.fn("sqlite3_busy_timeout") else {
                throw StateStoreError.io("sqlite3_busy_timeout missing")
            }
            _ = fn(handle, ms)
            #endif
        }

        /// 여러 문장 DDL 용.
        func exec(_ sql: String) throws {
            #if canImport(SQLite3)
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let message = errmsg.map { String(cString: $0) } ?? "rc \(rc)"
                sqlite3_free(errmsg)
                throw StateStoreError.io("sqlite exec failed: \(message)")
            }
            #else
            guard let fn: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32) = SQLiteShim.fn("sqlite3_exec") else {
                throw StateStoreError.io("sqlite3_exec missing")
            }
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = fn(handle, sql, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let message = errmsg.map { String(cString: $0) } ?? "rc \(rc)"
                if let freeFn: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = SQLiteShim.fn("sqlite3_free"), let err = errmsg {
                    freeFn(UnsafeMutableRawPointer(err))
                }
                throw StateStoreError.io("sqlite exec failed: \(message)")
            }
            #endif
        }

        func prepare(_ sql: String) throws -> Stmt {
            #if canImport(SQLite3)
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let prepared = stmt else {
                throw StateStoreError.io("sqlite prepare failed: \(errorMessage())")
            }
            return Stmt(prepared)
            #else
            guard let fn: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32) = SQLiteShim.fn("sqlite3_prepare_v2") else {
                throw StateStoreError.io("sqlite3_prepare_v2 missing")
            }
            var raw: UnsafeMutableRawPointer?
            let rc = fn(handle, sql, -1, &raw, nil)
            guard rc == SQLITE_OK, let prepared = raw else {
                throw StateStoreError.io("sqlite prepare failed: \(errorMessage())")
            }
            return Stmt(prepared)
            #endif
        }

        func errorMessage() -> String {
            #if canImport(SQLite3)
            return String(cString: sqlite3_errmsg(handle))
            #else
            guard let fn: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?) = SQLiteShim.fn("sqlite3_errmsg"), let message = fn(handle) else {
                return "unknown sqlite error"
            }
            return String(cString: message)
            #endif
        }

        func close() throws {
            #if canImport(SQLite3)
            sqlite3_close_v2(handle)
            #else
            if let fn: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = SQLiteShim.fn("sqlite3_close_v2") {
                fn(handle)
            }
            #endif
        }
    }

    final class Stmt {
        #if canImport(SQLite3)
        private let handle: OpaquePointer
        #else
        private let handle: UnsafeMutableRawPointer
        #endif
        private var finalized = false

        #if canImport(SQLite3)
        init(_ handle: OpaquePointer) { self.handle = handle }
        #else
        init(_ handle: UnsafeMutableRawPointer) { self.handle = handle }
        #endif

        deinit { finalize() }

        func finalize() {
            guard !finalized else { return }
            finalized = true
            #if canImport(SQLite3)
            sqlite3_finalize(handle)
            #else
            if let fn: (@convention(c) (UnsafeMutableRawPointer?) -> Int32) = SQLiteShim.fn("sqlite3_finalize") {
                _ = fn(handle)
            }
            #endif
        }

        func reset() {
            #if canImport(SQLite3)
            sqlite3_reset(handle)
            #else
            if let fn: (@convention(c) (UnsafeMutableRawPointer?) -> Int32) = SQLiteShim.fn("sqlite3_reset") {
                _ = fn(handle)
            }
            #endif
        }

        /// true = SQLITE_ROW, false = SQLITE_DONE.
        func step() throws -> Bool {
            #if canImport(SQLite3)
            let rc = sqlite3_step(handle)
            #else
            guard let fn: (@convention(c) (UnsafeMutableRawPointer?) -> Int32) = SQLiteShim.fn("sqlite3_step") else {
                throw StateStoreError.io("sqlite3_step missing")
            }
            let rc = fn(handle)
            #endif
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default:
                throw StateStoreError.io("sqlite step failed rc \(rc)")
            }
        }

        func bind(_ value: Int64, at index: Int32) {
            #if canImport(SQLite3)
            sqlite3_bind_int64(handle, index, value)
            #else
            bindShim("sqlite3_bind_int64") { fn in
                let typed = unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32, Int64) -> Int32).self)
                _ = typed(self.handle, index, value)
            }
            #endif
        }

        func bind(_ value: Double, at index: Int32) {
            #if canImport(SQLite3)
            sqlite3_bind_double(handle, index, value)
            #else
            bindShim("sqlite3_bind_double") { fn in
                let typed = unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32, Double) -> Int32).self)
                _ = typed(self.handle, index, value)
            }
            #endif
        }

        func bindText(_ value: String, at index: Int32) {
            let bytes = Array(value.utf8CString)  // NUL 종료 포함
            #if canImport(SQLite3)
            bytes.withUnsafeBufferPointer { buffer in
                _ = sqlite3_bind_text(handle, index, buffer.baseAddress, Int32(bytes.count - 1), kSQLITE_TRANSIENT)
            }
            #else
            bindShim("sqlite3_bind_text") { fn in
                let typed = unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32, UnsafeRawPointer?) -> Int32).self)
                bytes.withUnsafeBufferPointer { buffer in
                    _ = typed(self.handle, index, buffer.baseAddress, Int32(bytes.count - 1), UnsafeRawPointer(bitPattern: UInt(bitPattern: -1)))
                }
            }
            #endif
        }

        func bind(_ value: Data, at index: Int32) {
            #if canImport(SQLite3)
            if value.isEmpty {
                var sentinel: UInt8 = 0
                withUnsafeBytes(of: &sentinel) { buffer in
                    // NULL 포인터가 아니라 길이 0 블롭으로 확정 바인드(빈 첨부 보존).
                    _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, 0, SQLiteBridge.kSQLITE_TRANSIENT)
                }
                return
            }
            value.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), SQLiteBridge.kSQLITE_TRANSIENT)
            }
            #else
            if value.isEmpty {
                var sentinel: UInt8 = 0
                withUnsafeBytes(of: &sentinel) { buffer in
                    bindShim("sqlite3_bind_blob") { fn in
                        let typed = unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?) -> Int32).self)
                        _ = typed(self.handle, index, buffer.baseAddress, 0, UnsafeRawPointer(bitPattern: UInt(bitPattern: -1)))
                    }
                }
                return
            }
            bindShim("sqlite3_bind_blob") { fn in
                let typed = unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?) -> Int32).self)
                value.withUnsafeBytes { buffer in
                    _ = typed(self.handle, index, buffer.baseAddress, Int32(buffer.count), UnsafeRawPointer(bitPattern: UInt(bitPattern: -1)))
                }
            }
            #endif
        }

        func bindNull(at index: Int32) {
            #if canImport(SQLite3)
            sqlite3_bind_null(handle, index)
            #else
            bindShim("sqlite3_bind_null") { fn in
                let typed = unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self)
                _ = typed(self.handle, index)
            }
            #endif
        }

        func columnInt64(_ index: Int32) -> Int64 {
            #if canImport(SQLite3)
            sqlite3_column_int64(handle, index)
            #else
            columnShim("sqlite3_column_int64") { fn in
                unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int64).self)(self.handle, index)
            } ?? 0
            #endif
        }

        func columnDouble(_ index: Int32) -> Double {
            #if canImport(SQLite3)
            sqlite3_column_double(handle, index)
            #else
            columnShim("sqlite3_column_double") { fn in
                unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Double).self)(self.handle, index)
            } ?? 0
            #endif
        }

        func columnText(_ index: Int32) -> String {
            columnTextOpt(index) ?? ""
        }

        func columnTextOpt(_ index: Int32) -> String? {
            #if canImport(SQLite3)
            guard let cString = sqlite3_column_text(handle, index) else { return nil }
            return utf8String(cString)
            #else
            return columnShim("sqlite3_column_text") { fn in
                unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafePointer<UInt8>?).self)(self.handle, index)
            }.map(utf8String)
            #endif
        }

        func columnBlob(_ index: Int32) -> Data {
            columnBlobOpt(index) ?? Data()
        }

        func columnBlobOpt(_ index: Int32) -> Data? {
            #if canImport(SQLite3)
            // 0길이 blob: sqlite3_column_blob 은 NULL 을 돌려주므로 column_type 으로 SQL NULL 과 구분한다.
            let count = Int(sqlite3_column_bytes(handle, index))
            guard count > 0 else {
                return sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : Data()
            }
            guard let pointer = sqlite3_column_blob(handle, index) else { return nil }
            return Data(bytes: pointer, count: count)
            #else
            let pointer: UnsafeRawPointer? = columnShim("sqlite3_column_blob") { fn in
                unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafeRawPointer?).self)(self.handle, index)
            }
            let byteCount = Int(columnShim("sqlite3_column_bytes") { fn in
                unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self)(self.handle, index)
            } ?? 0)
            guard byteCount > 0 else {
                let type = columnShim("sqlite3_column_type") { fn in
                    unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self)(self.handle, index)
                } ?? 0
                return type == SQLITE_NULL ? nil : Data()
            }
            guard let pointer else { return nil }
            return Data(bytes: pointer, count: byteCount)
            #endif
        }

        #if !canImport(SQLite3)
        private func bindShim(_ name: String, _ body: (UnsafeMutableRawPointer) -> Void) {
            guard let fn = SQLiteShim.raw(name) else {
                preconditionFailure("sqlite3 symbol missing: \(name)")
            }
            body(fn)
        }

        private func columnShim<T>(_ name: String, _ body: (UnsafeMutableRawPointer) -> T?) -> T? {
            guard let fn = SQLiteShim.raw(name) else { return nil }
            return body(fn)
        }
        #endif
    }
}

#if !canImport(SQLite3)
/// Linux: 시스템 libsqlite3 를 dlopen 해서 쓰는 최소 심볼 테이블(Package 수정 없이 의존 0).
enum SQLiteShim {
    static let handle: UnsafeMutableRawPointer? = {
        for name in ["libsqlite3.so.0", "libsqlite3.so"] {
            if let handle = dlopen(name, RTLD_NOW | RTLD_LOCAL) { return handle }
        }
        return nil
    }()

    static func raw(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    static func fn<T>(_ name: String) -> T? {
        guard let pointer = raw(name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

let SQLITE_OK: Int32 = 0
let SQLITE_ROW: Int32 = 100
let SQLITE_DONE: Int32 = 101
let SQLITE_OPEN_READWRITE: Int32 = 0x00000002
let SQLITE_OPEN_CREATE: Int32 = 0x00000004
let SQLITE_OPEN_FULLMUTEX: Int32 = 0x00010000
let SQLITE_NULL: Int32 = 5
#endif
