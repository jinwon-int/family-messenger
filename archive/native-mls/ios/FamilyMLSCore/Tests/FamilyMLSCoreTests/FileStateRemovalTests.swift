// `RoomStateRemoving`(StateRemoval.swift) — 파일 저장소의 방 상태 삭제: 잠금 안에서, 멱등, 삭제 뒤 generation 0 → 시드에서 재시작.
import XCTest
@testable import FamilyMLSCore

final class FileStateRemovalTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fmrm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(_ dir: URL) throws -> FileStateStore {
        #if canImport(CryptoKit)
        return try FileStateStore(directory: dir, sealer: ChaChaPolySealer(keySource: StaticSealKeySource(key: Data(repeating: 7, count: 32))))
        #else
        return try FileStateStore(directory: dir, sealer: PassthroughSealer())
        #endif
    }

    func testRemoveStateClearsFilesAndGenerationAndIsIdempotent() throws {
        let dir = try makeDir()
        let store = try makeStore(dir)
        try store.withExclusive(room: "family", timeout: 1) { try $0.save(Data("g1".utf8)) }
        try store.withExclusive(room: "family", timeout: 1) { try $0.save(Data("g2".utf8)) }
        XCTAssertEqual(try store.generation(room: "family"), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("family.state").path))

        try store.removeState(room: "family", timeout: 1)
        XCTAssertEqual(try store.generation(room: "family"), 0, "no state = generation 0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("family.state").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("family.gen").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("family.lock").path), "lock anchor stays")
        try store.withExclusive(room: "family", timeout: 1) { XCTAssertNil(try $0.load(), "next transaction starts from nothing") }

        try store.removeState(room: "family", timeout: 1)   // 멱등
        try store.removeState(room: "never-existed", timeout: 1)

        // 다시 저장하면 1 부터(헤더·미러 모두 새로).
        try store.withExclusive(room: "family", timeout: 1) { try $0.save(Data("fresh".utf8)) }
        XCTAssertEqual(try store.generation(room: "family"), 1)
        XCTAssertEqual(try store.withExclusive(room: "family", timeout: 1) { try $0.load() }, Data("fresh".utf8))
    }

    func testRemoveStateWaitsForTheRoomLock() throws {
        let dir = try makeDir()
        let writer = try makeStore(dir)
        let remover = try makeStore(dir)
        try writer.withExclusive(room: "family", timeout: 1) { try $0.save(Data("g1".utf8)) }

        let holding = expectation(description: "holder inside transaction")
        let release = expectation(description: "release holder")
        let thread = Thread {
            try? writer.withExclusive(room: "family", timeout: 1) { _ in
                holding.fulfill()
                self.wait(for: [release], timeout: 5)
            }
        }
        thread.start()
        wait(for: [holding], timeout: 5)
        XCTAssertThrowsError(try remover.removeState(room: "family", timeout: 0.2)) { error in
            XCTAssertEqual(error as? StateStoreError, .lockTimeout("family"), "removal does not bypass the single-writer lock")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("family.state").path), "nothing was deleted under a held lock")
        release.fulfill()
        while !thread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        try remover.removeState(room: "family", timeout: 1)
        XCTAssertEqual(try remover.generation(room: "family"), 0)
    }

    func testRemoveStateRejectsUnsafeRoomNames() {
        XCTAssertThrowsError(try makeStore(try makeDir()).removeState(room: "../etc", timeout: 1))
    }
}
