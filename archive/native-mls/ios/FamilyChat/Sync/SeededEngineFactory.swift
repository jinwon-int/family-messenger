// identity 슬롯 ↔ 방별 MLS 상태 시드 (파이널라이저 결정 D2, NOTES-FINALIZER.md).
//
// 파사드 `Device` 하나 = 서명키 1개 + 그룹 0..1개라 방마다 상태 파일이 따로 있다(봇·relay-app 과 같음).
// L3 `RoomSyncEngine` 은 방 상태가 없으면 `create(identity:)` 를 부르는데, 그대로 두면 방마다 새 서명키가 생겨
// 정책 체인에 등록한 키(기기당 1개)·지문·`sign_approval`·`remove_pending` 이 두 번째 방부터 어긋난다.
// 그래서 "새 방 상태" = `_identity` 슬롯의 export 바이트를 import 한 것으로 바꾼다. 슬롯에는 그룹도 키 패키지도 없으므로
// (슬롯에서는 `key_package`·`create` 를 하지 않는다) 개인 init 키가 방들로 복제되지 않는다.
import Foundation
import FamilyMLSCore

struct SeededEngineFactory: MlsEngineFactory {
    let base: MlsEngineFactory
    /// `_identity` 슬롯의 export_state 바이트(평문 — 봉인은 저장소 몫).
    let seed: () throws -> Data

    func create(identity: DeviceID) throws -> MlsEngine {
        // 파사드가 identity 를 바이트에 박아 두고 import 때 재검사하므로 다른 기기의 시드는 거부된다.
        try base.importState(identity: identity, bytes: try seed())
    }

    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine {
        try base.importState(identity: identity, bytes: bytes)
    }
}
