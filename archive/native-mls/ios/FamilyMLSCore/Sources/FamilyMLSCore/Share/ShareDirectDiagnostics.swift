// #664 공유 확장 직접 송신 측정 기록 — Mac(Console) 없이 앱의 「진단 기록 복사」로 읽기 위한 것(P3 D-A4 문턱의 입력).
//
// 확장은 앱과 다른 프로세스라 앱의 진단 기록(메모리 200줄)에 줄을 더할 수 없다. 그래서 App Group 컨테이너의 작은 파일
// `share-direct-send.json` 에 직접 송신 1회마다 기록 1건을 남기고(확장만 쓴다), 앱은 복사할 때 읽어 한 구획으로 붙인다(앱은 읽기만).
//
//   - **시작 표시 먼저**: 봉인·업로드 전에 `begin`(조각 수·바이트·송신 전 메모리·한도)을 쓰고, 끝나면 `finish` 가 같은 기록에 결과를 채운다.
//     확장이 송신 도중 죽으면(메모리 한도 초과 = jetsam, 로그도 남지 않는다) 결과 없는 기록이 남아 `did-not-finish` 로 보인다 —
//     이것이 문턱 초과 신호다. 임대(`ShareHandoff.sendingLease`) 안이면 아직 보내는 중일 수 있어 `in-progress`.
//   - **최근 `keep` 건만**, 원자 쓰기(임시 파일 → rename). 쓰기·읽기 실패는 조용히 무시한다 — 측정이 송신을 막거나 실패시키지 않는다.
//   - **식별자 없음(형식으로 보장)**: 기록의 필드는 개수·바이트·MB·초·시각과 닫힌 토큰 둘(빌드 번호 = 숫자·점, 멈춤 사유 = 소문자·밑줄
//     머리 토큰)뿐이다. 글·파일 이름·방·사람·기기 ID 를 받는 자리가 없고, 문자열 둘은 쓸 때와 보일 때 모두 걸러진다.
//
// Foundation 만 쓴다 — Linux `swift test`. 파일 시각 API 는 쓰지 않는다(시각은 기록 안의 `startedAt`, Required Reason 범주를 늘리지 않음).
import Foundation

public enum ShareDirectDiagnostics {
    /// App Group 컨테이너 바로 아래 파일 이름(맡김 `share-outbox/` 와 섞지 않는다 — 그 디렉터리는 앱이 정리한다).
    public static let fileName = "share-direct-send.json"
    /// 남기는 기록 수(최근 것). 1건 ≈ 250바이트 → 파일은 수 KB.
    public static let keep = 20
    /// 「진단 기록 복사」 안의 구획 머리.
    public static let sectionTitle = "share direct-send:"

    /// 직접 송신 1회. `outcome == nil` = 시작만 기록됐다(보내는 중이거나, 확장이 도중에 끝났다).
    public struct Record: Codable, Equatable {
        /// 송신 시작 시각(1970 기준 정수 밀리초 — `ShareHandoff.milliseconds`).
        public private(set) var startedAt: Int64
        /// 앱 빌드 번호(`CFBundleVersion`) — 숫자·점만.
        public private(set) var build: String
        /// 직접 보내려던 조각 수 / 앱에 미룬 조각 수 / 직접 보내려던 파일 바이트 합.
        public private(set) var pieces: Int
        public private(set) var deferred: Int
        public private(set) var bytes: Int
        /// 송신 직전 물리 메모리(MB). 못 읽었으면 nil.
        public private(set) var footprintBefore: Double?
        /// 이 프로세스의 메모리 한도(MB) = 송신 직전 값 + 한도까지 남은 양. 모르면 nil(시뮬레이터 등).
        public private(set) var limit: Double?
        public private(set) var outcome: Outcome?

        public init(startedAt: Date, build: String?, pieces: Int, deferred: Int, bytes: Int, footprintBefore: Double?, limit: Double?) {
            self.startedAt = ShareHandoff.milliseconds(startedAt)
            self.build = ShareDirectDiagnostics.buildToken(build)
            self.pieces = max(0, pieces); self.deferred = max(0, deferred); self.bytes = max(0, bytes)
            self.footprintBefore = ShareDirectDiagnostics.tenths(footprintBefore)
            self.limit = ShareDirectDiagnostics.tenths(limit)
        }

        /// 계획에서 — 조각의 **개수**만 꺼낸다(이름·내용은 건드리지 않는다).
        public init(startedAt: Date, build: String?, plan: ShareDirectSend.Plan, bytes: Int, footprintBefore: Double?, limit: Double?) {
            self.init(startedAt: startedAt, build: build, pieces: plan.direct.count, deferred: plan.deferred.count, bytes: bytes,
                      footprintBefore: footprintBefore, limit: limit)
        }

        /// 결과를 채운 사본.
        public func finished(_ outcome: Outcome) -> Record {
            var out = self
            out.outcome = outcome
            return out
        }
    }

    /// 직접 송신이 끝난 뒤의 결과.
    public struct Outcome: Codable, Equatable {
        public private(set) var sent: Int
        public private(set) var queued: Int
        public private(set) var refused: Int
        /// 멈춘 사유의 머리 토큰(`not_joined`·`lock_timeout`·`network` …). nil = 직접 조각을 끝까지 돌았다.
        public private(set) var stopped: String?
        /// 송신 뒤 물리 메모리(MB) / 프로세스가 살아온 동안의 **최고치**(MB, 송신 전 화면 준비 포함) / 송신에 걸린 초.
        public private(set) var footprintAfter: Double?
        public private(set) var footprintPeak: Double?
        public private(set) var seconds: Double

        public init(sent: Int, queued: Int, refused: Int, stopped: String?, footprintAfter: Double?, footprintPeak: Double?, seconds: Double) {
            self.sent = max(0, sent); self.queued = max(0, queued); self.refused = max(0, refused)
            self.stopped = ShareDirectDiagnostics.stopToken(stopped)
            self.footprintAfter = ShareDirectDiagnostics.tenths(footprintAfter)
            self.footprintPeak = ShareDirectDiagnostics.tenths(footprintPeak)
            self.seconds = ShareDirectDiagnostics.tenths(seconds) ?? 0
        }

        /// 보고서에서 — 조각의 **개수**와 멈춤 사유 토큰만.
        public init(report: ShareDirectSend.Report, footprintAfter: Double?, footprintPeak: Double?, seconds: Double) {
            self.init(sent: report.sent.count, queued: report.queued.count, refused: report.refused.count, stopped: report.stopped,
                      footprintAfter: footprintAfter, footprintPeak: footprintPeak, seconds: seconds)
        }
    }

    /// 디스크 봉투. 형식을 바꾸면 `version` 을 올린다 — 모르는 버전은 빈 기록으로 읽는다.
    struct Log: Codable {
        static let currentVersion = 1
        var version: Int
        var records: [Record]
    }

    // MARK: - 닫힌 토큰(식별자가 들어올 수 없게)

    /// 빌드 번호: 숫자·점만, 12자까지. 비면 "?".
    static func buildToken(_ raw: String?) -> String {
        let token = String((raw ?? "").filter { $0.isASCII && ($0.isNumber || $0 == ".") }.prefix(12))
        return token.isEmpty ? "?" : token
    }

    /// 멈춤 사유: `ShareDirectSend.describe` 의 머리 토큰만(첫 `:` 앞, 소문자·밑줄, 24자까지). `halted: <사유>`·`error: <타입>` 의 꼬리는
    /// 버린다 — 정지 사유 문구에는 무엇이든 들어 있을 수 있다. 걸러서 비면 "other".
    static func stopToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let head = raw.prefix(while: { $0 != ":" })
        let token = String(head.filter { $0.isASCII && ($0.isLowercase || $0 == "_") }.prefix(24))
        return token.isEmpty ? "other" : token
    }

    /// 소수 한 자리로(MB·초). 음수·무한·NaN 은 nil — JSON 으로 쓸 수 없고 뜻도 없다.
    static func tenths(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return (value * 10).rounded() / 10
    }

    // MARK: - 「진단 기록 복사」 줄

    /// 기록 한 줄 — 확장의 os_log 줄과 같은 이름(`pieces=`…`footprint_mb_after=`)에 최고치·한도·초를 더한다. 결과가 없으면
    /// 임대 안은 `in-progress`, 지났으면 `did-not-finish`.
    public static func line(_ record: Record, now: Date = Date()) -> String {
        let started = ShareHandoff.date(milliseconds: record.startedAt)
        var parts: [String] = [ISO8601DateFormatter().string(from: started)]
        parts.append("build=\(buildToken(record.build))")
        parts.append("pieces=\(record.pieces)")
        parts.append("deferred=\(record.deferred)")
        parts.append("bytes=\(record.bytes)")
        guard let outcome = record.outcome else {
            parts.append("footprint_mb_before=\(number(record.footprintBefore))")
            parts.append("limit_mb=\(number(record.limit))")
            parts.append(now.timeIntervalSince(started) < ShareHandoff.sendingLease ? "in-progress" : "did-not-finish")
            return parts.joined(separator: " ")
        }
        parts.append("sent=\(outcome.sent)")
        parts.append("queued=\(outcome.queued)")
        parts.append("refused=\(outcome.refused)")
        parts.append("stopped=\(stopToken(outcome.stopped) ?? "-")")
        parts.append("footprint_mb_before=\(number(record.footprintBefore))")
        parts.append("footprint_mb_after=\(number(outcome.footprintAfter))")
        parts.append("footprint_mb_peak=\(number(outcome.footprintPeak))")
        parts.append("limit_mb=\(number(record.limit))")
        parts.append("seconds=\(number(outcome.seconds))")
        return parts.joined(separator: " ")
    }

    /// 구획 전체(머리 + 오래된 것부터 한 줄씩). 기록이 없으면 머리 + `(none)` — 이 빌드에 측정은 있으나 직접 송신이 돈 적이 없다는 뜻.
    public static func lines(_ records: [Record], now: Date = Date()) -> [String] {
        [sectionTitle] + (records.isEmpty ? ["(none)"] : records.map { line($0, now: now) })
    }

    private static func number(_ value: Double?) -> String {
        guard let value = tenths(value) else { return "-" }
        return String(format: "%.1f", value)
    }
}

public extension ShareDirectSend.Plan {
    /// 직접 보내는 조각의 파일 바이트 합(글은 0, 크기를 못 읽은 파일도 0) — 측정 기록의 `bytes`.
    func directFileBytes(fileSize: (String) -> Int?) -> Int {
        direct.reduce(0) { total, piece in
            if case .file(let name) = piece { return total + (fileSize(name) ?? 0) }
            return total
        }
    }
}

/// 측정 기록 저장소(확장 = `begin`·`finish`, 앱 = `records`·`lines`). 어떤 실패도 던지지 않는다.
public final class ShareDirectDiagnosticsStore {
    public let file: URL

    /// `container` = App Group 컨테이너(테스트는 임시 디렉터리).
    public init(container: URL) {
        self.file = container.appendingPathComponent(ShareDirectDiagnostics.fileName)
    }

    /// 남아 있는 기록(오래된 것부터). 파일이 없거나 읽을 수 없거나 모르는 버전이면 빈 배열.
    public func records() -> [ShareDirectDiagnostics.Record] {
        guard let data = try? Data(contentsOf: file),
              let log = try? JSONDecoder().decode(ShareDirectDiagnostics.Log.self, from: data),
              log.version == ShareDirectDiagnostics.Log.currentVersion else { return [] }
        return log.records
    }

    /// 확장: 송신 **전에** 시작 표시를 남긴다. 쓰지 못해도 송신은 계속한다.
    public func begin(_ record: ShareDirectDiagnostics.Record) {
        write(records() + [record])
    }

    /// 확장: 송신이 끝났다 — 같은 시작 표시(시각이 같고 결과가 없는 것)에 결과를 채운다. 표시가 없으면(쓰기 실패·밀려남) 끝에 더한다.
    public func finish(_ record: ShareDirectDiagnostics.Record, _ outcome: ShareDirectDiagnostics.Outcome) {
        var all = records()
        let done = record.finished(outcome)
        if let index = all.lastIndex(where: { $0.startedAt == record.startedAt && $0.outcome == nil }) {
            all[index] = done
        } else {
            all.append(done)
        }
        write(all)
    }

    /// 앱: 「진단 기록 복사」에 붙일 구획.
    public func lines(now: Date = Date()) -> [String] {
        ShareDirectDiagnostics.lines(records(), now: now)
    }

    private func write(_ records: [ShareDirectDiagnostics.Record]) {
        let log = ShareDirectDiagnostics.Log(version: ShareDirectDiagnostics.Log.currentVersion,
                                             records: Array(records.suffix(ShareDirectDiagnostics.keep)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
