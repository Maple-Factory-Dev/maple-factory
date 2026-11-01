import CryptoKit
import Foundation
import MapleKit
import Observation
import UIKit

/// The iPhone app's factory: who you're signed in as, where, and the feed's state. Opens the same
/// `/client/connect` socket as the Mac app, applies what it says to a FeedState (MapleKit), and
/// sends the actions a phone can take.
@MainActor @Observable
final class FactoryStore {
    enum Status: Equatable {
        case signedOut, connecting, live, demo
        case reconnecting(attempt: Int, reason: String)
        case tooNew
    }

    private(set) var status: Status = .signedOut
    private(set) var feed = FeedState()
    private(set) var server: URL?
    private(set) var token: String?
    private(set) var saved: [SavedFactory] = []
    /// The toast or error to show, newest only.
    var notice: FeedState.Notice?
    /// A `maplefactory://` link waiting to be opened. Signing out keeps it, so a link opened on the
    /// sign-in screen opens once you're in; RootView takes it.
    var pendingLink: FactoryLink?
    /// Each task's diff once loaded, keyed by the change it was loaded for.
    private(set) var diffs: [String: (key: String, files: [DiffFile])] = [:]
    /// Each task's draft review: single-line notes on its diff, sent together as one `task.review`.
    private(set) var reviewNotes: [String: [Wire.ReviewNote]] = [:]
    /// The last `stats` reply, for admins' Statistics (FeedState doesn't keep it).
    private(set) var stats: Wire.StatsSummary?
    /// CI check logs asked for (`task.checkLog`), keyed `<task>/<check>`. The server never broadcasts or keeps them.
    private(set) var checkLogs: [String: CheckLogLoad] = [:]
    /// The goal sent with `goal.save` (GoalEditorSheet): waiting on the server, kept, or refused.
    private(set) var goalSave: GoalSave?

    /// A goal save's progress. While saving, the goal.updated for it (its id, or a new goal's prefix and
    /// name) makes it `.saved`; an error makes it `.failed`, shown in the sheet rather than as a notice.
    enum GoalSave: Equatable {
        case saving(id: String, prefix: String, name: String)
        case saved(id: String)
        case failed(String)
    }

    /// A check log: on its way, there, or refused (expired, or a check from outside GitHub).
    enum CheckLogLoad: Equatable {
        case loading
        case loaded(text: String, truncated: Bool, failedStep: String?, url: URL?)
        case failed(String)
    }

    // MARK: Push (PushNotifications.swift, MF-272)

    enum NotificationStatus: Equatable { case notAsked, allowed, off }

    /// This phone's APNs token (hex) and its environment, once iOS hands it over.
    private(set) var pushToken: String?
    private(set) var pushEnvironment: Wire.PushEnvironment = AppDelegate.environment
    /// The id the factory shows for this phone's token (server/src/push.ts deviceId).
    private(set) var pushDeviceID: String?
    /// Why iOS gave no token (a simulator, or no entitlement).
    var pushError: String?
    /// Your phones registered with this factory (`push.devices`).
    private(set) var pushDevices: [Wire.PushDevice] = []
    /// Your quiet hours, from the snapshot and `quietHours.updated`.
    private(set) var quietHours: Wire.QuietHours?
    var notificationStatus: NotificationStatus = .notAsked
    /// The task whose detail is on screen, so its own notification needn't show a banner.
    var visibleTask: String?
    /// Asks iOS for permission and a token; called when a real factory goes live (AppDelegate sets it).
    @ObservationIgnored var askForPush: (() -> Void)?

    nonisolated static func checkLogKey(task: String, check: String) -> String { "\(task)/\(check)" }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: Keychain

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keychain = Keychain(service: "dev.maplefactory.ios", defaults: defaults)
        saved = SavedFactories.load(defaults) ?? []
    }

    var isSignedIn: Bool { status != .signedOut }
    var me: String { feed.me?.login ?? "" }
    var isAdmin: Bool { feed.me?.role == "admin" }
    var factoryName: String { feed.name ?? (feed.org.isEmpty ? server?.host() ?? "Factory" : feed.org) }

    // MARK: Signing in

    /// Opens the most recently used saved factory, if its token is still here.
    func restore() {
        guard let factory = SavedFactories.fallback(saved), let token = keychain.read(account: factory.server.absoluteString) else { return }
        open(factory.server, token: token)
    }

    func signedIn(_ result: FactoryAPI.SignInResult) {
        keychain.write(result.token, account: result.server.absoluteString)
        let name = result.org.isEmpty || result.org == "local" ? result.server.host() ?? "Factory" : result.org
        saved = SavedFactories.upsert(SavedFactory(server: result.server, org: result.org, name: name, lastUsed: Date()), into: saved)
        SavedFactories.store(saved, defaults)
        open(result.server, token: result.token)
    }

    /// Switches to another saved factory.
    func switchTo(_ factory: SavedFactory) {
        guard let token = keychain.read(account: factory.server.absoluteString) else { return }
        unregisterPush()
        var factory = factory
        factory.lastUsed = Date()
        saved = SavedFactories.upsert(factory, into: saved)
        SavedFactories.store(saved, defaults)
        open(factory.server, token: token)
    }

    func signOut() {
        unregisterPush()
        if let server {
            keychain.delete(account: server.absoluteString)
            saved = SavedFactories.remove(server, from: saved)
            SavedFactories.store(saved, defaults)
        }
        close()
        if let next = SavedFactories.fallback(saved) { switchTo(next) }
    }

    /// Leaves the demo, or the factory, for the sign-in screen.
    func close() {
        disconnect()
        generation += 1
        server = nil
        token = nil
        feed = FeedState()
        diffs = [:]
        stats = nil
        goalSave = nil
        pushDevices = []
        quietHours = nil
        status = .signedOut
    }

    private func open(_ server: URL, token: String) {
        close()
        self.server = server
        self.token = token
        connect()
    }

    /// A local dev server's sign-in (`/dev/token`); `-devAs <login>` signs in as that member instead.
    static func devSignIn(_ server: URL) async throws -> FactoryAPI.SignInResult {
        var url = server.appending(path: "/dev/token")
        if let login = UserDefaults.standard.string(forKey: "devAs"), !login.isEmpty { url.append(queryItems: [URLQueryItem(name: "as", value: login)]) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var result: FactoryAPI.SignInResult = try await FactoryAPI.load(request)
        result.server = server
        return result
    }

    static var deviceLabel: String { UIDevice.current.name }

    // MARK: Feed

    func connect() {
        guard let server, let token else { return }
        disconnect()
        generation += 1
        let gen = generation
        if status != .live { status = attempt == 0 ? .connecting : status }
        var request = URLRequest(url: FactoryAPI.websocketURL(server, path: "/client/connect"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Teammates see a phone badge for someone who's only on a phone.
        request.setValue("mobile", forHTTPHeaderField: "x-maple-client")
        let socket = URLSession.shared.webSocketTask(with: request)
        // The default 1 MiB is less than a big factory's snapshot ("Message too long"), as on the Mac.
        socket.maximumMessageSize = 64 << 20
        self.socket = socket
        socket.resume()
        send(.subscribe)
        Task { await receive(socket, gen: gen) }
        Task { await keepAlive(socket, gen: gen) }
    }

    /// Pull to refresh: a fresh socket, so a fresh snapshot.
    func refresh() async {
        guard status != .demo, server != nil else { return }
        attempt = 0
        connect()
        for _ in 0..<30 where status != .live { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        let decoder = JSONDecoder()
        while gen == generation {
            do {
                let message = try await socket.receive()
                // A socket left open to finish its push.unregister (unregisterPush) mustn't feed the next factory.
                guard gen == generation else { return }
                guard case .string(let text) = message else { continue }
                apply(try decoder.decode(Wire.ServerToClient.self, from: Data(text.utf8)))
            } catch {
                guard gen == generation else { return }
                if error is DecodingError {
                    NSLog("Maple Factory: can't read the factory's message: \(error)")
                    disconnect()
                    status = .tooNew
                    return
                }
                if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                    signOut()
                    notice = .error("Your sign-in expired.")
                    return
                }
                retry(reason: FactoryAPI.describe(error, response: socket.response))
                return
            }
        }
    }

    /// Pings keep proxies from dropping a quiet socket.
    private func keepAlive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            try? await Task.sleep(for: .seconds(20))
            guard gen == generation else { return }
            socket.sendPing { _ in }
        }
    }

    /// Tries again after 2, 4, 8… seconds, at most 30.
    private func retry(reason: String) {
        attempt += 1
        status = .reconnecting(attempt: attempt, reason: reason)
        let delay = min(pow(2, Double(min(attempt, 5))), 30)
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if gen == generation { connect() }
        }
    }

    /// One message from the feed.
    func apply(_ message: Wire.ServerToClient) {
        if case .snapshot(let snapshot) = message {
            attempt = 0
            status = .live
            ErrorReports.tag(org: snapshot.org)
            quietHours = snapshot.quietHours
            // Register again on every snapshot (the token can change, and it keeps lastSeen fresh); the
            // reply is push.devices. With no token yet, still ask, for the other phones' list.
            if let pushToken {
                send(.pushRegister(.init(platform: .apns, token: pushToken, environment: pushEnvironment)))
            } else {
                send(.pushDevices)
                askForPush?()
            }
        }
        if case .pushDevices(let reply) = message { pushDevices = reply.devices }
        if case .quietHoursUpdated(let update) = message { quietHours = update.quietHours }
        if case .stats(let reply) = message { stats = reply.summary }
        if case .checkLog(let reply) = message {
            // Only one still asked for: a log forgotten by a re-run stays forgotten.
            let key = Self.checkLogKey(task: reply.id, check: reply.check)
            if checkLogs[key] == .loading {
                checkLogs[key] = .loaded(text: reply.text, truncated: reply.truncated, failedStep: reply.failedStep, url: reply.url.flatMap(URL.init(string:)))
            }
        }
        // A log that couldn't be read says which one (`checkLog:<task>/<check>`) and shows in its sheet, not as an error notice.
        if case .error(let error) = message, let id = error.requestId, id.hasPrefix("checkLog:") {
            let key = String(id.dropFirst("checkLog:".count))
            if checkLogs[key] == .loading { checkLogs[key] = .failed(error.message) }
            return
        }
        if case .saving(let id, let prefix, let name) = goalSave {
            if case .goalUpdated(let update) = message, id.isEmpty ? update.goal.prefix == prefix && update.goal.name == name : update.goal.id == id {
                goalSave = .saved(id: update.goal.id)
            } else if case .error(let error) = message, !(error.requestId ?? "").contains(":") {
                // Not a task.get or a check log's: the server refusing the goal (a prefix in use).
                goalSave = .failed(error.message)
                return
            }
        }
        if let notice = feed.apply(message) { self.notice = notice }
    }

    /// The next page of the goal's finished tasks older than the snapshot's 14 days.
    func loadOlder(goal: String) {
        if let request = feed.olderRequest(goal: goal) { send(request) }
    }

    /// A task opened by ID that isn't loaded (the snapshot leaves out ones finished over 14 days ago).
    func fetchTask(_ id: String) {
        guard status == .live, let request = feed.fetchRequest(id: id) else { return }
        send(request)
    }

    func send(_ message: Wire.ClientMessage) {
        if status == .demo { return demoSend(message) }
        guard let socket, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Push

    /// The token iOS handed over: registered now if a factory is live, else with the next snapshot.
    func registerPush(token: String, environment: Wire.PushEnvironment) {
        pushToken = token
        pushEnvironment = environment
        pushError = nil
        pushDeviceID = Self.pushDeviceID(token)
        if status == .live { send(.pushRegister(.init(platform: .apns, token: token, environment: environment))) }
    }

    /// server/src/push.ts deviceId: the first 16 hex digits of sha256("push-device\n" + token).
    nonisolated static func pushDeviceID(_ token: String) -> String {
        SHA256.hash(data: Data("push-device\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Before leaving a factory (sign-out, switching): tells it to stop pushing to this phone. The old
    /// socket stays open until the frame is sent, then closes; its replies are ignored (receive's gen check).
    private func unregisterPush() {
        guard status == .live, let pushToken, let socket,
              let data = try? JSONEncoder().encode(Wire.ClientMessage.pushUnregister(.init(token: pushToken))),
              let text = String(data: data, encoding: .utf8) else { return }
        self.socket = nil
        socket.send(.string(text)) { _ in socket.cancel(with: .goingAway, reason: nil) }
    }

    /// Settings' Notifications row: Off without permission, Quiet now inside quiet hours, else On.
    var pushSummary: String {
        if notificationStatus != .allowed { return "Off" }
        return quietHours?.isQuiet(at: Date()) == true ? "Quiet now" : "On"
    }

    /// Removes one of your other phones, by its id.
    func removePushDevice(_ id: String) {
        pushDevices.removeAll { $0.id == id }
        send(.pushUnregister(.init(id: id)))
    }

    /// Sets your quiet hours (nil: none) on every device; the server answers quietHours.updated.
    func setQuietHours(_ schedule: Wire.QuietHours?) {
        quietHours = schedule
        send(.quietHoursSet(.init(quietHours: schedule)))
    }

    // MARK: Actions

    func approvePlan(_ id: String) { send(.taskApprovePlan(.init(id: id))) }
    func approveChanges(_ id: String) { send(.taskApproveChanges(.init(id: id))) }
    func merge(_ id: String) { send(.taskMerge(.init(id: id))) }
    func holdMerge(_ id: String) { send(.taskHoldMerge(.init(id: id))) }
    func answer(_ id: String, text: String) { send(.taskAnswer(.init(id: id, text: text))) }
    func resolveHand(_ id: String, option: String?, note: String) { send(.taskResolveHand(.init(id: id, option: option, note: note))) }
    func comment(_ id: String, text: String) { send(.taskComment(.init(id: id, text: text))) }
    func steer(_ id: String, text: String) { send(.taskSteer(.init(id: id, text: text))) }
    /// Answers the permission prompt the task's worker is waiting on: Yes or No in its session.
    func answerPrompt(_ id: String, choice: Wire.PromptChoice) { send(.taskAnswerPrompt(.init(id: id, choice: choice))) }
    /// Signs off a Done when item yourself (index from 0), with an optional note on why.
    func checkedIt(_ id: String, item: Int, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.taskCheckedIt(.init(id: id, item: UInt32(item), note: note.isEmpty ? nil : note)))
    }
    /// Asks the planner to change one of its mockups.
    func requestMockupChange(_ id: String, mockup: String, text: String) { send(.taskMockupChange(.init(id: id, mockup: mockup, text: text))) }
    /// One more automated-review round on a task in review, looking first at `focus`.
    func requestReview(_ id: String, focus: String) {
        let focus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !focus.isEmpty else { return }
        send(.taskRequestReview(.init(id: id, focus: focus)))
    }
    /// Turns review findings (or a note) into draft follow-up tasks in the task's goal.
    func followUp(_ id: String, items: [Wire.FollowUpItem]) {
        guard !items.isEmpty else { return }
        send(.taskFollowUp(.init(id: id, items: Array(items.prefix(Self.maxFollowUps)))))
    }
    /// Keeps a note on one diff line in the task's draft review: a removed line is numbered on the old
    /// side, any other on the new; the snippet is the line as the diff shows it, with its prefix.
    func addReviewNote(task id: String, path: String, line: DiffLine, text: String) {
        guard let note = Self.reviewNote(path: path, line: line, text: text) else { return }
        reviewNotes[id, default: []].append(note)
    }

    func removeReviewNote(task id: String, at index: Int) {
        guard reviewNotes[id]?.indices.contains(index) == true else { return }
        reviewNotes[id]?.remove(at: index)
        if reviewNotes[id]?.isEmpty == true { reviewNotes[id] = nil }
    }

    /// Sends the draft as one review: each note a comment, the batch one change request for the builder.
    func submitReview(_ id: String) {
        guard let notes = reviewNotes[id], !notes.isEmpty else { return }
        send(.taskReview(.init(id: id, notes: notes, summary: nil)))
        reviewNotes[id] = nil
        notice = .toast("Review sent: \(notes.count) comment\(notes.count == 1 ? "" : "s")", taskId: id)
    }

    static func reviewNote(path: String, line: DiffLine, text: String) -> Wire.ReviewNote? {
        let side: Wire.DiffSide = line.kind == .removed ? .old : .new
        guard let number = (side == .old ? line.old : line.new) else { return nil }
        let prefix = line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
        return .init(path: path, start: UInt32(number), end: UInt32(number), side: side, snippet: prefix + line.text, text: text)
    }

    /// Where a note sits, as the Mac's DiffReview anchors it: `path:L12`.
    static func anchor(_ note: Wire.ReviewNote) -> String { "\(note.path):L\(note.start)" }

    func retryTask(_ id: String) {
        send(.taskRetry(.init(id: id)))
        notice = .toast("Retrying \(id)", taskId: id)
    }

    /// Reads the task's pull request and CI from GitHub again, for a webhook that never came.
    func recheckGitHub(_ id: String) {
        send(.taskRecheckGitHub(.init(id: id)))
        notice = .toast("Checking GitHub…", taskId: id)
    }

    /// Splits the task into `parts`: it keeps its first steps, the rest become new tasks for planning.
    func split(_ id: String, into parts: Int) {
        send(.taskSplit(.init(id: id, parts: UInt32(parts))))
        notice = .toast("Splitting \(id) into \(parts) tasks; the new ones go to planning", taskId: id)
    }

    /// How many parts the PR budget suggests for the task (the Mac's RiskModel.suggestedSplit): none
    /// while its footprint fits the policy's files and lines.
    func suggestedSplit(_ task: Wire.Task) -> Int? {
        guard let footprint = task.footprint, let policy = feed.policy, policy.maxFiles > 0, policy.maxLines > 0,
              footprint.files > policy.maxFiles || footprint.lines > policy.maxLines else { return nil }
        return max(Int((Double(footprint.files) / Double(policy.maxFiles)).rounded(.up)),
                   Int((Double(footprint.lines) / Double(policy.maxLines)).rounded(.up)))
    }

    /// Which plan steps a split into `parts` gives each task, as the factory splits it: the original
    /// keeps up to its current step (at least one), the rest spread over the new ones.
    static func splitSteps(_ plan: [Wire.PlanStep], parts: Int) -> [[Wire.PlanStep]] {
        guard parts > 1, plan.count >= parts else { return [plan] }
        let firstEnd = max(plan.firstIndex { $0.progress == .active } ?? (plan.count / parts - 1), 0)
        let rest = Array(plan[(firstEnd + 1)...])
        let perPart = max(Int((Double(rest.count) / Double(parts - 1)).rounded(.up)), 1)
        let chunks = stride(from: 0, to: rest.count, by: perPart).map { Array(rest[$0..<min($0 + perPart, rest.count)]) }
        return [Array(plan[...firstEnd])] + chunks
    }

    /// Reads a CI check's log from GitHub (again); the answer, or a refusal, lands in `checkLogs`.
    func loadCheckLog(task id: String, check: String) {
        checkLogs[Self.checkLogKey(task: id, check: check)] = .loading
        send(.taskCheckLog(.init(id: id, check: check)))
    }

    func checkLog(task id: String, check: String) -> CheckLogLoad {
        checkLogs[Self.checkLogKey(task: id, check: check)] ?? .loading
    }

    /// Runs one of the pull request's checks again; its old log no longer applies.
    func rerunCheck(_ id: String, check: String) {
        checkLogs[Self.checkLogKey(task: id, check: check)] = nil
        send(.taskRerunCheck(.init(id: id, check: check)))
        notice = .toast("Running \(check) again", taskId: id)
    }

    /// Runs every failed check on the pull request again.
    func rerunFailedChecks(_ id: String) {
        for check in feed.task(id)?.pr?.checks ?? [] where check.status == .failed {
            checkLogs[Self.checkLogKey(task: id, check: check.name)] = nil
        }
        send(.taskRerunChecks(.init(id: id)))
        notice = .toast("Running \(id)'s failed checks again", taskId: id)
    }

    /// A finished check on a pull request that's still open, as the Mac decides it.
    static func canRerun(_ check: Wire.CICheck, pr: Wire.PullRequest) -> Bool {
        (check.status == .failed || check.status == .passed) && (pr.state == .open || pr.state == .draft) && pr.url != nil
    }

    /// The check's own run, or the pull request's Checks tab when the server didn't say.
    static func githubURL(_ check: Wire.CICheck, pr: Wire.PullRequest) -> URL? {
        check.url.flatMap(URL.init(string:)) ?? pr.url.flatMap { URL(string: $0)?.appending(path: "checks") }
    }
    func cancel(_ id: String) {
        send(.taskCancel(.init(id: id)))
        notice = .toast("Cancelled \(id)", taskId: id)
    }

    /// Sends a draft to planning, or picks up a backlog task.
    func plan(_ id: String) { send(.taskPlan(.init(id: id))) }
    /// Parks a draft (or a plan waiting for approval) in the backlog.
    func sendToBacklog(_ id: String) { send(.taskBacklog(.init(id: id))) }
    /// Moves a draft ahead of `before` ("top": first; nil: last) in its goal's drafts.
    func rankDraft(_ id: String, before: String?) { send(.taskRankDraft(.init(id: id, before: before))) }

    // MARK: Task actions (the … menu)

    /// Whether you can give `task` to someone else: its owner or an admin can. Anyone can take a task over.
    func canReassign(_ task: Wire.Task) -> Bool { task.owner == me || isAdmin }

    /// Makes `login` the task's owner: its next sessions prefer their machines, and its open hand is theirs.
    func assign(_ id: String, to login: String) {
        guard let task = feed.task(id), task.owner != login else { return }
        send(.taskAssign(.init(id: id, owner: login)))
        notice = .toast(login == me ? "You took over \(id)" : "Gave \(id) to \(feed.member(login)?.name ?? login)", taskId: id)
    }

    /// A new title and brief, trimmed; only what changed is sent, and an empty title is ignored.
    func edit(_ id: String, title: String, brief: String) {
        guard let task = feed.task(id) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = !title.isEmpty && title != task.title ? title : nil
        let newBrief = brief != task.brief.trimmingCharacters(in: .whitespacesAndNewlines) ? brief : nil
        guard newTitle != nil || newBrief != nil else { return }
        send(.taskEdit(.init(id: id, title: newTitle, brief: newBrief, shareable: nil)))
        notice = .toast("Saved \(id)", taskId: id)
    }

    /// The goals `task` can move to (unarchived, not its own), each with why it can't when that goal doesn't work in the task's repo.
    func moveTargets(_ task: Wire.Task) -> [(goal: Wire.Goal, blocked: String?)] {
        let from = feed.goal(task.goal)
        let repo = task.repo ?? from?.repo
        return feed.goals.filter { $0.archived != true && $0.id != task.goal }.map { goal in
            let repos = ([goal.repo].compactMap { $0 } + goal.repos).map { $0.lowercased() }
            if let repo { return (goal, repos.contains(repo.lowercased()) ? nil : "doesn't work in \(repo)") }
            // A goal on a folder: only to another goal on the same folder.
            let folder = from?.folder
            let named = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "its folder"
            return (goal, repos.isEmpty && folder != nil && goal.folder == folder ? nil : "doesn't work in \(named)")
        }
    }

    /// Puts the task in effort `name` (whitespace collapsed), or takes it out when `name` is nil or
    /// empty; nothing is sent when it's already there. The wire's `task.edit` clears it on an empty string.
    func setEffort(_ id: String, _ name: String?) {
        guard let task = feed.task(id) else { return }
        let name = name?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        let was = task.effort ?? ""
        guard name != was else { return }
        send(.taskEdit(.init(id: id, effort: name)))
        notice = .toast(name.isEmpty ? "Took \(id) out of \(was)" : "Put \(id) in \(name)", taskId: id)
    }

    /// Every task in `goal` that's part of `effort`, in feed order: the Effort card's rows.
    func tasks(inEffort effort: String, goal: String) -> [Wire.Task] {
        feed.tasks(in: goal).filter { $0.effort == effort }
    }

    /// Moves a task to another goal; it keeps its id, branch and pull request.
    func moveGoal(_ id: String, to goal: Wire.Goal) {
        guard feed.task(id)?.goal != goal.id else { return }
        send(.taskMoveGoal(.init(id: id, goal: goal.id)))
        notice = .toast("Moved \(id) to \(goal.name)", taskId: id)
    }

    /// To the front of the queue, or the back.
    func queueTop(_ id: String) {
        send(.taskQueue(.init(id: id, before: "top")))
        notice = .toast("Moved \(id) to the top", taskId: id)
    }

    func queueBottom(_ id: String) {
        send(.taskQueue(.init(id: id, before: nil)))
        notice = .toast("Moved \(id) to the bottom", taskId: id)
    }

    func follow(_ goal: String, _ following: Bool) { send(.goalFollow(.init(id: goal, following: following))) }
    /// Asks for the factory's statistics over the last `days`; the reply lands in `stats`.
    func loadStats(days: Int) { send(.statsGet(.init(days: UInt32(days), goal: nil))) }

    /// Starts a task in `goal`: handed to a planner now (`plan`), or kept as a draft. An empty brief
    /// sends the title as the brief, like the Mac's composer; `repo` counts only when it's one of the goal's.
    /// `attachments` go at the end of the brief as links (inline images for pictures), the way the Mac's
    /// composer puts a pasted file in; `agent` and `effort` ride along in `task.create`.
    func createTask(goal: Wire.Goal, title: String, brief: String, repo: String?, priority: Wire.Priority?, plan: Bool,
                    agent: String? = nil, effort: String? = nil, attachments: [Attachment] = []) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let brief = Self.brief(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : brief, attachments: attachments)
        let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.taskCreate(.init(goal: goal.id, title: title, brief: brief, shareable: false, plan: plan, agent: agent,
                               repo: repo.flatMap { goal.repos.contains($0) ? $0 : nil },
                               effort: effort?.isEmpty == false ? effort : nil, priority: priority)))
        notice = .toast(plan ? "Sent to planning" : "Saved as a draft", taskId: nil)
    }

    /// The brief with each attachment linked on a line of its own at the end: `![name](path)` for an image.
    static func brief(_ text: String, attachments: [Attachment]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return text }
        let links = attachments.map { "\($0.mime.hasPrefix("image/") ? "!" : "")[\($0.name)](\($0.path))" }
        return text + "\n\n" + links.joined(separator: "\n")
    }

    /// The agents the factory's machines can run, as their health reports it: Claude Code first, then
    /// Codex, then the rest (the Mac's `liveAgents`). Claude Code is always there, as the default.
    var agents: [String] {
        let installed = Set(feed.machines.flatMap { $0.health?.agents.map(\.name) ?? [] })
        return ["claude", "codex"].filter { installed.contains($0) || $0 == "claude" } + installed.subtracting(["claude", "codex"]).sorted()
    }

    /// The efforts the goal's tasks are grouped under, sorted: what a new task can join.
    func efforts(in goal: Wire.Goal) -> [String] {
        Set(feed.tasks(in: goal.id).compactMap { $0.effort?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).sorted()
    }

    // MARK: Attachments

    /// A file stored by the factory for a brief or note (`POST /api/attachments`), as the Mac's FactoryClient has it.
    struct Attachment: Decodable, Hashable, Sendable {
        let id: String
        let name: String
        let mime: String
        let size: Int
        /// `/attachments/<id>/<name>`: what the brief links to.
        let path: String
    }

    /// The factory's limit for one attachment.
    static let maxAttachment = 25 * 1024 * 1024

    enum UploadError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let text): text } }
    }

    /// Uploads a photo or file for a brief. The demo stores nothing and hands back a made-up path,
    /// so the UI tests run with no server.
    func upload(data: Data, filename: String, mime: String) async throws -> Attachment {
        guard data.count <= Self.maxAttachment else { throw UploadError.message("It's over 25 MB.") }
        if status == .demo {
            // `-demoUploadHang IMG-` keeps the files named that way uploading, for a screenshot of the spinner.
            let hang = UserDefaults.standard.string(forKey: "demoUploadHang").map { !$0.isEmpty && filename.hasPrefix($0) } ?? false
            try await Task.sleep(for: .seconds(hang ? 3600 : 0.4))
            let id = "demo"
            return Attachment(id: id, name: filename, mime: mime, size: data.count, path: "/attachments/\(id)/\(filename)")
        }
        guard let server, let token else { throw UploadError.message("Not signed in.") }
        var components = URLComponents(url: server.appending(path: "/api/attachments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "name", value: filename)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let reason = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            throw UploadError.message(reason ?? "The factory said \(code).")
        }
        return try JSONDecoder().decode(Attachment.self, from: body)
    }

    // MARK: Goals

    /// The goal's lead or an admin: who the server lets change its auto-merge or archive it.
    func canLead(_ goal: Wire.Goal) -> Bool { feed.canLead(goal, me: feed.me) }

    /// Sends the goal as GoalEditorView.save() on the Mac does; GoalEditorSheet waits on `goalSave`.
    func saveGoal(_ goal: Wire.Goal) {
        goalSave = .saving(id: goal.id, prefix: goal.prefix, name: goal.name)
        send(.goalSave(.init(goal: goal)))
    }

    /// The sheet's done with it: closed, or gave up waiting (`failure` says why).
    func endGoalSave(failure: String? = nil) { goalSave = failure.map { .failed($0) } }

    /// Lets the factory auto-merge the goal's work up to `upTo`, on the record; nil takes it back.
    func acceptRisk(goal: Wire.Goal, upTo: Wire.RiskLevel?) {
        send(.goalAcceptRisk(.init(goal: goal.id, upTo: upTo, note: nil)))
        notice = .toast(upTo.map { "You accepted up to \($0.rawValue) for \(goal.name)" } ?? "Auto-merge off for \(goal.name)", taskId: nil)
    }

    /// Archives the goal (or brings it back). With unfinished tasks, `unfinished` says what happens to them.
    func archiveGoal(_ goal: Wire.Goal, archived: Bool, unfinished: Wire.UnfinishedTasks?) {
        send(.goalArchive(.init(id: goal.id, archived: archived, unfinished: unfinished)))
        notice = .toast(archived ? "Archived \(goal.name)" : "Unarchived \(goal.name)", taskId: nil)
    }

    // MARK: Machines

    /// The machine's owner or an admin: who the server lets update or rename it.
    func canManage(_ machine: Wire.Machine) -> Bool { !me.isEmpty && (machine.owner == me || isAdmin) }
    /// Moving a task off a stuck machine: its machine's owner, an admin, or the task's own owner.
    func canMove(task id: String, on machine: Wire.Machine) -> Bool { canManage(machine) || (!me.isEmpty && feed.task(id)?.owner == me) }
    /// A machine its tasks can be moved off: offline, or paused by its owner.
    /// Offline or fully paused. Under a new-work pause the tasks here keep finishing, so they aren't stuck.
    static func isStuck(_ machine: Wire.Machine) -> Bool { !machine.online || (machine.settings?.paused == true && machine.settings?.pauseNew != true) }

    /// Asks the machine to install the runner release shown (not a newer one out since); `machine.update` on it says how it goes.
    func updateRunner(_ machine: Wire.Machine) { send(.machineUpdate(.init(machine: machine.id, version: feed.runnerLatest))) }
    /// A nickname everyone sees; empty goes back to its id.
    func renameMachine(_ machine: Wire.Machine, name: String) { send(.machineRename(.init(machine: machine.id, name: name))) }
    /// Slots, team sharing and pause, as the Mac's machine settings sheet saves them.
    func saveMachineSettings(_ machine: Wire.Machine, settings: Wire.MachineSettings, handOff: Bool) {
        send(.machineSettings(.init(machine: machine.id, settings: settings, handOff: handOff)))
    }
    /// The swipe's Pause and Resume: pausing holds back new work only, with no end; resuming clears it.
    func setPaused(_ machine: Wire.Machine, _ paused: Bool) {
        var settings = machine.settings ?? Wire.MachineSettings(teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false)
        settings.paused = paused
        settings.pauseNew = paused ? true : nil
        settings.pausedUntil = nil
        saveMachineSettings(machine, settings: settings, handOff: false)
        if paused { notice = .toast("Paused new work on \(machine.name)", taskId: nil) }
    }
    /// Moves a task off its offline or paused machine: it re-queues first and carries on from its last push.
    func moveTask(_ id: String) {
        let pushed = feed.task(id)?.pr != nil
        send(.taskMove(.init(id: id)))
        notice = .toast("\(id) moves to the next free machine\(pushed ? " · carries on from its last push" : "")", taskId: id)
    }

    // MARK: Live sessions
    // The Mac's FactoryClient commands; the server's org-hub lets the machine's owner or an admin (canManage) send them.

    /// Opens a new terminal session on the machine: an agent in a folder, at the Mac's 120×36.
    func openSession(machine: String, agent: String, cwd: String) {
        send(.sessionOpen(.init(machine: machine, agent: agent, cwd: cwd, cols: 120, rows: 36)))
    }
    /// Ends a session: its terminal closes for everyone watching.
    func killSession(machine: String, id: String) { send(.sessionKill(.init(machine: machine, id: id))) }
    /// Who else may open a session's terminal: the whole list, each to watch or to type.
    func shareSession(machine: String, id: String, shares: [Wire.ShareGrant]) {
        send(.sessionShare(.init(machine: machine, id: id, shares: shares)))
    }
    /// Where a new session can start: home, the goals' folders, then where its sessions already are; no repeats.
    func folderChoices(for machine: Wire.Machine) -> [String] {
        var seen = Set<String>()
        return (["~"] + feed.goals.compactMap(\.folder) + machine.sessions.map(\.session.cwd))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Tells the factory which task you're looking at, so others see you there.
    func viewing(_ id: String?) { visibleTask = id; send(.presence(.init(viewing: id))) }

    // MARK: Review rounds and follow-ups
    // The same refusals as the server (engine.ts task.requestReview / task.followUp) and the Mac's
    // ReviewActions, so the phone doesn't offer what the factory would turn down.

    /// The server's `task.followUp` cap.
    static let maxFollowUps = 20
    /// The factory marks a task it's merging with this live log line (engine.ts startMerge).
    static let mergingLog = "Merging…"

    /// One more review round can be asked for: in review, its last round is in, nothing's up, not merging.
    static func canRequestReview(_ task: Wire.Task, feed: FeedState) -> Bool {
        guard task.state == .reviewing, let last = task.autoReview?.rounds.last else { return false }
        return last.verdict != .inProgress && task.hand == nil && task.question == nil && task.liveLog != mergingLog
    }

    /// Why follow-ups can't be made from this task, or nil when they can.
    static func followUpBlock(_ task: Wire.Task, feed: FeedState) -> String? {
        if task.state != .reviewing && task.state != .merged { return "Follow-ups are made from a task in review or merged." }
        guard let goal = feed.goal(task.goal) else { return "Its goal isn't there any more." }
        if goal.archived == true { return "\(goal.name) is archived; unarchive it to add tasks." }
        return nil
    }

    /// Which task already follows each `<task>#<finding>` (the server's `followedUp`, scout.ts).
    static func followedUp(_ feed: FeedState) -> [String: String] {
        var out: [String: String] = [:]
        for t in feed.tasks {
            for from in [t.scoutedFrom, t.followUpOf].compactMap({ $0 }) where out[from] == nil { out[from] = t.id }
        }
        return out
    }

    /// The findings a follow-up can still be made for: not fixed, and no task follows them yet.
    static func followableFindings(_ task: Wire.Task, feed: FeedState) -> [Wire.Finding] {
        let taken = followedUp(feed)
        return (task.autoReview?.findings ?? []).filter { $0.status != .fixed && taken["\(task.id)#\($0.id)"] == nil }
    }

    // MARK: HTTP

    /// A request to the factory with your token, for diffs and proof attachments.
    func request(_ path: String) -> URLRequest? {
        guard let server, let token else { return nil }
        return FactoryAPI(server: server, token: token).request(path)
    }

    /// A session's terminal socket (`/client/terminal`). No cols/rows: the phone watches at the pane's own size
    /// rather than shrinking the agent's pane to fit. Nil in the demo, which plays DemoData.terminal instead.
    func terminalRequest(machine: String, session: String) -> URLRequest? {
        guard status != .demo, let server, let token else { return nil }
        return FactoryAPI.terminalRequest(server, token: token, machine: machine, session: session)
    }

    /// Whether what you type reaches a session, as the server decides it: the machine's owner, an admin,
    /// or a teammate it was shared with to type. Everyone else watches.
    func canType(machine id: String, session: String) -> Bool {
        guard let machine = feed.machines.first(where: { $0.id == id }) else { return false }
        if machine.owner == me || isAdmin { return true }
        return machine.sessions.first { $0.session.id == session }?.shares?.first { $0.login == me }?.canType == true
    }

    /// Fetches a task's diff unless the one held is for the same change (`key`).
    func loadDiff(task id: String, key: String) async {
        if status == .demo { diffs[id] = (key, DemoData.diff(for: id)); return }
        guard diffs[id]?.key != key, let request = request("/api/tasks/\(id)/diff") else { return }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let files = await Task.detached { DiffFile.parse(String(decoding: data, as: UTF8.self)) }.value
        diffs[id] = (key, files)
    }

    /// An attachment's bytes (/attachments/<id>/<name>), with your token.
    func attachment(_ path: String) async -> Data? {
        // The demo's attachments: the app's mark for any image, a line of text for anything else.
        if status == .demo, path.hasPrefix("/attachments/demo/") {
            try? await Task.sleep(for: .seconds(0.2))
            if LinkedAttachment.kind(of: path, image: false) == .image { return UIImage(named: "Mark")?.pngData() }
            return Data("A demo attachment: \(path.split(separator: "/").last ?? "")\n".utf8)
        }
        guard let request = request(path) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Demo

    /// Sample goals, tasks and machines, so the app renders fully with no server.
    func startDemo() {
        close()
        feed = DemoData.feed()
        status = .demo
        // A sample registration for this phone and another; the demo never asks iOS or the network.
        notificationStatus = .allowed
        pushDeviceID = DemoData.thisPhone.id
        pushEnvironment = DemoData.thisPhone.environment
        pushDevices = DemoData.pushDevices
    }

    /// The demo answers actions itself, the way a factory would.
    private func demoSend(_ message: Wire.ClientMessage) {
        func update(_ id: String, _ change: (inout Wire.Task) -> Void) {
            guard var task = feed.task(id) else { return }
            change(&task)
            task.updatedAt = DemoData.now
            feed.apply(.taskUpdated(.init(task: task)))
        }
        switch message {
        case .taskApprovePlan(let m):
            update(m.id) { $0.approvals.append(me); if $0.approvals.count >= $0.approvalsNeeded { $0.state = .building } }
            notice = .toast("Plan approved", taskId: m.id)
        case .taskApproveChanges(let m):
            update(m.id) { $0.reviews.append(me) }
            notice = .toast("Changes approved", taskId: m.id)
        case .taskMerge(let m):
            update(m.id) { $0.state = .merged; $0.mergeAt = nil }
            notice = .toast("Merged", taskId: m.id)
        case .taskHoldMerge(let m):
            update(m.id) { $0.mergeAt = nil }
        case .taskAnswer(let m):
            update(m.id) { $0.question = nil; $0.events.append(.init(who: me, text: "answered: \(m.text)", at: DemoData.now)) }
        case .taskResolveHand(let m):
            update(m.id) { $0.hand = nil; $0.events.append(.init(who: me, text: "resolved the hand: \(m.option ?? m.note)", at: DemoData.now)) }
        case .taskComment(let m):
            update(m.id) { $0.comments.append(.init(id: UUID().uuidString, author: me, text: m.text, at: DemoData.now)) }
        case .taskReview(let m):
            // As the Mac's mockup does: a comment per note, then the batch as one queued change request.
            guard !m.notes.isEmpty else { break }
            update(m.id) { task in
                for note in m.notes {
                    task.comments.append(.init(id: UUID().uuidString, author: me, text: "```diff\n\(note.snippet)\n```\n\(note.text)", at: DemoData.now, anchor: Self.anchor(note)))
                }
                let text = m.notes.enumerated().map { "\($0.offset + 1). \(Self.anchor($0.element)): \($0.element.text)" }.joined(separator: "\n")
                task.changes.append(.init(id: "C\(task.changes.count + 1)", author: me, text: text, at: DemoData.now, anchor: "Review · \(m.notes.count) comment\(m.notes.count == 1 ? "" : "s")", status: .queued))
            }
        case .taskSteer(let m):
            update(m.id) { $0.changes.append(.init(id: UUID().uuidString, author: me, text: m.text, at: DemoData.now, status: .queued)) }
        case .taskPlan(let m):
            guard let state = feed.task(m.id)?.state, state == .drafting || state == .backlog else { return }
            update(m.id) { $0.state = .planning; $0.events.append(.init(who: me, text: "sent it to planning", at: DemoData.now)) }
            notice = .toast("Sent to planning", taskId: m.id)
        case .taskBacklog(let m):
            guard let state = feed.task(m.id)?.state, state == .drafting || state == .awaitingApproval else { return }
            update(m.id) { $0.state = .backlog; $0.approvals = []; $0.waiting = nil; $0.events.append(.init(who: me, text: "sent it to the backlog", at: DemoData.now)) }
            notice = .toast("Sent to the backlog", taskId: m.id)
        case .taskRankDraft(let m):
            guard let task = feed.task(m.id) else { return }
            let line = feed.tasks(in: task.goal).filter { $0.state == .drafting && $0.id != m.id }.sorted(by: Wire.Task.draftOrder)
            let target = m.before == "top" ? line.first : line.first { $0.id == m.before }
            let rank: Double
            if let target, let at = line.firstIndex(where: { $0.id == target.id }) {
                rank = at > 0 ? (line[at - 1].draftOrderRank + target.draftOrderRank) / 2 : target.draftOrderRank - 1000
            } else {
                rank = (line.map(\.draftOrderRank).max() ?? 0) + 1
            }
            update(m.id) { $0.draftRank = rank }
        case .taskAnswerPrompt(let m):
            // The runner passes the answer to the session, which carries on.
            guard let worker = feed.task(m.id)?.worker, let mi = feed.machines.firstIndex(where: { $0.id == worker.machine }),
                  let si = feed.machines[mi].sessions.firstIndex(where: { $0.session.id == worker.session }) else { break }
            var machine = feed.machines[mi]
            machine.sessions[si].activity = .init(state: .working, message: m.choice == .yes ? "Allowed" : "Denied", at: DemoData.now)
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .machineUpdate(let m):
            // Installing, then back on the latest a moment later, as a runner would report it.
            guard var machine = feed.machines.first(where: { $0.id == m.machine }) else { break }
            let target = feed.runnerLatest, from = machine.version
            machine.update = .init(state: .installing, target: target, from: from, at: DemoData.now)
            feed.apply(.machineUpdated(.init(machine: machine)))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "demoUpdateSeconds").nonZero ?? 2.5))
                guard let self, self.status == .demo, var machine = self.feed.machines.first(where: { $0.id == m.machine }) else { return }
                machine.version = target ?? machine.version
                machine.update = .init(state: .updated, target: target, from: from, at: DemoData.now)
                self.feed.apply(.machineUpdated(.init(machine: machine)))
            }
        case .machineRename(let m):
            guard var machine = feed.machines.first(where: { $0.id == m.machine }) else { break }
            let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
            machine.name = name.isEmpty ? machine.id : name
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .machineSettings(let m):
            guard var machine = feed.machines.first(where: { $0.id == m.machine }) else { break }
            machine.settings = m.settings
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .taskMove(let m):
            // The task re-queues: its session leaves the stuck machine.
            for var machine in feed.machines where machine.sessions.contains(where: { $0.session.taskId == m.id }) {
                machine.sessions.removeAll { $0.session.taskId == m.id }
                feed.apply(.machineUpdated(.init(machine: machine)))
            }
            update(m.id) { $0.worker = nil; $0.events.append(.init(who: me, text: "moved it to the next free machine", at: DemoData.now)) }
        case .taskCheckedIt(let m):
            // As the server does: the item is proven by your word, with the note as its reason.
            guard let task = feed.task(m.id), task.doneWhen.indices.contains(Int(m.item)) else { break }
            let item = task.doneWhen[Int(m.item)]
            let reason = m.note
            update(m.id) {
                $0.doneWhen[Int(m.item)].status = .proven
                $0.doneWhen[Int(m.item)].evidence = .init(kind: item.proof, summary: "Attested by \(me)\(reason.map { ": \($0)" } ?? "")", by: me, at: DemoData.now, attested: true, reason: reason)
                $0.events.append(.init(who: me, text: "attested \"\(item.text)\"\(reason.map { ": \($0)" } ?? "")", at: DemoData.now))
            }
            notice = .toast("Marked as checked", taskId: m.id)
        case .taskMockupChange(let m):
            // As the server does: the mockup waits on a new version, the change is queued for the
            // planner, and a plan waiting for approval goes back to planning.
            guard let mockup = feed.task(m.id)?.mockups.first(where: { $0.id == m.mockup }) else { break }
            update(m.id) {
                if let i = $0.mockups.firstIndex(where: { $0.id == m.mockup }) { $0.mockups[i].status = .changesRequested }
                $0.changes.append(.init(id: "C\($0.changes.count + 1)", author: me, text: m.text, at: DemoData.now, anchor: "Mockup: \(mockup.title)", status: .queued))
                $0.events.append(.init(who: me, text: "asked for a change to the \"\(mockup.title)\" mockup", at: DemoData.now))
                if $0.state == .awaitingApproval { $0.approvals = []; $0.state = .planning }
            }
            notice = .toast("Change requested: the planner will post a new version", taskId: m.id)
        case .taskRequestReview(let m):
            // As the server does: a running round with the focus, the merge waits for it, and there's
            // room for it and a fix round after.
            guard let task = feed.task(m.id), Self.canRequestReview(task, feed: feed) else {
                notice = .error("A review round is already running; wait for it to come in."); break
            }
            update(m.id) {
                guard var review = $0.autoReview else { return }
                if review.rounds.count + 2 > review.maxRounds { review.maxRounds = UInt32(review.rounds.count + 2) }
                review.rounds.append(.init(number: UInt32(review.rounds.count + 1), verdict: .inProgress, found: 0, at: DemoData.now, focus: m.focus, by: me))
                $0.autoReview = review
                $0.mergeAt = nil
                $0.comments.append(.init(id: UUID().uuidString, author: me, text: m.focus, at: DemoData.now, anchor: "Review request"))
                $0.events.append(.init(who: me, text: "asked for a review: \(m.focus)", at: DemoData.now))
            }
        case .taskFollowUp(let m):
            guard let task = feed.task(m.id) else { break }
            if let block = Self.followUpBlock(task, feed: feed) { notice = .error(block); break }
            guard let goal = feed.goal(task.goal), !m.items.isEmpty else { break }
            // Checked before any is made, so a bad item makes none.
            let taken = Self.followedUp(feed)
            var picks: [(title: String, brief: String, from: String, priority: Wire.Priority?)] = []
            for item in m.items {
                let title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                let note = item.brief.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { notice = .error("Each follow-up needs a title."); return }
                guard let id = item.finding else {
                    if note.isEmpty { notice = .error("Say what \"\(title)\" should do."); return }
                    picks.append((title, "\(note)\n\nFollow-up from \(task.id).", task.id, item.priority)); continue
                }
                guard let finding = task.autoReview?.findings.first(where: { $0.id == id }) else { notice = .error("\(task.id) has no finding \(id)."); return }
                let from = "\(task.id)#\(id)"
                if finding.status == .fixed { notice = .error("\(from) is already fixed."); return }
                if taken[from] != nil || picks.contains(where: { $0.from == from }) { notice = .error("\(from) already has a follow-up."); return }
                let quote = "> **\(finding.severity.rawValue) \(finding.kind.rawValue)**\(finding.file.map { " in `\($0)`" } ?? ""): \(finding.text.replacingOccurrences(of: "\n", with: "\n> "))"
                picks.append((title, "\(quote)\(note.isEmpty ? "" : "\n\n\(note)")\n\nFollow-up from \(task.id).", from, item.priority))
            }
            var next = (feed.tasks(in: goal.id).compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
            var made: [String] = []
            for p in picks {
                let draft = Wire.Task(id: "\(goal.prefix)-\(next)", goal: goal.id, title: p.title, state: .drafting, owner: me,
                                      brief: p.brief, createdAt: DemoData.now, updatedAt: DemoData.now, planVersion: 0, approvalsNeeded: 1, reviewsNeeded: 1,
                                      events: [.init(who: me, text: "made it as a follow-up of \(p.from)", at: DemoData.now)],
                                      shareable: false, agent: task.agent, repo: task.repo, priority: p.priority, followUpOf: p.from)
                feed.apply(.taskUpdated(.init(task: draft)))
                made.append(draft.id)
                next += 1
            }
            update(m.id) { $0.events.append(.init(who: me, text: "made follow-up\(made.count == 1 ? "" : "s") \(made.joined(separator: ", "))", at: DemoData.now)) }
            notice = .toast("Made \(made.count) follow-up\(made.count == 1 ? "" : "s") of \(task.id); \(made.count == 1 ? "it's" : "they're") in \(goal.name)'s drafts.", taskId: task.id)
        case .goalFollow(let m):
            feed.follows[m.id] = m.following
        case .goalAcceptRisk(let m):
            // As the server does: one acceptance per goal, replaced, or removed when taken back.
            var acceptances = feed.acceptances.filter { $0.goal != m.goal }
            if let upTo = m.upTo { acceptances.append(.init(goal: m.goal, upTo: upTo, by: me, at: DemoData.now, note: m.note)) }
            feed.acceptances = acceptances
        case .goalSave(let m):
            // As goal.save does: a prefix another goal uses is refused; a new goal gets an id.
            var goal = m.goal
            if feed.goals.contains(where: { $0.prefix == goal.prefix && $0.id != goal.id }) {
                apply(.error(.init(message: "Another goal already uses \(goal.prefix).")))
                break
            }
            if goal.id.isEmpty { goal.id = "g-\(goal.prefix.lowercased())" }
            apply(.goalUpdated(.init(goal: goal)))
        case .goalArchive(let m):
            guard var goal = feed.goal(m.id) else { break }
            if m.archived, m.unfinished == .cleanup || m.unfinished == .cancel {
                for task in feed.unfinishedTasks(in: goal.id) {
                    update(task.id) { $0.state = .cancelled; $0.worker = nil; $0.events.append(.init(who: me, text: "cancelled it, archiving \(goal.name)", at: DemoData.now)) }
                }
            }
            goal.archived = m.archived ? true : nil
            feed.apply(.goalUpdated(.init(goal: goal)))
        case .taskCreate(let m):
            guard let goal = feed.goal(m.goal) else { return }
            let next = (feed.tasks(in: goal.id).compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
            var task = Wire.Task(id: "\(goal.prefix)-\(next)", goal: goal.id, title: m.title, state: m.plan ? .planning : .drafting, owner: me,
                                 brief: m.brief, createdAt: DemoData.now, updatedAt: DemoData.now, planVersion: 0, approvalsNeeded: 1, reviewsNeeded: 1,
                                 events: [.init(who: me, text: "created the task", at: DemoData.now)],
                                 shareable: m.shareable, agent: m.agent ?? "claude", repo: m.repo, priority: m.priority)
            task.effort = m.effort
            feed.apply(.taskUpdated(.init(task: task)))
        case .taskAssign(let m):
            update(m.id) { task in
                if task.hand?.assignee == task.owner { task.hand?.assignee = m.owner }
                task.owner = m.owner
                task.events.append(.init(who: me, text: m.owner == me ? "took it over" : "assigned it to @\(m.owner)", at: DemoData.now))
            }
        case .taskEdit(let m):
            update(m.id) { task in
                if let title = m.title { task.title = title }
                if let brief = m.brief { task.brief = brief }
                if let effort = m.effort {
                    let was = task.effort
                    task.effort = effort.isEmpty ? nil : effort
                    task.events.append(.init(who: me, text: effort.isEmpty ? "took it out of effort \(was ?? "")" : "put it in effort \(effort)", at: DemoData.now))
                }
                if m.title != nil || m.brief != nil {
                    task.events.append(.init(who: me, text: m.title != nil ? "renamed it to \(m.title!)" : "edited the brief", at: DemoData.now))
                }
            }
        case .taskMoveGoal(let m):
            guard let goal = feed.goal(m.goal) else { return }
            update(m.id) { task in
                let was = feed.goal(task.goal)?.name ?? task.goal
                task.goal = goal.id
                task.effort = nil
                task.events.append(.init(who: me, text: "moved it from \(was) to \(goal.name)", at: DemoData.now))
            }
        case .taskCancel(let m):
            update(m.id) { task in
                task.state = .cancelled
                task.worker = nil
                task.mergeAt = nil
                if task.pr?.state == .open || task.pr?.state == .draft { task.pr?.state = .closed }
                task.events.append(.init(who: me, text: "cancelled it", at: DemoData.now))
            }
        case .taskQueue(let m):
            let ranks = feed.tasks.compactMap(\.queueRank)
            update(m.id) { task in
                task.queueRank = m.before == "top" ? (ranks.min() ?? 0) - 1 : (ranks.max() ?? 0) + 1
                task.events.append(.init(who: me, text: m.before == "top" ? "moved it to the top of the queue" : "moved it to the bottom of the queue", at: DemoData.now))
            }
        case .statsGet(let m):
            stats = DemoData.stats(days: Int(m.days))
        case .taskCheckLog(let m):
            let failed = feed.task(m.id)?.pr?.checks.first { $0.name == m.check }?.status == .failed
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                self.apply(.checkLog(DemoData.checkLog(task: m.id, check: m.check, failed: failed)))
            }
        case .taskRerunCheck(let m):
            demoRerun(m.id, checks: [m.check], text: "re-ran \(m.check)")
        case .taskRerunChecks(let m):
            let failed = feed.task(m.id)?.pr?.checks.filter { $0.status == .failed }.map(\.name) ?? []
            demoRerun(m.id, checks: failed, text: "re-ran the failed checks")
        case .taskRetry(let m):
            update(m.id) { task in
                if task.hand?.reason == .sessionEnded { task.hand = nil }
                if task.state == .cancelled || task.state == .closed {
                    if task.pr != nil {
                        task.state = .reviewing
                        if task.pr?.state == .closed { task.pr?.state = .open }
                    } else {
                        task.state = task.plan.isEmpty ? .planning : .building
                    }
                }
                task.events.append(.init(who: me, text: "retried it", at: DemoData.now))
            }
        case .taskRecheckGitHub(let m):
            demoRecheck(m.id)
        case .taskSplit(let m):
            demoSplit(m.id, parts: Int(m.parts))
        case .sessionOpen(let m):
            guard var machine = feed.machines.first(where: { $0.id == m.machine }) else { break }
            let id = "s-\(UUID().uuidString.prefix(6).lowercased())"
            machine.sessions.append(.init(session: .init(id: id, agent: m.agent, cwd: m.cwd, startedAt: DemoData.now),
                                          activity: .init(state: .working, message: "Started", at: DemoData.now)))
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .sessionKill(let m):
            guard var machine = feed.machines.first(where: { $0.id == m.machine }) else { break }
            machine.sessions.removeAll { $0.session.id == m.id }
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .sessionShare(let m):
            guard var machine = feed.machines.first(where: { $0.id == m.machine }),
                  let i = machine.sessions.firstIndex(where: { $0.session.id == m.id }) else { break }
            let old = machine.sessions[i].shares ?? []
            machine.sessions[i].shares = m.shares.map { grant in
                let kept = old.first { $0.login == grant.login }
                let same = kept?.canType == grant.canType
                return .init(login: grant.login, canType: grant.canType, by: same ? kept!.by : me, at: same ? kept!.at : DemoData.now)
            }
            feed.apply(.machineUpdated(.init(machine: machine)))
        case .recurringSave, .recurringPause, .recurringRunNow, .recurringDelete:
            demoRecurring(message)
        case .pushRegister, .pushDevices:
            break // The sample devices are already there.
        case .pushUnregister(let m):
            pushDevices.removeAll { $0.id == m.id || (m.token != nil && $0.id == m.token.map(Self.pushDeviceID)) }
        case .quietHoursSet(let m):
            quietHours = m.quietHours
        default:
            break
        }
    }
}

extension FactoryStore {
    /// The demo's re-run: the checks run, then pass about 2.5 s later.
    fileprivate func demoRerun(_ id: String, checks names: [String], text: String) {
        func update(_ change: (inout Wire.Task) -> Void) {
            guard var task = feed.task(id) else { return }
            change(&task)
            task.updatedAt = DemoData.now
            feed.apply(.taskUpdated(.init(task: task)))
        }
        guard !names.isEmpty else { return }
        update { task in
            for index in task.pr?.checks.indices ?? 0..<0 where names.contains(task.pr!.checks[index].name) {
                task.pr!.checks[index].status = .running
                task.pr!.checks[index].duration = nil
            }
            task.events.append(.init(who: me, text: text, at: DemoData.now))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            update { task in
                for index in task.pr?.checks.indices ?? 0..<0 where names.contains(task.pr!.checks[index].name) && task.pr!.checks[index].status == .running {
                    task.pr!.checks[index].status = .passed
                    task.pr!.checks[index].duration = "1m \(10 + index * 7)s"
                }
            }
        }
    }
}

extension FactoryStore {
    /// The demo's GitHub recheck (the Mac's mock): about 2.5 s later running or queued checks have
    /// passed, or a passing `test` shows up on a PR that reported none.
    fileprivate func demoRecheck(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard self.status == .demo, var task = self.feed.task(id), var pr = task.pr else { return }
            if pr.checks.isEmpty { pr.checks = [.init(name: "test", status: .passed, duration: "1m 12s", required: true)] }
            for index in pr.checks.indices where pr.checks[index].status == .running || pr.checks[index].status == .queued {
                pr.checks[index].status = .passed
                pr.checks[index].duration = "1m \(20 + index * 7)s"
            }
            task.pr = pr
            task.events.append(.init(who: self.me, text: "rechecked CI on GitHub", at: DemoData.now))
            task.updatedAt = DemoData.now
            self.feed.apply(.taskUpdated(.init(task: task)))
        }
    }

    /// The demo's split (the Mac's AppState.split): the original keeps its first steps, each later
    /// chunk becomes a new task in the same goal and repo, queued for planning.
    fileprivate func demoSplit(_ id: String, parts: Int) {
        guard var original = feed.task(id), let goal = feed.goal(original.goal) else { return }
        let chunks = Self.splitSteps(original.plan, parts: parts)
        guard chunks.count > 1 else { return }
        var next = (feed.tasks(in: goal.id).compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
        let share = original.footprint.map { Wire.Footprint(files: UInt32((Double($0.files) / Double(parts)).rounded(.up)), lines: $0.lines / UInt32(parts), estimated: true) }
        var made: [String] = []
        for chunk in chunks.dropFirst() {
            var task = Wire.Task(id: "\(goal.prefix)-\(next)", goal: goal.id,
                                 title: chunk.count > 1 ? "\(chunk[0].text) (+\(chunk.count - 1) more)" : chunk[0].text,
                                 state: .planning, owner: original.owner,
                                 brief: "Split from \(id) to stay inside the PR budget. \(original.brief)",
                                 createdAt: DemoData.now, updatedAt: DemoData.now,
                                 plan: chunk.map { var step = $0; step.progress = nil; return step },
                                 planVersion: 0, approvalsNeeded: original.approvalsNeeded, reviewsNeeded: original.reviewsNeeded,
                                 events: [.init(who: me, text: "made it by splitting \(id)", at: DemoData.now)],
                                 footprint: share, shareable: original.shareable, agent: original.agent, splitFrom: id, repo: original.repo)
            task.effort = original.effort
            feed.apply(.taskUpdated(.init(task: task)))
            made.append(task.id)
            next += 1
        }
        original.plan = chunks[0]
        original.footprint = share.map { Wire.Footprint(files: $0.files, lines: $0.lines, estimated: original.footprint?.estimated ?? true) }
        original.events.append(.init(who: me, text: "Split into \(made.count + 1) tasks: \(([id] + made).joined(separator: ", "))", at: DemoData.now))
        original.updatedAt = DemoData.now
        feed.apply(.taskUpdated(.init(task: original)))
    }
}

// MARK: Recurring tasks

extension FactoryStore {
    /// A goal's recurring tasks: running ones first, then soonest next run.
    func recurring(goal: String) -> [Wire.Recurring] { feed.recurring(goal: goal) }

    /// Add or change a recurring task (a new one has a new id); the server works out its next run.
    func saveRecurring(_ item: Wire.Recurring) { send(.recurringSave(.init(recurring: item))) }

    /// Pause or resume one; resuming moves its next run to the next due time from now.
    func pauseRecurring(id: String, paused: Bool) { send(.recurringPause(.init(id: id, paused: paused))) }

    /// Start a run now; its schedule is kept.
    func runRecurringNow(id: String) {
        let title = feed.recurring[id]?.title
        send(.recurringRunNow(.init(id: id)))
        notice = .toast(title.map { "Started a run of \($0)" } ?? "Started a run", taskId: nil)
    }

    /// Gone from the list right away, as on the Mac; the server confirms with `recurring.deleted`.
    func deleteRecurring(id: String) {
        feed.recurring[id] = nil
        send(.recurringDelete(.init(id: id)))
    }

    /// The demo answers the recurring messages the way the server would.
    fileprivate func demoRecurring(_ message: Wire.ClientMessage) {
        func update(_ id: String, _ change: (inout Wire.Recurring) -> Void) {
            guard var item = feed.recurring[id] else { return }
            change(&item)
            feed.apply(.recurringUpdated(.init(recurring: item)))
        }
        switch message {
        case .recurringSave(let m):
            var item = m.recurring
            item.nextAt = item.firstAt
            item.by = me
            if let was = feed.recurring[item.id] { item.lastTask = was.lastTask; item.lastRunAt = was.lastRunAt; item.paused = was.paused }
            feed.apply(.recurringUpdated(.init(recurring: item)))
        case .recurringPause(let m):
            update(m.id) { $0.paused = m.paused }
        case .recurringRunNow(let m):
            guard let item = feed.recurring[m.id], let goal = feed.goal(item.goal) else { return }
            let next = (feed.tasks(in: goal.id).compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
            let task = Wire.Task(id: "\(goal.prefix)-\(next)", goal: goal.id, title: item.title, state: .planning, owner: item.by,
                                 brief: item.brief, createdAt: DemoData.now, updatedAt: DemoData.now, planVersion: 0, approvalsNeeded: 1, reviewsNeeded: 1,
                                 events: [.init(who: "factory", text: "started it from the recurring task \(item.title)", at: DemoData.now)],
                                 shareable: false, agent: item.agent, repo: item.repo)
            feed.apply(.taskUpdated(.init(task: task)))
            update(m.id) { $0.lastTask = task.id; $0.lastRunAt = DemoData.now }
        case .recurringDelete(let m):
            feed.apply(.recurringDeleted(.init(id: m.id)))
        default:
            break
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

extension Wire.Task {
    /// Where a draft sits in its goal's drafts: its rank, or when it was made, as the factory orders them.
    var draftOrderRank: Double { draftRank ?? Double(createdAt) }

    /// A goal's drafts, first first.
    static func draftOrder(_ a: Wire.Task, _ b: Wire.Task) -> Bool {
        (a.draftOrderRank, a.id) < (b.draftOrderRank, b.id)
    }
}
