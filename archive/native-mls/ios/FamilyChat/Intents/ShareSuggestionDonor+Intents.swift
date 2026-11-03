// #666 공유 시트 맨 윗줄 대화 추천 — `INSendMessageIntent` 기부(Apple 전용, Linux 스모크 복사 대상 아님).
//
// iOS 는 앱이 기부한 메시지 보내기 의도를 공유 시트 맨 윗줄 "사람/대화" 칸에 올리고, 누르면 그 앱의 공유 확장을
// `extensionContext.intent` 에 같은 의도를 실어 연다(확장 `Info.plist` `IntentsSupported` = INSendMessageIntent).
// 받는 쪽 `recipients` 는 방을 나타내는 가짜 사람 1명 — 이름은 화면과 같은 방 이름, 사진·연락처 없음.
// 식별자 규칙·거르기는 Core `ShareSuggestions`(스코프/방).
import Foundation
import Intents
import FamilyMLSCore

extension ShareSuggestionDonor {
    static var live: ShareSuggestionDonor {
        ShareSuggestionDonor(
            donate: { conversation, title in
                let handle = INPersonHandle(value: conversation, type: .unknown)
                let room = INPerson(personHandle: handle, nameComponents: nil, displayName: title, image: nil,
                                    contactIdentifier: nil, customIdentifier: conversation)
                let intent = INSendMessageIntent(recipients: [room], outgoingMessageType: .outgoingMessageText, content: nil,
                                                 speakableGroupName: INSpeakableString(spokenPhrase: title),
                                                 conversationIdentifier: conversation, serviceName: "한데", sender: nil, attachments: nil)
                let interaction = INInteraction(intent: intent, response: nil)
                interaction.groupIdentifier = conversation
                interaction.direction = .outgoing
                interaction.donate(completion: nil)
            },
            delete: { conversations in
                for conversation in conversations { INInteraction.delete(with: conversation, completion: nil) }
            },
            deleteAll: { INInteraction.deleteAll(completion: nil) })
    }
}
