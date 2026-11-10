import Foundation
import Testing
@testable import MapleFactory

/// MF-401: a send that can't leave the Mac is a known outcome. It's refused out loud, the composer keeps its
/// brief, spinners don't start, and the main window's pill follows the reconnect.
@MainActor struct OfflineSendTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    /// Signed in, snapshot landed, then the feed dropped: no socket, status reconnecting.
    private func offlineClient() throws -> FactoryClient {
        let client = FactoryClient()
        client._signInForTesting()
        let task = { (id: String, state: String) in
            """
            {"id":"\(id)","goal":"g","title":"Task \(id)","state":"\(state)","owner":"alice","brief":"",
             "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":1,"reviewsNeeded":0,"shareable":false,"agent":"claude"}
            """
        }
        client.apply(try decode(#"""
        {"type":"snapshot","org":"acme","protocolVersion":2,
         "me":{"login":"afomera","role":"member","teams":[]},
         "members":[{"login":"alice","role":"admin","teams":[]}],
         "machines":[],"ended":[],
         "goals":[{"id":"g","name":"Goal","prefix":"MF","color":"#14B8A6","summary":"","lead":"alice","repos":[]}],
         "tasks":[\#(task("MF-1", "awaitingApproval")),\#(task("MF-2", "reviewing"))],
         "acceptances":[],"online":[],"notes":[],"follows":[],"intake":[],"repos":[],"secrets":[],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}}}
        """#))
        client._setStatusForTesting(.reconnecting(attempt: 2, reason: "Could not connect to the server."))
        return client
    }

    private func offlineState() throws -> (AppState, FactoryClient) {
        let client = try offlineClient()
        let state = AppState()
        state.client = client
        #expect(state.isLive)
        return (state, client)
    }

    @Test func sendWithoutASocketSaysItDidntGo() {
        let client = FactoryClient()
        #expect(!client.canSend)
        #expect(!client.send(.taskMerge(.init(id: "MF-1"))))
    }

    @Test func aRefusedActionCallsOnRefusedButBackgroundReadsStaySilent() throws {
        let client = try offlineClient()
        var refused: [Wire.ClientMessage] = []
        client.onRefused = { refused.append($0) }
        #expect(!client.send(.taskComment(.init(id: "MF-1", text: "hi", replyTo: nil))))
        #expect(!client.send(.taskGet(.init(id: "MF-9"))))
        #expect(refused.count == 1)
    }

    @Test func backgroundFetchesDontStayLoading() throws {
        let client = try offlineClient()
        client.fetchTask(id: "MF-99")
        #expect(!client.fetching.contains("MF-99"))
    }

    @Test func reconnectingSinceIsSetOnceAndClearedOnLive() throws {
        let client = try offlineClient()
        let since = try #require(client.reconnectingSince)
        client._setStatusForTesting(.reconnecting(attempt: 3, reason: "again"))
        #expect(client.reconnectingSince == since)
        client._setStatusForTesting(.live)
        #expect(client.reconnectingSince == nil)
    }

    @Test func composerKeepsItsDraftWhenTaskCreateCantGo() throws {
        let (state, _) = try offlineState()
        state.isComposing = true
        state.draft.goal = "Goal"
        state.draft.title = "Offline brief"
        state.draft.body = "Written on a plane"
        state.submitDraft(sendToPlanning: true)
        #expect(state.isComposing)
        #expect(state.draft.title == "Offline brief")
        #expect(state.draft.body == "Written on a plane")
        #expect(state.toast?.text == AppState.offlineToast)
        #expect(state.toast?.text != "Sent to planning")
    }

    /// MF-404: the refused brief is still the unsent draft, kept for a relaunch.
    @Test func aRefusedSendKeepsTheStoredDraft() throws {
        let (state, _) = try offlineState()
        state.taskGoalDefaults = UserDefaults(suiteName: "OfflineSendTests.\(UUID().uuidString)")!
        state.isComposing = true
        state.draft.goal = "Goal"
        state.draft.title = "Offline brief"
        state.submitDraft(sendToPlanning: true)
        #expect(state.draft.title == "Offline brief")
        let key = try #require(state.unsentDraftKey)
        #expect(UnsentDraft.load(key: key, defaults: state.taskGoalDefaults)?.title == "Offline brief")
    }

    @Test func approveAndMergeFailFastOffline() throws {
        let (state, _) = try offlineState()
        state.approvePlan("MF-1")
        #expect(state.inFlight["MF-1"] == nil)
        #expect(state.toast?.text == AppState.offlineToast)
        state.toast = nil
        state.merge("MF-2")
        #expect(state.inFlight["MF-2"] == nil)
        #expect(state.toast?.text == AppState.offlineToast)
        state.toast = nil
        state.holdMerge("MF-2")
        #expect(state.inFlight["MF-2"] == nil)
        #expect(state.toast?.text == AppState.offlineToast)
    }

    @Test func bannerWaitsForTheReconnectDelayAndClearsOnLive() {
        let since = Date(timeIntervalSince1970: 1000)
        let reconnecting = FactoryClient.Status.reconnecting(attempt: 1, reason: "x")
        #expect(ConnectionBanner.visible(status: reconnecting, since: since, now: since.addingTimeInterval(1)) == nil)
        #expect(ConnectionBanner.visible(status: reconnecting, since: since, now: since.addingTimeInterval(4)) == .offline)
        #expect(ConnectionBanner.visible(status: .tooNew, since: nil, now: since) == .updateNeeded)
        #expect(ConnectionBanner.visible(status: .live, since: since, now: since.addingTimeInterval(60)) == nil)
        #expect(ConnectionBanner.visible(status: .connecting, since: since, now: since.addingTimeInterval(60)) == nil)
    }
}
