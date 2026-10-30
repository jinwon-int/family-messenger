// status-v1(#560, STATUS-V1.md): `status-<uuid>` 형식 판정 · 동기화가 저장하지 않고 패스에 싣는지 · 방별 임시 말풍선 판정
// (웹 `status-v1.test.mjs` 와 같은 사례).
import XCTest
@testable import FamilyMLSCore

final class StatusFormatTests: XCTestCase {
    let alice = "alice-pc"
    let bot = "dungae-bot"
    static let uuid = "0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"

    // MARK: 형식

    func testClientIdRuleMatchesBotRelayAndWeb() {
        XCTAssertTrue(StatusFormat.isClientId("status-\(Self.uuid)"))
        XCTAssertFalse(StatusFormat.isClientId("status-\(Self.uuid.uppercased())"), "lowercase only")
        XCTAssertFalse(StatusFormat.isClientId("status-"), "prefix alone is a normal message")
        XCTAssertFalse(StatusFormat.isClientId("status-report"))
        XCTAssertFalse(StatusFormat.isClientId("status-\(Self.uuid)x"))
        XCTAssertFalse(StatusFormat.isClientId("file-v2-\(Self.uuid)"))
        XCTAssertFalse(StatusFormat.isClientId("dungae-bot-echo-3"))
        XCTAssertFalse(StatusFormat.isClientId(""))
    }

    // MARK: 동기화

    private func joinedHarness() throws -> SyncHarness {
        let h = try SyncHarness()
        try h.store.seed(room: h.room, .joined([alice, bot, h.me].sorted(), epoch: 1, pending: nil))
        h.relay.epoch = 1
        h.relay.members = [alice, bot, h.me]
        return h
    }

    func testStatusEventIsCarriedOnThePassNeverStoredAndTheCursorAdvances() async throws {
        let h = try joinedHarness()
        let sent: Int64 = 1_792_306_680
        let status = h.relay.inject(device: bot, kind: .application, bytes: h.ciphertext(from: bot, clientId: bot, text: "⏳ Working — 10s | Bash: ls"),
                                    clientId: "status-\(Self.uuid)", createdAt: sent)
        let reply = h.relay.inject(device: bot, kind: .application, bytes: h.ciphertext(from: bot, clientId: bot, text: "답"))
        let plain = h.relay.inject(device: bot, kind: .application, bytes: h.ciphertext(from: bot, clientId: bot, text: "status-report"),
                                   clientId: "status-report")
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.statuses, [AgentStatusLine(sender: bot, text: "⏳ Working — 10s | Bash: ls", seq: status,
                                                       sentAt: Date(timeIntervalSince1970: TimeInterval(sent)))])
        XCTAssertEqual(pass.inserted, [reply, plain], "a status is never inserted")
        XCTAssertEqual(pass.rejected, [])
        XCTAssertEqual(try h.messages.messages(room: h.room, after: 0, limit: 10).map(\.seq), [reply, plain])
        XCTAssertEqual(pass.cursor, plain)
        XCTAssertEqual(try h.cursors.cursor(room: h.room), plain, "the cursor (and so the ack) passes the status")
        XCTAssertEqual(h.engineState?.receiveGeneration, 3, "the status was decrypted — the receive ratchet moved")
    }

    func testUndecryptableOrSpoofedStatusLeavesNoRow() async throws {
        let h = try joinedHarness()
        let bad = h.relay.inject(device: bot, kind: .application, bytes: Data("garbage".utf8), clientId: "status-\(Self.uuid)")
        let spoof = h.relay.inject(device: bot, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "⏳ 가짜"),
                                   clientId: "status-1f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2")
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.statuses, [])
        XCTAssertEqual(pass.inserted, [])
        XCTAssertEqual(pass.rejected, [], "a lost status line is not worth an 「해독할 수 없는 메시지」 row")
        XCTAssertEqual(h.messages.records, [])
        XCTAssertEqual(try h.cursors.cursor(room: h.room), max(bad, spoof))
    }

    // MARK: 말풍선 판정

    private func line(_ sender: DeviceID, _ text: String, _ seq: Int64, at: Date) -> AgentStatusLine {
        AgentStatusLine(sender: sender, text: text, seq: seq, sentAt: at)
    }

    func testOneBubblePerSenderUpdatedInPlaceNewestWins() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var board = AgentStatusBoard()
        XCTAssertTrue(board.apply(line(bot, "⏳ Working — 5s", 10, at: now), now: now))
        XCTAssertTrue(board.apply(line(bot, "⏳ Working — 10s | Bash: ls", 11, at: now), now: now))
        XCTAssertFalse(board.apply(line(bot, "⏳ Working — 10s | Bash: ls", 12, at: now), now: now), "same text → no repaint")
        XCTAssertFalse(board.apply(line(bot, "⏳ old", 9, at: now), now: now), "an older status never replaces a newer one")
        board.apply(line("seoseo-bot", "⏳ Working — 5s", 13, at: now), now: now)
        XCTAssertEqual(board.visible(now: now).map { "\($0.sender):\($0.text)" },
                       ["\(bot):⏳ Working — 10s | Bash: ls", "seoseo-bot:⏳ Working — 5s"])
        XCTAssertEqual(board.oldestSeq, 12)
    }

    func testTheSendersNextMessageClearsOnlyItsBubble() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var board = AgentStatusBoard()
        board.apply(line(bot, "⏳ a", 10, at: now), now: now)
        board.apply(line("seoseo-bot", "⏳ b", 11, at: now), now: now)
        XCTAssertTrue(board.clear(sender: bot, seq: 12))
        XCTAssertEqual(board.visible(now: now).map(\.sender), ["seoseo-bot"])
        XCTAssertFalse(board.clear(sender: alice, seq: 13), "a human message touches nobody else")
        XCTAssertFalse(board.clear(sender: "seoseo-bot", seq: 5), "an older message (history) never clears a newer status")
        XCTAssertEqual(board.visible(now: now).count, 1)
    }

    func testExpiresFiveMinutesAfterTheLastUpdateUsingRelayTimeCappedAtThisClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var board = AgentStatusBoard()
        board.apply(line(bot, "⏳ a", 1, at: now), now: now)
        XCTAssertEqual(board.visible(now: now.addingTimeInterval(AgentStatusBoard.ttl)).count, 1)
        XCTAssertEqual(board.visible(now: now.addingTimeInterval(AgentStatusBoard.ttl + 1)).count, 0)
        board.expire(now: now.addingTimeInterval(AgentStatusBoard.ttl + 1))
        XCTAssertTrue(board.isEmpty)
        // 밀린 이력(한 시간 전 status)은 도착하자마자 만료.
        board.apply(line(bot, "⏳ old", 2, at: now.addingTimeInterval(-3600)), now: now)
        XCTAssertEqual(board.visible(now: now).count, 0)
        // 릴레이 시계가 앞서도 이 기기 시계보다 오래 남지 않는다.
        board.apply(line(bot, "⏳ future", 3, at: now.addingTimeInterval(3600)), now: now)
        XCTAssertEqual(board.visible(now: now.addingTimeInterval(AgentStatusBoard.ttl + 1)).count, 0)
    }

    func testRoomListLineIsTheNewestVisibleStatusAndNilWhenNone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var board = AgentStatusBoard()
        XCTAssertNil(AgentStatusBoard.listLine(board.visible(now: now)), "no status → the list shows its normal preview")
        board.apply(line(bot, "⏳ Working — 5s", 10, at: now), now: now)
        board.apply(line("seoseo-bot", "⏳ Working — 20s | Bash: df", 14, at: now), now: now)
        board.apply(line(bot, "⏳ Working — 10s | Read", 12, at: now), now: now)
        XCTAssertEqual(AgentStatusBoard.listLine(board.visible(now: now)), "⏳ Working — 20s | Bash: df", "newest seq across senders")
        board.clear(sender: "seoseo-bot", seq: 15)
        XCTAssertEqual(AgentStatusBoard.listLine(board.visible(now: now)), "⏳ Working — 10s | Read")
        board.clear(sender: bot, seq: 16)
        XCTAssertNil(AgentStatusBoard.listLine(board.visible(now: now)), "reply arrived → back to the normal preview")
        board.apply(line(bot, "⏳ Working — 5s", 17, at: now), now: now)
        XCTAssertNil(AgentStatusBoard.listLine(board.visible(now: now.addingTimeInterval(AgentStatusBoard.ttl + 1))), "expired → normal preview")
    }

    func testBlankLinesAreIgnoredAndLongLinesBounded() {
        var board = AgentStatusBoard()
        XCTAssertFalse(board.apply(line(bot, "   \n", 1, at: Date())))
        XCTAssertFalse(board.apply(line("", "⏳", 1, at: Date())))
        board.apply(line(bot, "⏳ " + String(repeating: "x", count: 5000), 2, at: Date()))
        XCTAssertEqual(board.visible().first?.text.count, StatusFormat.maxTextLength)
    }
}
