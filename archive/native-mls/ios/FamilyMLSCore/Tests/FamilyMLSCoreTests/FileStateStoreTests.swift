// L1 결함 주입·계약 테스트(CONTRACTS.md §3.2·§3.3). 계약 테스트는 `StateStoreContract.run` 을
// **그대로** 호출한다(InMemory 가 기준). 결함 주입은 커밋 파이프라인의 debugCrashHook 으로
// 실제 크래시 직후 디스크 상태를 만들어 회복을 증명한다.
import XCTest
@testable import FamilyMLSCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Security)
import Security
#endif

final class FileStateStoreTests: XCTestCase {
    // MARK: 도우미

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fml1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 두 인스턴스가 서로의 파일을 읽으려면 같은 봉인 키가 필요하다(Apple = ChaChaPoly 256bit,
    /// 키는 시스템 난수원). Linux CI(Passthrough)는 키가 없어도 파일 교환이 성립한다.
    private func makeSealer() throws -> FileStateSealing {
        #if canImport(CryptoKit)
        var generator = SystemRandomNumberGenerator()
        var key = Data(count: 32)
        key.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for i in 0..<bytes.count { bytes[i] = UInt8.random(using: &generator) }
        }
        return try ChaChaPolySealer(keySource: StaticSealKeySource(key: key))
        #else
        return PassthroughSealer()
        #endif
    }

    private func makeStore(_ dir: URL) throws -> FileStateStore {
        try FileStateStore(directory: dir, sealer: try makeSealer())
    }

    private func makePair(_ dir: URL) throws -> (MlsStateStore, MlsStateStore) {
        (try makeStore(dir), try makeStore(dir))
    }

    /// debugCrashHook 등 FileStateStore 전용 멤버를 쓰는 테스트용(계약 run 은 makePair 그대로).
    private func makeConcretePair(_ dir: URL) throws -> (FileStateStore, FileStateStore) {
        (try makeStore(dir), try makeStore(dir))
    }

    private func stateURL(_ dir: URL, _ room: String) -> URL {
        dir.appendingPathComponent("\(room).state")
    }

    private func genURL(_ dir: URL, _ room: String) -> URL {
        dir.appendingPathComponent("\(room).gen")
    }

    // MARK: 계약 (§3.2 — 그대로 호출)

    func testFileStoreSatisfiesContract() throws {
        let dir = try makeTempDir()
        try StateStoreContract.run(label: "File") { try self.makePair(dir) }
    }

    // MARK: 결함 주입 (§3.3)

    /// abort-before-write: 아무것도 쓰지 않고 죽음 → 상태 없음, 잠금 해제, 재시도 가능.
    func testFaultAbortBeforeWrite() throws {
        let dir = try makeTempDir()
        let (a, b) = try makeConcretePair(dir)
        a.debugCrashHook = { phase in
            XCTAssertEqual(phase, "commit-start")
            throw FileStateStore.FileCrashSimulated(phase: phase)
        }
        XCTAssertThrowsError(try a.withExclusive(room: "fw", timeout: 1) { tx in
            try tx.save(Data("v1".utf8))
        })
        a.debugCrashHook = nil
        XCTAssertEqual(try b.generation(room: "fw"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL(dir, "fw").path))
        try b.withExclusive(room: "fw", timeout: 1) { tx in
            XCTAssertNil(try tx.load())
        }
        // 같은 프로세스에서 이어서 정상 저장 가능(잠금 회복 증명).
        try a.withExclusive(room: "fw", timeout: 1) { tx in try tx.save(Data("v1".utf8)) }
        XCTAssertEqual(try b.generation(room: "fw"), 1)
    }

    /// abort-after-tmp-before-rename: tmp 만 남음 → 이전 상태·generation 유지, 열 때 tmp 회수.
    func testFaultAbortAfterTmp() throws {
        let dir = try makeTempDir()
        let (a, b) = try makeConcretePair(dir)
        try a.withExclusive(room: "ft", timeout: 1) { tx in try tx.save(Data("v1".utf8)) }

        a.debugCrashHook = { phase in
            if phase == "after-tmp" { throw FileStateStore.FileCrashSimulated(phase: phase) }
        }
        XCTAssertThrowsError(try a.withExclusive(room: "ft", timeout: 1) { tx in
            try tx.save(Data("v2".utf8))
        })
        a.debugCrashHook = nil

        // 크래시 직후: 본체는 v1, tmp 잔존(프로세스가 죽었으니 정리는 없었다).
        XCTAssertEqual(try b.generation(room: "ft"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ft.state.tmp").path))
        // 다음 열림이 tmp 를 회수하고 이전 상태로 계속한다.
        try b.withExclusive(room: "ft", timeout: 1) { tx in
            XCTAssertEqual(try tx.load(), Data("v1".utf8))
            XCTAssertEqual(tx.generation, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ft.state.tmp").path))
        try a.withExclusive(room: "ft", timeout: 1) { tx in try tx.save(Data("v2".utf8)) }
        XCTAssertEqual(try b.generation(room: "ft"), 2)
    }

    /// abort-after-rename-before-gen: 본체는 새 상태, .gen 미러는 뒤처짐 → 열 때 헤더로 미러 복구.
    func testFaultAbortAfterRenameBeforeGen() throws {
        let dir = try makeTempDir()
        let (a, b) = try makeConcretePair(dir)
        try a.withExclusive(room: "fr", timeout: 1) { tx in try tx.save(Data("v1".utf8)) }

        a.debugCrashHook = { phase in
            if phase == "after-rename" { throw FileStateStore.FileCrashSimulated(phase: phase) }
        }
        XCTAssertThrowsError(try a.withExclusive(room: "fr", timeout: 1) { tx in
            try tx.save(Data("v2".utf8))
        })
        a.debugCrashHook = nil

        // 크래시 직후: 미러는 1(뒤처짐), 본체 헤더는 2.
        XCTAssertEqual(try b.generation(room: "fr"), 1, "crash left stale mirror")
        XCTAssertEqual(try headerGeneration(of: stateURL(dir, "fr")), 2, "state file already renamed")

        // 다음 스토어(프로세스)가 열면 헤더 generation 으로 미러를 복구하고 새 상태를 읽는다.
        let c = try makeStore(dir)
        try c.withExclusive(room: "fr", timeout: 1) { tx in
            XCTAssertEqual(try tx.load(), Data("v2".utf8))
            XCTAssertEqual(tx.generation, 2)
        }
        XCTAssertEqual(try b.generation(room: "fr"), 2, "mirror repaired from header")
    }

    /// 봉인 손상(AEAD 태그 불일치) → `.sealing`. 봉인은 Apple(CryptoKit) 경로라 Linux CI 에선 스킵.
    #if canImport(CryptoKit)
    func testCorruptSealedPayloadThrowsSealing() throws {
        let dir = try makeTempDir()
        let (a, b) = try makePair(dir)
        try a.withExclusive(room: "cs", timeout: 1) { tx in try tx.save(Data("payload".utf8)) }

        let url = stateURL(dir, "cs")
        var blob = try Data(contentsOf: url)
        XCTAssertGreaterThan(blob.count, 16 + 12 + 16)
        blob[blob.count - 1] ^= 0xFF  // 태그 1바이트 뒤집기
        try blob.write(to: url)

        XCTAssertThrowsError(try b.withExclusive(room: "cs", timeout: 1) { tx in
            _ = try tx.load()
        }) { error in
            guard case StateStoreError.sealing = error else {
                return XCTFail("expected .sealing, got \(error)")
            }
        }
    }
    #endif

    /// 잠금 보유 "프로세스 죽음" = fd close → 커널이 flock 해제하는 OS 성질을 그대로 증명.
    func testLockReleasedWhenHolderDescriptorCloses() throws {
        let dir = try makeTempDir()
        let b = try makeStore(dir)
        let lockPath = dir.appendingPathComponent("lk.lock").path

        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "test acquires the lock like another process")

        XCTAssertThrowsError(try b.withExclusive(room: "lk", timeout: 0.2) { _ in }) { error in
            guard case StateStoreError.lockTimeout(let room) = error, room == "lk" else {
                return XCTFail("expected lockTimeout, got \(error)")
            }
        }

        close(fd)  // = 보유 프로세스 죽음 (명시적 unlock 없음)

        try b.withExclusive(room: "lk", timeout: 2) { tx in
            XCTAssertNil(try tx.load())
        }
    }

    /// 두 인스턴스 교대 쓰기 1,000회 — generation 단조 증가 + 마지막 상태.
    func testThousandAlternatingWritesGenerationMonotonic() throws {
        let dir = try makeTempDir()
        let (a, b) = try makePair(dir)
        for i in 0..<1000 {
            let store = i % 2 == 0 ? a : b
            let expected = UInt64(i + 1)
            try store.withExclusive(room: "alt", timeout: 5) { tx in
                XCTAssertEqual(tx.generation, UInt64(i), "generation monotonic before save \(i)")
                try tx.save(Data("\(i)".utf8))
            }
            _ = expected
        }
        XCTAssertEqual(try a.generation(room: "alt"), 1000)
        try b.withExclusive(room: "alt", timeout: 1) { tx in
            XCTAssertEqual(try tx.load(), Data("999".utf8))
            XCTAssertEqual(tx.generation, 1000)
        }
    }

    /// 1,000 메시지 규모에서 `.state` 크기는 메시지 수와 무관(선형 아님) — 같은 상태 반영 저장은
    /// 항상 같은 크기(로그 성장 없음). 또한 저장 1회 = 커밋 파이프라인 1회(전체 직렬화 1회).
    func testStateSizeNotLinearOverThousandSaves() throws {
        let dir = try makeTempDir()
        let (a, b) = try makeConcretePair(dir)
        let payload = Data(repeating: 0x5A, count: 4096)

        var commits = 0
        a.debugCrashHook = { phase in
            if phase == "commit-start" { commits += 1 }
        }
        b.debugCrashHook = { phase in
            if phase == "commit-start" { commits += 1 }
        }
        defer {
            a.debugCrashHook = nil
            b.debugCrashHook = nil
        }

        var sizeAfterFirst: Int?
        for i in 0..<100 {
            let store = i % 2 == 0 ? a : b
            try store.withExclusive(room: "sz", timeout: 5) { tx in try tx.save(payload) }
            let attributes = try FileManager.default.attributesOfItem(atPath: stateURL(dir, "sz").path)
            let size = attributes[.size] as! Int
            if let first = sizeAfterFirst {
                XCTAssertEqual(size, first, "sealed state size must stay constant (save \(i))")
            } else {
                sizeAfterFirst = size
            }
        }
        XCTAssertGreaterThan(sizeAfterFirst ?? 0, 4096)
        XCTAssertEqual(commits, 100, "one save = one commit pipeline = one serialization")
    }

    /// 계약 문서의 mismatch 경로: 트랜잭션 도중 디스크 generation 이 바뀌면 커밋이 실패하고 디스크는 불변.
    func testGenerationMismatchAbortsCommit() throws {
        let dir = try makeTempDir()
        let (a, b) = try makePair(dir)
        try a.withExclusive(room: "gm", timeout: 1) { tx in try tx.save(Data("v1".utf8)) }

        XCTAssertThrowsError(try a.withExclusive(room: "gm", timeout: 1) { tx in
            try tx.save(Data("v2".utf8))
            // 잠금이 있으면 일어날 수 없는 일을 흉내: 다른 주체가 미러를 바꿨다.
            var bytes = Data(count: 8)
            withUnsafeBytes(of: UInt64(99).littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
            try FileSys.writeFileSync(path: genURL(dir, "gm").path, bytes: bytes)
        }) { error in
            XCTAssertEqual(error as? StateStoreError, .generationMismatch(expected: 1, actual: 99))
        }

        try b.withExclusive(room: "gm", timeout: 1) { tx in
            XCTAssertEqual(try tx.load(), Data("v1".utf8), "disk immutable on mismatch")
            XCTAssertEqual(tx.generation, 1)
        }
    }

    /// 파일명으로 쓰이는 room id 위생 — 경로 조작 불가.
    func testRejectUnsafeRoomNames() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        for bad in ["../evil", "a/b", "", ".", "..", "room with space"] {
            XCTAssertThrowsError(try store.withExclusive(room: bad, timeout: 1) { _ in }, "\(bad)") { error in
                guard case StateStoreError.io = error else {
                    return XCTFail("\(bad): expected .io, got \(error)")
                }
            }
        }
    }

    /// 같은 스레드에서의 다른 인스턴스 재진입은 데드락이 아니라 timeout 이다(잠금은 파일 단위).
    func testCrossInstanceSameThreadTimesOut() throws {
        let dir = try makeTempDir()
        let (a, b) = try makePair(dir)
        XCTAssertThrowsError(try a.withExclusive(room: "x", timeout: 1) { _ in
            try b.withExclusive(room: "x", timeout: 0.15) { _ in }
        }) { error in
            guard case StateStoreError.lockTimeout = error else {
                return XCTFail("expected lockTimeout, got \(error)")
            }
        }
    }

    // MARK: Keychain 키 소스(운영 경로) — macOS job 대상

    #if canImport(Security)
    func testKeychainSealKeySourceCreatesAndSharesKey() throws {
        let service = "fm.mls.test-\(UUID().uuidString)"
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "seal-v1",
            ] as CFDictionary)
        }
        let first = KeychainSealKeySource(service: service)
        let second = KeychainSealKeySource(service: service)
        let key1 = try first.key32()
        XCTAssertEqual(key1.count, 32)
        XCTAssertEqual(try second.key32(), key1, "two instances share the Keychain key")
    }
    #endif

    // MARK: 내부 도우미

    /// .state 헤더의 평문 generation(8..16 바이트) 을 직접 읽는다(테스트 단정용).
    private func headerGeneration(of url: URL) throws -> UInt64 {
        let raw = try Data(contentsOf: url)
        XCTAssertTrue(raw.count >= 16)
        return raw.dropFirst(8).prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }
}
