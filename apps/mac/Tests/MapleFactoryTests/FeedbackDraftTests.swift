import Foundation
import Testing
@testable import MapleFactory

@Suite struct FeedbackDraftTests {
    @Test func emptyOrWhitespaceMessageBlocksSend() {
        #expect(!FeedbackDraft().canSend)
        #expect(!FeedbackDraft(message: "  \n\t ").canSend)
        #expect(FeedbackDraft(message: "The board froze").canSend)
    }

    @Test func badEmailBlocksSendButNoEmailIsFine() {
        #expect(FeedbackDraft(message: "Hi", email: "").canSend)
        #expect(FeedbackDraft(message: "Hi", email: "   ").canSend)
        #expect(FeedbackDraft(message: "Hi", email: "me@example.com").canSend)
        #expect(FeedbackDraft(message: "Hi", email: " me@example.com ").replyEmail == "me@example.com")
        #expect(!FeedbackDraft(message: "Hi", email: "me@").canSend)
        #expect(!FeedbackDraft(message: "Hi", email: "not an email").canSend)
        #expect(FeedbackDraft(message: "Hi").replyEmail == nil)
    }

    @Test func sentryMessageCarriesTheKind() {
        #expect(FeedbackDraft(kind: .bug, message: " The board froze \n").sentryMessage == "[Bug] The board froze")
        #expect(FeedbackDraft(kind: .idea, message: "Dark icons").sentryMessage == "[Idea] Dark icons")
        #expect(FeedbackDraft(kind: .other, message: "Thanks").sentryMessage == "[Other] Thanks")
    }

    @Test func mailtoEncodesTheBodyAndVersion() throws {
        let url = FeedbackDraft(kind: .bug, message: "1+1 & a ?question").mailtoURL(version: "0.3.17", build: "417", screen: "goal.board")
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:\(FeedbackDraft.address)?"))
        #expect(!url.absoluteString.contains(" "))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.hasPrefix("1+1 & a ?question"))
        #expect(body.contains("Version: 0.3.17 (417)"))
        #expect(body.contains("Screen: goal.board"))
        #expect(body.contains("Kind: Bug"))
        #expect(items.first { $0.name == "subject" }?.value == "Maple Factory feedback: Bug")
        #expect(url.absoluteString.contains("1%2B1"))
    }

    @Test func paletteOffersSendFeedback() {
        let found = CommandPaletteModel.results(query: "feedback", tasks: [], goals: [], pages: [], actions: PaletteAction.allCases, me: "me")
        #expect(CommandPaletteModel.flatten(found).first == .action(.sendFeedback))
        let bug = CommandPaletteModel.results(query: "bug", tasks: [], goals: [], pages: [], actions: PaletteAction.allCases, me: "me")
        #expect(CommandPaletteModel.flatten(bug).contains(.action(.sendFeedback)))
    }
}
