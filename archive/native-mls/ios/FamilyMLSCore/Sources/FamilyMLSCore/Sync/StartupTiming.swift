// 시작 구간 계측(#836 — #766 I 의 iOS 판). 앱이 시작한 순간부터 첫 화면(방 목록·로그인·등록 화면 등)까지 구간별로 몇 ms 가
// 걸렸는지 한 줄로 남긴다. 웹 `startup-timing.js`(#805, 「첫 화면까지 N ms (대화 화면 · 저장분) — …」)·Android
// `boot: first screen N ms (stored|network)`(#827)와 같은 뜻이다. 줄은 진단 기록(🔔 「진단 기록 복사」)에 들어가므로 Xcode 없이
// 현장 값을 받는다 — #766 B(저장분으로 먼저 그리기)의 before/after 는 이 줄로 잰다.
//
// 순수 값 타입(시계 없음, Linux `swift test`): 호출자가 단조 시계의 초(`ProcessInfo.systemUptime`)를 넘긴다.
// 기록하는 것은 구간·화면 이름과 ms 뿐이다 — 방 이름·기기 ID·주소는 넣지 않는다(이름은 [A-Za-z0-9_-] 24자로 깎는다).
//
// 줄 모양:
//   startup: first screen 412 ms (stored) — launch 300 · identity 95 · rooms 17
//   startup: first screen 1650 ms (network) — launch 300 · identity 95 · rooms 17 · listing 410 · sync 828
//   startup: first sync 1180 ms (ready)
// - 구간 ms 는 앞 구간이 끝난 뒤부터 그 구간이 끝날 때까지다 — 합이 총합이다. 마지막 구간 뒤 첫 화면까지 남은 시간은 `rest`.
// - 괄호 안은 첫 화면이 무엇이었나(앱이 정한다): stored = 릴레이 응답 전에 저장된 방으로 그림, network = 응답 뒤에 그림 등.
// - `first sync` 줄은 첫 화면을 첫 동기화 한 바퀴 **전에** 그렸을 때만(`finish(… awaitingSync: true)`), 그 바퀴가 끝날 때 한 번 —
//   같은 시작 기준의 ms 와 그 바퀴의 결과(ready · offline · enroll …). 저장분으로 그린 실행과 종전 실행(network)을 이 값으로 견준다.
import Foundation

/// 한 실행의 시작 → 첫 화면 계측. 앱 모델이 들고 있다. 첫 화면은 한 번만 — 그 뒤의 `mark`·`finish` 는 무시한다.
public struct StartupTiming: Equatable, Sendable {
    /// 한 번의 시작에서 남기는 구간 수 상한(웹 `MAX_STAGES` 와 같다 — 다시 지나는 경로가 줄을 늘리지 않게).
    public static let maxStages = 16
    /// 마지막 구간 뒤 첫 화면까지 남은 시간(웹의 `paint` 자리).
    public static let restStage = "rest"

    public struct Stage: Equatable, Sendable {
        public let name: String
        /// 앞 구간이 끝난 뒤부터 이 구간이 끝날 때까지(ms).
        public let ms: Int
        public init(name: String, ms: Int) { self.name = name; self.ms = ms }
    }

    /// `screen` = 첫 화면(또는 첫 동기화의 결과) 이름, `total` = 시작부터 ms. 첫 화면 요약은 `stages` 의 합이 `total` 이다.
    public struct Summary: Equatable, Sendable {
        public let screen: String
        public let total: Int
        public let stages: [Stage]
        public init(screen: String, total: Int, stages: [Stage]) { self.screen = screen; self.total = total; self.stages = stages }
    }

    private struct Mark: Equatable, Sendable {
        let name: String
        /// 시작부터 ms(앞 표시보다 작아지지 않게 맞춘 값).
        let at: Int
    }

    /// 시작 시각(호출자의 단조 시계 초).
    public let origin: TimeInterval
    private var marks: [Mark] = []
    /// 첫 화면 요약. nil = 아직 시작 화면.
    public private(set) var firstScreen: Summary?
    /// 첫 화면을 첫 동기화 전에 그렸고 그 바퀴가 아직 끝나지 않았다.
    public private(set) var awaitsFirstSync = false
    /// 첫 동기화 한 바퀴의 끝(`awaitsFirstSync` 였을 때만). `stages` 는 비어 있다.
    public private(set) var firstSync: Summary?

    public init(origin: TimeInterval) { self.origin = origin }

    public var finished: Bool { firstScreen != nil }

    /// 구간 하나가 방금 끝났다. 같은 이름은 처음 것만, 첫 화면 뒤·상한 뒤는 무시한다.
    public mutating func mark(_ name: String, at now: TimeInterval) {
        guard firstScreen == nil, marks.count < Self.maxStages else { return }
        let key = Self.clean(name)
        guard !marks.contains(where: { $0.name == key }) else { return }
        // 시계가 뒤로 가도 구간이 음수가 되지 않게 앞 표시 뒤로 맞춘다.
        let floor = marks.last?.at ?? 0
        marks.append(Mark(name: key, at: max(elapsed(now), floor)))
    }

    /// 첫 화면이 정해졌다. 처음 한 번만 진단 기록 한 줄을 돌려주고, 그 뒤로는 nil.
    /// `awaitingSync` = 이 화면을 첫 동기화 한 바퀴 전에 그렸다(그 바퀴가 끝나면 `finishFirstSync` 가 한 줄 더).
    @discardableResult
    public mutating func finish(_ screen: String, at now: TimeInterval, awaitingSync: Bool = false) -> String? {
        guard firstScreen == nil else { return nil }
        var stages: [Stage] = []
        var previous = 0
        for mark in marks {
            stages.append(Stage(name: mark.name, ms: mark.at - previous))
            previous = mark.at
        }
        let end = max(elapsed(now), previous)
        if end > previous { stages.append(Stage(name: Self.restStage, ms: end - previous)) }
        let summary = Summary(screen: Self.clean(screen), total: end, stages: stages)
        firstScreen = summary
        awaitsFirstSync = awaitingSync
        return Self.line(firstScreen: summary)
    }

    /// 첫 화면 뒤 첫 동기화 한 바퀴가 끝났다(`outcome` = 그 바퀴 뒤의 상태 이름). 기다리던 때 한 번만 한 줄, 그 밖에는 nil.
    @discardableResult
    public mutating func finishFirstSync(_ outcome: String, at now: TimeInterval) -> String? {
        guard let screen = firstScreen, awaitsFirstSync, firstSync == nil else { return nil }
        let summary = Summary(screen: Self.clean(outcome), total: max(elapsed(now), screen.total), stages: [])
        firstSync = summary
        awaitsFirstSync = false
        return Self.line(firstSync: summary)
    }

    /// 진단 기록 머리에 둘 줄(기록이 200줄을 넘겨 밀려나도 남게) — 아직 없으면 빈 배열.
    public var lines: [String] {
        var out: [String] = []
        if let screen = firstScreen { out.append(Self.line(firstScreen: screen)) }
        if let sync = firstSync { out.append(Self.line(firstSync: sync)) }
        return out
    }

    public static func line(firstScreen summary: Summary) -> String {
        let head = "startup: first screen \(summary.total) ms (\(summary.screen))"
        guard !summary.stages.isEmpty else { return head }
        let parts = summary.stages.map { "\($0.name) \($0.ms)" }
        return head + " — " + parts.joined(separator: " · ")
    }

    public static func line(firstSync summary: Summary) -> String {
        "startup: first sync \(summary.total) ms (\(summary.screen))"
    }

    /// 시작부터 ms(음수·비정상 값은 0, 터무니없이 큰 값은 하루로 자른다 — 정수 변환이 넘치지 않게).
    private func elapsed(_ now: TimeInterval) -> Int {
        let seconds = now - origin
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((min(seconds, 86_400) * 1000).rounded())
    }

    /// 기록에 들어갈 이름: ASCII 글자·숫자·`_`·`-` 만, 24자까지. 남는 것이 없으면 `stage`.
    static func clean(_ name: String) -> String {
        let kept = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return kept.isEmpty ? "stage" : String(kept.prefix(24))
    }
}
