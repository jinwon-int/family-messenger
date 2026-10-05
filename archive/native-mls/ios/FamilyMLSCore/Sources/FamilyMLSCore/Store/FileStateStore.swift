// 계약 3 — 파일 기반 `MlsStateStore`(CONTRACTS.md §3.1, L1). 봇 `persist_state` 와 같은 계약.
//
// 디스크 레이아웃(컨테이너 디렉터리 기준, iOS = App Group `<group>/mls`):
//   <room>.state     헤더 8B magic("FMLSST01") + 8B generation(u64le, 평문) + 봉인 페이로드
//   <room>.state.tmp 저장 중 임시(커밋 시 rename 대상, 열릴 때 잔존분은 회수)
//   <room>.gen       generation 미러 u64le — `generation(room:)` 이 잠금 없이 읽는 값
//   <room>.lock      0바이트 flock 앵커
//
// 트랜잭션: withExclusive 가 flock(LOCK_EX) 을 얻고(50ms 폴링, timeout 초과 = .lockTimeout),
// body 가 성공하면 커밋한다. 커밋 = generation 재확인(.gen 미러 == tx.generation, 아니면
// .generationMismatch) → tmp 쓰기·fsync → rename → 디렉터리 fsync → .gen 갱신. body 가 throw 하면
// 디스크는 불변(tmp 폐기)이고 잠금만 해제된다. 결함 주입 테스트를 위해 커밋 파이프라인 단계에
// debugCrashHook 을 둔다 — 훅이 던지면 잔여 정리 없이 그대로 재던져 실제 크래시 직후 디스크와
// 동일한 상태를 만든다(시뮬레이션 전용, 운영 경로는 훅이 nil).
//
// generation 진실원: 헤더가 1차, .gen 미러는 2차. 열릴 때(rename 후 .gen 갱신 전 크래시 상태)
// 헤더 > 미러면 미러를 헤더로 복구한다(abort-after-rename-before-gen 회복).
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class FileStateStore: MlsStateStore {
    static let magic = Data("FMLSST01".utf8)  // 8 bytes
    static let pollInterval: TimeInterval = 0.05

    public let directory: URL
    private let sealer: FileStateSealing
    private let stateLock = NSLock()  // 진행 중 잠금 테이블 보호
    private var holders: [RoomID: Thread] = [:]
    /// 결함 주입 전용(테스트, @testable): 단계 "before-tmp"|"after-tmp"|"after-rename"|"commit-start".
    /// 던지면 정리 없이 그대로 전파된다(크래시 직후 디스크 상태 재현).
    var debugCrashHook: ((String) throws -> Void)?

    public struct FileCrashSimulated: Error {
        public let phase: String
    }

    public init(directory: URL, sealer: FileStateSealing? = nil) throws {
        if let sealer {
            self.sealer = sealer
        } else {
            self.sealer = try defaultFileSealer()
        }
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyProtection(dir)
        self.directory = dir
    }

    #if canImport(Security)
    /// App Group 컨테이너의 `mls/` 를 연다(운영 진입점).
    public convenience init(appGroup: String, sealer: FileStateSealing? = nil) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw StateStoreError.io("app group container unavailable: \(appGroup)")
        }
        try self.init(directory: container.appendingPathComponent("mls", isDirectory: true), sealer: sealer)
    }
    #endif

    // MARK: - MlsStateStore

    public func withExclusive<T>(room: RoomID, timeout: TimeInterval, _ body: (StateTransaction) throws -> T) throws -> T {
        let name = try Self.sanitizedRoom(room)
        stateLock.lock()
        if holders[room] === Thread.current {
            stateLock.unlock()
            throw StateStoreError.io("re-entrant withExclusive for room \(room)")
        }
        stateLock.unlock()

        let lock = FileLock(path: path(room: name, suffix: "lock"), room: room)
        try lock.acquire(timeout: timeout)
        stateLock.lock()
        holders[room] = Thread.current
        stateLock.unlock()
        defer {
            stateLock.lock()
            holders[room] = nil
            stateLock.unlock()
            lock.release()
        }

        try recoverUnderLock(name: name)
        let baseGeneration = try headerGeneration(name: name)
        let tx = Tx(store: self, room: room, fileName: name, generation: baseGeneration)
        do {
            let result = try body(tx)
            try tx.commitIfPending()
            tx.close()
            return result
        } catch {
            tx.close()
            if error is FileCrashSimulated {
                throw error  // 크래시 시뮬레이션: 디스크를 건드리지 않고 전파
            }
            try? FileManager.default.removeItem(at: tmpURL(name: name))  // 디스크 불변: tmp 폐기
            throw error
        }
    }

    /// 잠금 없는 generation — `.gen` 미러를 읽는다(없으면 0). NSE 감지용.
    public func generation(room: RoomID) throws -> UInt64 {
        let name = try Self.sanitizedRoom(room)
        guard let raw = try FileSys.readAll(path: path(room: name, suffix: "gen")) else { return 0 }
        guard raw.count == 8 else { return 0 }
        return raw.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    // MARK: - 트랜잭션

    final class Tx: StateTransaction {
        let room: RoomID
        let fileName: String
        let generation: UInt64
        private weak var store: FileStateStore?
        private var open = true
        private var pending: Data?

        init(store: FileStateStore, room: RoomID, fileName: String, generation: UInt64) {
            self.store = store
            self.room = room
            self.fileName = fileName
            self.generation = generation
        }

        func load() throws -> Data? {
            guard open else { throw StateStoreError.notInTransaction }
            guard let s = store else { throw StateStoreError.notInTransaction }
            let url = s.stateURL(name: fileName)
            guard let raw = try FileSys.readAll(path: url.path) else { return nil }
            guard raw.count >= 16, raw.prefix(8) == FileStateStore.magic else {
                throw StateStoreError.io("bad state header in \(url.lastPathComponent)")
            }
            let payload = raw.dropFirst(16)
            return try s.sealer.open(Data(payload))
        }

        func save(_ exportState: Data) throws {
            guard open else { throw StateStoreError.notInTransaction }
            pending = exportState
        }

        /// body 성공 후 withExclusive 가 호출한다. 저장이 없으면 no-op.
        func commitIfPending() throws {
            guard open else { throw StateStoreError.notInTransaction }
            guard let data = pending else { return }
            guard let s = store else { throw StateStoreError.notInTransaction }
            defer { pending = nil }

            // 잠금이 있으면 일어나지 않지만 계약 경로: 미러가 트랜잭션 시작 값과 다르면 실패(디스크 불변).
            let diskGen = try s.generation(room: room)
            guard diskGen == generation else {
                throw StateStoreError.generationMismatch(expected: generation, actual: diskGen)
            }
            try s.commit(room: room, name: fileName, generation: generation + 1, plaintext: data)
        }

        func close() { open = false }
    }

    // MARK: - 커밋 파이프라인 (tmp 쓰기 → fsync → rename → dir fsync → .gen 갱신)

    fileprivate func commit(room: RoomID, name: String, generation newGeneration: UInt64, plaintext: Data) throws {
        try debugCrashHook?("commit-start")
        let sealed = try sealer.seal(plaintext)
        var blob = Data()
        blob.reserveCapacity(16 + sealed.count)
        blob.append(Self.magic)
        withUnsafeBytes(of: newGeneration.littleEndian) { blob.append(contentsOf: $0) }
        blob.append(sealed)

        let tmp = tmpURL(name: name)
        try FileSys.writeFileSync(path: tmp.path, bytes: blob)
        Self.applyProtection(tmp)
        try debugCrashHook?("after-tmp")

        try FileSys.rename(tmp.path, stateURL(name: name).path)
        try FileSys.fsyncDirectory(path: directory.path)
        try debugCrashHook?("after-rename")

        try writeMirrorGeneration(name: name, generation: newGeneration)
    }

    func writeMirrorGeneration(name: String, generation: UInt64) throws {
        let tmp = genTmpURL(name: name)
        var bytes = Data(count: 8)
        withUnsafeBytes(of: generation.littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        try FileSys.writeFileSync(path: tmp.path, bytes: bytes)
        Self.applyProtection(tmp)
        try FileSys.rename(tmp.path, genURL(name: name).path)
    }

    /// 잠금 안에서의 크래시 잔존 회수: 고아 tmp 제거, 헤더≠미러면 미러를 헤더로 복구.
    private func recoverUnderLock(name: String) throws {
        if FileManager.default.fileExists(atPath: tmpURL(name: name).path) {
            try FileManager.default.removeItem(at: tmpURL(name: name))
        }
        let header = try headerGeneration(name: name)
        let mirror = try generation(room: name)
        if header != mirror {
            try writeMirrorGeneration(name: name, generation: header)
        }
    }

    // MARK: - 헤더·경로

    private func headerGeneration(name: String) throws -> UInt64 {
        guard let raw = try FileSys.readAll(path: stateURL(name: name).path) else { return 0 }
        guard raw.count >= 16, raw.prefix(8) == Self.magic else { return 0 }
        return raw.dropFirst(8).prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    func stateURL(name: String) -> URL { url(name: name, suffix: "state") }
    fileprivate func tmpURL(name: String) -> URL { url(name: name, suffix: "state.tmp") }
    fileprivate func genURL(name: String) -> URL { url(name: name, suffix: "gen") }
    fileprivate func genTmpURL(name: String) -> URL { url(name: name, suffix: "gen.tmp") }
    fileprivate func path(room: String, suffix: String) -> String { url(name: room, suffix: suffix).path }
    private func url(name: String, suffix: String) -> URL { directory.appendingPathComponent("\(name).\(suffix)") }

    static func sanitizedRoom(_ room: RoomID) throws -> String {
        guard !room.isEmpty, room != ".", room != "..", room.count <= 128 else {
            throw StateStoreError.io("invalid room id")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard room.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StateStoreError.io("room id has characters unsafe for a file name")
        }
        return room
    }

    /// iOS Data Protection: 생성된 파일은 `.completeUntilFirstUserAuthentication`(macOS·Linux 무시).
    static func applyProtection(_ url: URL) {
        #if os(iOS)
        try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        #endif
    }
}

// MARK: - flock 앵커

final class FileLock {
    private let path: String
    private let room: RoomID
    private var fd: Int32 = -1

    init(path: String, room: RoomID) {
        self.path = path
        self.room = room
    }

    func acquire(timeout: TimeInterval) throws {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw StateStoreError.io("open lock failed: \(String(cString: strerror(errno)))")
        }
        self.fd = fd
        let start = Date()
        while true {
            let rc = flock(fd, LOCK_EX | LOCK_NB)
            if rc == 0 { return }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                let message = String(cString: strerror(errno))
                close(fd)
                self.fd = -1
                throw StateStoreError.io("flock failed: \(message)")
            }
            if Date().timeIntervalSince(start) >= timeout {
                close(fd)
                self.fd = -1
                throw StateStoreError.lockTimeout(room)
            }
            Thread.sleep(forTimeInterval: FileStateStore.pollInterval)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)  // fd 닫힘 = 보유 프로세스 죽음과 동일하게 커널이 잠금 해제
        fd = -1
    }

    var fileDescriptor: Int32 { fd }
}

// MARK: - 원시 fd 도우미

enum FileSys {
    static func writeFileSync(path: String, bytes: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw StateStoreError.io("open for write failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var written = 0
        let rc = bytes.withUnsafeBytes { buffer -> Int in
            guard var base = buffer.baseAddress else { return 0 }
            var remaining = buffer.count
            var total = 0
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                base = base.advanced(by: n)
                remaining -= n
                total += n
            }
            written = total
            return total
        }
        guard rc >= 0, written == bytes.count else {
            throw StateStoreError.io("short write (\(written)/\(bytes.count))")
        }
        guard fsync(fd) == 0 else {
            throw StateStoreError.io("fsync failed: \(String(cString: strerror(errno)))")
        }
    }

    static func rename(_ from: String, _ to: String) throws {
        guard renameFile(from, to) == 0 else {
            throw StateStoreError.io("rename failed: \(String(cString: strerror(errno)))")
        }
    }

    @discardableResult
    static func fsyncDirectory(path: String) throws -> Bool {
        #if canImport(Glibc) && !canImport(Darwin)
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        #else
        let fd = open(path, O_RDONLY)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if fsync(fd) != 0 && errno != EINVAL {
            return false  // 일부 파일시스템은 dir fsync 미지원 — 원자성은 rename 이 담보
        }
        return true
    }

    static func readAll(path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StateStoreError.io("read failed: \(path)")
        }
        return data
    }
}

#if canImport(Darwin)
private func renameFile(_ from: String, _ to: String) -> Int32 { Darwin.rename(from, to) }
#else
private func renameFile(_ from: String, _ to: String) -> Int32 { Glibc.rename(from, to) }
#endif
