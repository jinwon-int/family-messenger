// #398: 대화방이 최하단을 따라가야 하는지(순수 판정 — 뷰 밖에서 XCTest).
// 첨부 본체는 행이 보일 때 늦게 읽혀(#364/#367) 이미지로 바뀌며 행 높이가 커진다. 그 행이 마지막 몇 행 안에 있고
// 사용자가 위로 끌어 올리지 않았다면 다시 최하단으로 간다. 옛 사진을 보러 올라간 사람의 화면은 움직이지 않는다.
import Foundation

enum ScrollFollow {
    /// 늦게 커진 행이 이만큼 끝에 가까우면 최하단이 화면 밖으로 밀렸을 수 있다(마지막 행 + 그 위 두 행).
    static let tailRows = 3

    /// `loaded` 행이 `ids`(오래된 순)의 마지막 `tailRows` 안에 있고 `following` 이면 true.
    static func shouldRescroll(loaded: Int64, ids: [Int64], following: Bool) -> Bool {
        guard following, let index = ids.lastIndex(of: loaded) else { return false }
        return index >= ids.count - tailRows
    }
}
