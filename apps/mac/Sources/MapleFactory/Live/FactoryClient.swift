import AppKit
import Foundation
import Security

/// The app's connection to a real factory: who you are, the live machines, recent session ends, and
/// the goals and tasks. Views that were designed against mock data read the adapted copies
/// (`factoryTasks`, `factoryGoals`) when signed in.
@MainActor @Observable final class FactoryClient {
    enum Status: Equatable {
        case signedOut
        case connecting
        case live
        /// Lost the feed; trying again on a backoff.
        case reconnecting(attempt: Int, reason: String)
        /// The factory sent something this build can't read: it's newer than the app.
        case tooNew
    }

    /// A session end as the feed reported it, kept newest first.
    struct EndRecord: Identifiable {
        let machine: String
        let end: Wire.SessionEnd
        var id: String { end.id }
    }

    private(set) var server: URL?
    private(set) var org = ""
    /// Every factory signed into on this Mac, the current one among them. Each token stays in the
    /// Keychain under its factory's URL, so switching back doesn't ask to sign in again.
    private(set) var savedFactories: [SavedFactory] = [] {
        didSet { SavedFactories.store(savedFactories) }
    }
    private(set) var me: Wire.Member?
    private(set) var machines: [Wire.Machine] = []
    /// Agent sign-ins on your machines (`codex login --device-auth`), by `machine:agent`, while they run
    /// and until their card has shown how they ended.
    private(set) var agentLogins: [String: Wire.AgentLoginStatus] = [:]
    private(set) var ends: [EndRecord] = []
    private(set) var members: [Wire.Member] = []
    private(set) var goals: [Wire.Goal] = []
    private(set) var tasks: [Wire.Task] = []
    /// The tasks and goals as the views' models, rebuilt when they change.
    private(set) var factoryTasks: [FactoryTask] = [] {
        didSet { tasksRevision &+= 1 }
    }
    /// Counts changes to `factoryTasks`: what's worked out from the tasks is cached against it.
    private(set) var tasksRevision = 0
    private(set) var factoryGoals: [Goal] = []
    private(set) var online: [Wire.Presence] = []
    private(set) var intakeRequests: [Wire.IntakeRequest] = []
    /// Requests as the views' models, newest first.
    private(set) var intake: [IntakeRequest] = []
    /// Your Scratchpad, as the views' notes, newest first.
    private(set) var notes: [Note] = []
    /// Your Draft with AI runs, by id.
    private(set) var drafts: [String: Wire.Draft] = [:]
    /// Goals you chose to follow (true) or stop following (false), by id.
    private(set) var follows: [String: Bool] = [:]
    /// Notes edited here whose save hasn't gone out yet; the server's echo of an older save mustn't undo typing.
    private var unsaved: [UUID: Task<Void, Never>] = [:]
    private(set) var policy: Wire.RiskPolicy?
    /// The org's additions to every session's prompt, by role; nil from an older server.
    private(set) var prompts: Wire.PromptAdditions?
    /// The factory's MCP connectors, secret values blank (only which keys are set). None: an older server.
    private(set) var connectors: [Wire.McpConnector]?
    /// The org's repos: the GitHub App's, and any added by hand.
    private(set) var repos: [Wire.OrgRepo] = []
    /// Every repo's secrets: names and who changed them when, never a value.
    private(set) var secrets: [Wire.RepoSecret] = []
    /// The repos with worktree scripts (Settings › Repositories); empty from an older server.
    private(set) var repoScripts: [Wire.RepoWorktreeScripts] = []
    /// Other GitHub accounts an admin approved, whose installations of the app add repos; empty from an older server.
    private(set) var repoOwners: [String] = []
    /// The factory's GitHub App and its links; nil with no app, or from an older server.
    private(set) var githubApp: Wire.GitHubAppInfo?
    /// The newest released runner, when the factory has a release to offer.
    private(set) var runnerLatest: String?
    /// Runner releases with their notes, newest first (What's new); empty from an older server.
    private(set) var runnerReleases: [Wire.RunnerRelease] = []
    /// This factory's maple-server version, and a newer one when there is (admins only).
    private(set) var serverVersion: String?
    private(set) var serverUpdate: Wire.ServerUpdate?
    /// The factory's icon link (`/icon/<id>`), nil when it has none (or the server is older).
    private(set) var iconLink: String?
    /// The factory's icon, from this Mac's cache; nil shows the letter tile (and the Maple Dock icon).
    /// The Dock follows it on every change: launch, sign-in, a switch, icon.updated and sign-out.
    private(set) var icon: NSImage? {
        didSet { if icon !== oldValue { DockIcon.apply(icon) } }
    }
    /// The name an admin gave the factory (Settings › Appearance), nil when unset (or the server is older).
    private(set) var displayName: String?
    /// The last statistics asked for (admins only).
    private(set) var stats: Wire.StatsSummary?
    /// CI check logs asked for (`task.checkLog`), by CheckLogRequest.id. Logs are never broadcast or kept by the server.
    private(set) var checkLogs: [String: CheckLogLoad] = [:]
    var isAdmin: Bool { me?.role == "admin" }
    /// Admins see Statistics; signed out, the mockup shows it.
    var canSeeStats: Bool { !isSignedIn || isAdmin }

    /// Who this person keeps in their sidebar (Settings → People), per factory; nil until they pick.
    var sidebarPicks: [String]? {
        get { _ = picksChanged; return AppDefaults.stringArray(forKey: picksKey) }
        set { AppDefaults.set(newValue, forKey: picksKey); picksChanged += 1 }
    }
    private var picksChanged = 0
    private var picksKey: String { "sidebarPeople.\(serverKey)" }

    /// The order this person put their sidebar goals in, by goal id, per factory; nil until they move one.
    var goalOrder: [String]? {
        get { _ = goalOrderChanged; return AppDefaults.stringArray(forKey: goalOrderKey) }
        set { AppDefaults.set(newValue, forKey: goalOrderKey); goalOrderChanged += 1 }
    }
    private var goalOrderChanged = 0
    private var goalOrderKey: String { "sidebarGoalOrder.\(serverKey)" }
    private var serverKey: String { "\(server?.host() ?? "")\(server?.port.map { ":\($0)" } ?? "")" }

    /// The people in the sidebar: their picks, else whoever shares a GitHub team with them (everyone
    /// when they're on none). Always them first.
    var sidebarMembers: [Wire.Member] {
        guard let me else { return members }
        let others = members.filter { $0.login != me.login }
        let shown = sidebarPicks.map { picks in others.filter { picks.contains($0.login) } }
            ?? (me.teams.isEmpty ? others : others.filter { !Set($0.teams).isDisjoint(with: me.teams) })
        return [members.first { $0.login == me.login } ?? me] + shown
    }

    /// The machines in the sidebar: yours, then teammates' that have team slots open. The Machines page
    /// still lists them all.
    var sidebarMachines: [Wire.Machine] { Self.sidebarMachines(machines, me: me?.login) }

    static func sidebarMachines(_ machines: [Wire.Machine], me: String?) -> [Wire.Machine] {
        guard let me else { return machines }
        let mine = machines.filter { $0.owner == me }
        let shared = machines.filter { $0.owner != me && isShared($0) }
        return mine + shared
    }

    /// Whether a machine lends anything to the team; one with no settings yet lends nothing.
    static func isShared(_ machine: Wire.Machine) -> Bool {
        guard let settings = machine.settings else { return false }
        return settings.teamSlots > 0 || settings.lendIdle
    }
    private(set) var acceptances: [Wire.RiskAcceptance] = []
    /// The policy and acceptances as the views' models.
    private(set) var riskPolicy: RiskPolicy?
    private(set) var riskAcceptances: [String: RiskAcceptance] = [:]
    /// A passing line from the factory ("ATL-3 merged"), for the app's toast.
    private(set) var toast: (text: String, taskID: String?, at: Date)?
    private(set) var status: Status = .signedOut
    /// Whether this factory's first snapshot has landed. A reconnect keeps it, so the old content stays up.
    private(set) var hasSnapshot = false
    /// The last thing the server refused, shown as a toast-like line.
    var notice: String?
    /// The goal editor is waiting on goal.save: it shows refusals itself, so they don't toast behind it.
    var savingGoal = false
    /// Bumped on every goal.updated, so a saving goal editor hears an update even when nothing changed.
    private(set) var goalUpdates = 0

    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var attempt = 0
    /// When the feed last answered: a message, or a pong to a keep-alive ping.
    private var lastHeard = Date()

    var isSignedIn: Bool { server != nil && token != nil }

    /// The factory's name an admin set, else the org's, or the mockup's workspace when not signed in.
    var workspaceName: String {
        guard isSignedIn else { return "Studio Workspace" }
        return displayName ?? orgName
    }

    /// The GitHub org's name (or the server's host), what the factory is called when it has no name of its own.
    var orgName: String {
        org.isEmpty || org == "local" ? server?.host() ?? "Factory" : org
    }

    init() {
        let defaults = AppDefaults
        savedFactories = SavedFactories.migrate(SavedFactories.load(), currentURL: defaults.string(forKey: "factoryURL"),
                                                currentOrg: defaults.string(forKey: "factoryOrg"))
        if let saved = defaults.string(forKey: "factoryURL"), let url = URL(string: saved),
           let token = Keychain.read(account: saved) {
            server = url
            self.token = token
            org = defaults.string(forKey: "factoryOrg") ?? ""
            showSavedIcon()
        }
        // A socket can die quietly while the Mac sleeps or the app sits in the background; catch up
        // with a fresh snapshot rather than leave every list as it was.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp(force: true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp(force: false) }
        }
    }

    /// Reconnects (and so resubscribes) after a wake, or when the feed has been quiet longer than its pings allow.
    private func catchUp(force: Bool) {
        guard isSignedIn, force || Date().timeIntervalSince(lastHeard) > 45 else { return }
        attempt = 0
        connect()
    }

    /// Shows a change before the factory echoes it (a card dropped in the queue lands at once);
    /// the task's next `task.updated` replaces it with what the factory did.
    func expect(_ id: String, _ change: (inout FactoryTask) -> Void) {
        guard let index = factoryTasks.firstIndex(where: { $0.id == id }) else { return }
        change(&factoryTasks[index])
    }

    // MARK: Session

    func signIn(_ result: SignInResult) {
        if result.server != server { resetFactoryState() }
        server = result.server
        token = result.token
        me = result.member
        org = result.org
        AppDefaults.set(result.server.absoluteString, forKey: "factoryURL")
        AppDefaults.set(result.org, forKey: "factoryOrg")
        Keychain.write(result.token, account: result.server.absoluteString)
        remember()
        connect()
    }

    /// Opens another saved factory with its kept token. False when there's no token for it, so the
    /// caller can send the person to sign in again.
    @discardableResult
    func switchTo(_ factory: SavedFactory) -> Bool {
        guard SavedFactory.key(factory.server) != serverKey || !isSignedIn else { return true }
        guard let token = Keychain.read(account: factory.server.absoluteString) else { return false }
        disconnect()
        resetFactoryState()
        server = factory.server
        self.token = token
        org = factory.org
        AppDefaults.set(factory.server.absoluteString, forKey: "factoryURL")
        AppDefaults.set(factory.org, forKey: "factoryOrg")
        remember()
        showSavedIcon()
        connect()
        return true
    }

    /// Signs out of this factory only; the most recent other one opens in its place, when there is one.
    func signOut() {
        if let server {
            Keychain.delete(account: server.absoluteString)
            savedFactories = SavedFactories.remove(server, from: savedFactories)
            try? FileManager.default.removeItem(at: FactoryIcons.folder(for: server))
        }
        if let next = SavedFactories.fallback(savedFactories), switchTo(next) { return }
        AppDefaults.removeObject(forKey: "factoryURL")
        AppDefaults.removeObject(forKey: "factoryOrg")
        disconnect()
        generation += 1
        server = nil
        token = nil
        resetFactoryState()
        status = .signedOut
    }

    /// Puts the current factory at the front of the saved list, as the last one used.
    private func remember() {
        guard let server else { return }
        let kept = savedFactories.first { $0.id == SavedFactory.key(server) }?.icon
        savedFactories = SavedFactories.upsert(SavedFactory(server: server, org: org, name: workspaceName, lastUsed: Date(), icon: kept), into: savedFactories)
    }

    /// Forgets everything the last factory sent, so none of it shows under the next one.
    private func resetFactoryState() {
        for task in unsaved.values { task.cancel() }
        unsaved = [:]
        me = nil
        machines = []
        ends = []
        members = []
        goals = []
        tasks = []
        online = []
        intakeRequests = []
        notes = []
        drafts = [:]
        follows = [:]
        policy = nil
        prompts = nil
        connectors = nil
        acceptances = []
        repos = []
        secrets = []
        repoScripts = []
        repoOwners = []
        githubApp = nil
        runnerLatest = nil
        runnerReleases = []
        serverVersion = nil
        serverUpdate = nil
        iconLink = nil
        icon = nil
        displayName = nil
        toast = nil
        notice = nil
        viewing = nil
        attempt = 0
        rebuild()
        hasSnapshot = false
        status = .connecting
    }

    // MARK: Feed

    func connect() {
        guard let server, let token else { return }
        disconnect()
        generation += 1
        let gen = generation
        if status != .live && status != .tooNew { status = attempt == 0 ? .connecting : status }
        var request = URLRequest(url: Self.websocketURL(server, path: "/client/connect"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        lastHeard = Date()
        socket.resume()
        send(.subscribe)
        Task { await receive(socket, gen: gen) }
        Task { await keepAlive(socket, gen: gen) }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// One for every message from the feed, not one each.
    private let decoder = JSONDecoder()

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            do {
                let message = try await socket.receive()
                lastHeard = Date()
                guard case .string(let text) = message, let data = text.data(using: .utf8) else { continue }
                apply(try decoder.decode(Wire.ServerToClient.self, from: data))
            } catch {
                guard gen == generation else { return }
                if error is DecodingError {
                    NSLog("Maple Factory: can't read the factory's message: \(error)")
                    tooNew()
                    return
                }
                retry(reason: Self.describe(error, response: socket.response))
                return
            }
        }
    }

    /// Pings keep proxies from dropping a quiet socket, and notice a dead one sooner than TCP would.
    private func keepAlive(_ socket: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            try? await Task.sleep(for: .seconds(20))
            guard gen == generation else { return }
            socket.sendPing { error in
                guard error == nil else { return }
                Task { @MainActor in self.lastHeard = Date() }
            }
        }
    }

    private func retry(reason: String) {
        attempt += 1
        status = .reconnecting(attempt: attempt, reason: reason)
        for index in machines.indices { machines[index].online = false }
        let delay = min(pow(2, Double(min(attempt, 5))), 30)
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if gen == generation { connect() }
        }
    }

    /// Only an app update (or the server rolling back) fixes a message this build can't read, so this
    /// tries again slowly rather than on the usual backoff.
    private func tooNew() {
        disconnect()
        status = .tooNew
        for index in machines.indices { machines[index].online = false }
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(60))
            if gen == generation { connect() }
        }
    }

    /// One message from the feed (internal for tests).
    func apply(_ message: Wire.ServerToClient) {
        switch message {
        case .snapshot(let snapshot):
            attempt = 0
            status = .live
            org = snapshot.org
            me = snapshot.me
            machines = snapshot.machines
            ends = snapshot.ended.map { EndRecord(machine: $0.machine, end: $0.end) }
            members = snapshot.members
            goals = snapshot.goals
            tasks = snapshot.tasks
            FactoryData.me = LiveAdapter.person(snapshot.me.login, members: members)
            policy = snapshot.policy
            acceptances = snapshot.acceptances
            prompts = snapshot.prompts
            connectors = snapshot.connectors
            online = snapshot.online
            notes = snapshot.notes.map(LiveAdapter.note)
            follows = Dictionary(snapshot.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
            intakeRequests = snapshot.intake
            repos = snapshot.repos
            secrets = snapshot.secrets
            repoScripts = snapshot.scripts ?? []
            repoOwners = snapshot.repoOwners ?? []
            githubApp = snapshot.githubApp
            runnerLatest = snapshot.runnerLatest
            runnerReleases = snapshot.runnerReleases ?? []
            serverVersion = snapshot.serverVersion
            serverUpdate = snapshot.serverUpdate
            displayName = snapshot.name
            rebuild()
            hasSnapshot = true
            remember()
            showIcon(snapshot.icon)
            if let viewing { send(.presence(.init(viewing: viewing))) }
        case .machineUpdated(let update):
            if let index = machines.firstIndex(where: { $0.id == update.machine.id }) {
                machines[index] = update.machine
            } else {
                machines.append(update.machine)
            }
            // Once health says it's signed in, a sign-in still showing a code or an error is over.
            for agent in update.machine.health?.agents ?? [] where agent.loggedIn {
                let key = Self.loginKey(update.machine.id, agent.name)
                if let login = agentLogins[key], login.state != .done { agentLogins[key] = nil }
            }
        case .machineAgentLogin(let update):
            let key = Self.loginKey(update.machine, update.status.agent)
            // A cancel without a reason is one asked for here: its panel already closed.
            agentLogins[key] = update.status.state == .cancelled && update.status.message == nil ? nil : update.status
        case .machineRemoved(let removed):
            machines.removeAll { $0.id == removed.id }
        case .sessionEnded(let ended):
            // The factory closing a session that reported back is how it's meant to go, not news.
            guard ended.end.by != "factory" else { break }
            ends.insert(EndRecord(machine: ended.machine, end: ended.end), at: 0)
            if ends.count > 50 { ends.removeLast(ends.count - 50) }
        case .taskUpdated(let update):
            let previous = tasks.first { $0.id == update.task.id }
            defer { notify(was: previous, now: update.task) }
            if let index = tasks.firstIndex(where: { $0.id == update.task.id }) {
                tasks[index] = update.task
                factoryTasks[index] = adapt(update.task)
            } else {
                tasks.insert(update.task, at: 0)
                factoryTasks.insert(adapt(update.task), at: 0)
                // A new task of yours puts its goal in your sidebar.
                if update.task.owner == me?.login { rebuildGoals() }
            }
        case .taskRemoved(let removed):
            tasks.removeAll { $0.id == removed.id }
            factoryTasks.removeAll { $0.id == removed.id }
        case .goalUpdated(let update):
            if let index = goals.firstIndex(where: { $0.id == update.goal.id }) {
                goals[index] = update.goal
            } else {
                goals.append(update.goal)
            }
            goalUpdates += 1
            rebuild()
        case .intakeUpdated(let update):
            if let index = intakeRequests.firstIndex(where: { $0.id == update.request.id }) {
                intakeRequests[index] = update.request
            } else {
                intakeRequests.insert(update.request, at: 0)
            }
            intake = intakeRequests.map { LiveAdapter.request($0, goals: goals, members: members) }
        case .noteUpdated(let update):
            let note = LiveAdapter.note(update.note)
            guard unsaved[note.id] == nil else { break }
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.insert(note, at: 0) }
        case .draftUpdated(let update):
            drafts[update.draft.id] = update.draft
        case .followsUpdated(let update):
            follows = Dictionary(update.follows.map { ($0.goal, $0.following) }, uniquingKeysWith: { _, last in last })
            rebuildGoals()
        case .noteRemoved(let removed):
            notes.removeAll { $0.id.uuidString.lowercased() == removed.id.lowercased() }
        case .presence(let update):
            online = update.online
            applyPresence()
        case .reposUpdated(let update):
            repos = update.repos
            if let scripts = update.scripts { repoScripts = scripts }
            if let owners = update.repoOwners { repoOwners = owners }
        case .secretsUpdated(let update):
            secrets = update.secrets
        case .runnerReleased(let update):
            // The hub's hourly look at the release feed: every outdated badge and What's new follows.
            runnerLatest = update.runnerLatest
            runnerReleases = update.runnerReleases
        case .promptsUpdated(let update):
            prompts = update.prompts
        case .membersUpdated(let update):
            // An admin grant changed: every badge follows, and so do this Mac's admin-only controls when it's about me.
            members = update.members
            if let mine = members.first(where: { $0.login == me?.login }) { me = mine }
            rebuild()
        case .iconUpdated(let update):
            showIcon(update.icon)
        case .nameUpdated(let update):
            // Every app shows the new name at once, and the factory switcher keeps it.
            displayName = update.name
            remember()
        case .connectorsUpdated(let update):
            connectors = update.connectors
        case .policyUpdated(let update):
            policy = update.policy
            acceptances = update.acceptances
            rebuild()
        case .stats(let reply):
            stats = reply.summary
        case .checkLog(let reply):
            let key = CheckLogRequest(taskID: reply.id, check: reply.check).id
            // Only into a sheet still waiting for it: a log forgotten since (the check re-run) stays forgotten.
            if checkLogs[key] == .loading {
                checkLogs[key] = .loaded(CheckLog(text: reply.text, truncated: reply.truncated, failedStep: reply.failedStep, url: reply.url.flatMap(URL.init(string:))))
            }
        case .toast(let toast):
            self.toast = (toast.text, toast.taskId, Date())
        case .error(let error):
            // A log that couldn't be read says which one (`checkLog:<task>/<check>`) and shows in its sheet.
            if let id = error.requestId, id.hasPrefix("checkLog:") {
                let key = String(id.dropFirst("checkLog:".count))
                if checkLogs[key] == .loading { checkLogs[key] = .failed(error.message) }
            } else {
                notice = error.message
            }
        case .unknown:
            break
        }
    }

    /// A banner when a task newly needs you; the snapshot never calls this, so reconnecting stays quiet.
    private func notify(was old: Wire.Task?, now task: Wire.Task) {
        for reason in Self.mentionReasons(was: old, now: task, me: me?.login, members: members) {
            Notifier.shared.notify(task: task, reason: reason)
        }
        let me = me?.login
        let needed = old.map { LiveAdapter.needsYou($0, me: me) } ?? false
        let needs = LiveAdapter.needsYou(task, me: me)
        let handRaised = old?.hand == nil && task.hand != nil && task.hand?.assignee == me
        guard needs else {
            if needed { Notifier.shared.clear(task: task.id) }
            return
        }
        guard !needed || handRaised else { return }
        let reason: Notifier.Reason
        if task.hand?.assignee == me, let hand = factoryTasks.first(where: { $0.id == task.id })?.hand {
            reason = .hand(hand.reason)
        } else if task.question != nil && task.owner == me {
            reason = .question
        } else if task.state == .awaitingApproval {
            reason = .approval
        } else {
            reason = .review
        }
        Notifier.shared.notify(task: task, reason: reason)
    }

    /// A `.mention` for each comment new in this update that a teammate wrote mentioning you.
    static func mentionReasons(was old: Wire.Task?, now task: Wire.Task, me: String?, members: [Wire.Member]) -> [Notifier.Reason] {
        guard let me else { return [] }
        let seen = Set(old?.comments.map(\.id) ?? [])
        return task.comments.filter { comment in
            guard !seen.contains(comment.id), comment.author.caseInsensitiveCompare(me) != .orderedSame else { return false }
            return Comment(author: LiveAdapter.person(comment.author, members: members), text: comment.text, when: "", mentions: comment.mentions).mentions(me)
        }.map { .mention(author: LiveAdapter.person($0.author, members: members).firstName, text: $0.text) }
    }

    private func adapt(_ task: Wire.Task, viewers: [String: [Person]]? = nil) -> FactoryTask {
        var adapted = LiveAdapter.task(task, goals: goals, members: members, me: me?.login)
        adapted.viewers = (viewers ?? Self.viewers(online, me: me?.login, members: members))[task.id] ?? []
        return adapted
    }

    /// Who's looking at each task, by its id, besides you.
    static func viewers(_ online: [Wire.Presence], me: String?, members: [Wire.Member]) -> [String: [Person]] {
        var viewers: [String: [Person]] = [:]
        for presence in online where presence.login != me {
            guard let id = presence.viewing else { continue }
            viewers[id, default: []].append(LiveAdapter.person(presence.login, members: members))
        }
        return viewers
    }

    /// The tasks whose viewers aren't `viewers`', by index, with the viewers they now have.
    static func viewerChanges(_ tasks: [FactoryTask], viewers: [String: [Person]]) -> [(index: Int, viewers: [Person])] {
        tasks.indices.compactMap { index in
            let now = viewers[tasks[index].id] ?? []
            return now.map(\.id) == tasks[index].viewers.map(\.id) ? nil : (index, now)
        }
    }

    /// Whether a goal is in your sidebar: what you chose, else whether you lead it, are on its team,
    /// or own or reviewed a task in it.
    func isFollowing(_ goal: Wire.Goal) -> Bool {
        if let chosen = follows[goal.id] { return chosen }
        guard let me else { return true }
        if goal.lead == me.login { return true }
        if let team = goal.team, me.teams.contains(where: { $0.caseInsensitiveCompare(team) == .orderedSame }) { return true }
        return tasks.contains { $0.goal == goal.id && ($0.owner == me.login || $0.reviews.contains(me.login)) }
    }

    func follow(goal name: String, _ following: Bool) {
        guard let goal = goal(named: name) else { return }
        follows[goal.id] = following
        rebuildGoals()
        send(.goalFollow(.init(id: goal.id, following: following)))
    }

    /// Every GitHub team someone in the org is on, for a goal's team.
    var teams: [String] { Array(Set(members.flatMap(\.teams) + (me?.teams ?? []))).sorted() }

    private func rebuildGoals() {
        // Live first: the timeline's start, and so each due day, is the mockup's until it is.
        if server != nil, FactoryData.liveGoals == nil { FactoryData.liveGoals = [] }
        factoryGoals = goals.map { LiveAdapter.goal($0, members: members, following: isFollowing($0)) }
        FactoryData.liveGoals = server == nil ? nil : factoryGoals
    }

    private func rebuild() {
        rebuildGoals()
        FactoryData.livePeople = server == nil ? nil : members.map { LiveAdapter.person($0.login, members: members) }
        let viewers = Self.viewers(online, me: me?.login, members: members)
        factoryTasks = tasks.map { adapt($0, viewers: viewers) }
        applyPresence()
        intake = intakeRequests.map { LiveAdapter.request($0, goals: goals, members: members) }
        riskPolicy = policy.map(LiveAdapter.policy)
        riskAcceptances = Dictionary(acceptances.compactMap { a in
            goals.first { $0.id == a.goal }.map { goal in
                (goal.name, RiskAcceptance(autoMergeUpTo: LiveAdapter.riskLevel(a.upTo), acceptedBy: LiveAdapter.person(a.by, members: members),
                                           when: LiveAdapter.ago(a.at), note: a.note))
            }
        }, uniquingKeysWith: { a, _ in a })
    }

    func save(policy: RiskPolicy) {
        riskPolicy = policy
        send(.policySave(.init(policy: LiveAdapter.wire(policy))))
    }

    /// Admins only; the server trims them and says so with prompts.updated.
    func save(prompts: Wire.PromptAdditions) {
        send(.promptsSave(.init(prompts: prompts)))
    }

    /// Admins only: makes someone who has signed in an admin here; members.updated says it took.
    func grantAdmin(_ login: String) {
        send(.adminsGrant(.init(login: login)))
    }

    /// Admins only: takes back a grant (not a GitHub owner's, nor my own).
    func revokeAdmin(_ login: String) {
        send(.adminsRevoke(.init(login: login)))
    }

    // MARK: Icon

    /// The current factory's cached icon, shown at once on launch or a switch, before its snapshot says whether it changed.
    private func showSavedIcon() {
        guard let server else { return }
        icon = savedFactories.first { $0.id == SavedFactory.key(server) }?.icon.flatMap(FactoryIcons.image)
    }

    /// Shows the factory's icon from `link`, fetching it into this Mac's cache when it isn't there yet;
    /// nil clears it (and the cache). The cached file's path goes on the saved factory, for the factory menu.
    private func showIcon(_ link: String?) {
        guard let server else { return }
        iconLink = link
        let folder = FactoryIcons.folder(for: server)
        guard let link, let id = FactoryIcons.id(link), let url = URL(string: link, relativeTo: server)?.absoluteURL else {
            icon = nil
            try? FileManager.default.removeItem(at: folder)
            setSavedIcon(nil, for: server)
            return
        }
        let file = folder.appending(path: id)
        if let image = FactoryIcons.image(file.path) {
            icon = image
            setSavedIcon(file.path, for: server)
            return
        }
        let gen = generation
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data),
                  gen == generation, iconLink == link else { return }
            // Only the newest image is kept.
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file)
            icon = image
            setSavedIcon(file.path, for: server)
        }
    }

    private func setSavedIcon(_ path: String?, for server: URL) {
        guard let index = savedFactories.firstIndex(where: { $0.id == SavedFactory.key(server) }), savedFactories[index].icon != path else { return }
        savedFactories[index].icon = path
    }

    /// The factory's limit for its icon.
    nonisolated static let maxIcon = 2 * 1024 * 1024

    /// Admins only: makes `data` (PNG, JPEG or WebP) the factory's icon; icon.updated brings it back.
    func upload(iconData data: Data) async throws {
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        guard data.count <= Self.maxIcon else { throw ClientError.message("The icon can be up to 2 MB.") }
        var request = URLRequest(url: server.appending(path: "/api/icon"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let _: Empty = try await Self.load(request)
    }

    /// Admins only: back to the letter tile.
    func removeIcon() async throws {
        let _: Empty = try await api("/api/icon", method: "DELETE")
    }

    /// The factory's limit for its name.
    nonisolated static let maxName = 60

    /// Admins only: names the factory (blank clears it); name.updated brings it back.
    func setName(_ name: String) async throws {
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        var request = URLRequest(url: server.appending(path: "/api/name"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        let _: Empty = try await Self.load(request)
    }

    /// Admins only: back to the GitHub org's name.
    func clearName() async throws {
        let _: Empty = try await api("/api/name", method: "DELETE")
    }

    /// Admins only: replaces `repo`'s worktree scripts (blank ones are cleared); repos.updated says how they were saved.
    func save(scripts: Wire.WorktreeScripts, for repo: String) {
        send(.reposScriptsSet(.init(repo: repo, scripts: scripts)))
    }

    /// Admins only: the other GitHub accounts whose installations of the app add repos; the server reads them again.
    func setRepoOwners(_ owners: [String]) {
        send(.reposOwnersSet(.init(owners: owners)))
    }

    /// `repo`'s worktree scripts, if it has any.
    func scripts(for repo: String) -> Wire.RepoWorktreeScripts? {
        repoScripts.first { $0.repo.lowercased() == repo.lowercased() }
    }

    /// Admins only: the whole list. A secret left blank keeps the stored value; connectors.updated echoes it.
    func save(connectors: [Wire.McpConnector]) {
        send(.connectorsSave(.init(connectors: connectors)))
    }

    func acceptRisk(goal name: String, upTo: RiskLevel?, note: String?) {
        guard let goal = goal(named: name) else { return }
        send(.goalAcceptRisk(.init(goal: goal.id, upTo: upTo.map(LiveAdapter.wireLevel), note: note)))
    }

    /// Keeps edits to notes here at once and saves each one half a second after its last change.
    func update(notes edited: [Note]) {
        for note in edited where notes.first(where: { $0.id == note.id }).map({ $0.title != note.title || $0.body != note.body || $0.taskID != note.taskID }) ?? true {
            unsaved[note.id]?.cancel()
            unsaved[note.id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, let me = self.me else { return }
                self.send(.noteSave(.init(note: LiveAdapter.wire(note, owner: me.login))))
                self.unsaved[note.id] = nil
            }
        }
        for gone in notes where !edited.contains(where: { $0.id == gone.id }) {
            // A save still waiting out its delay would otherwise go after the delete and bring the note back.
            unsaved[gone.id]?.cancel()
            unsaved[gone.id] = nil
            send(.noteDelete(.init(id: gone.id.uuidString.lowercased())))
        }
        notes = edited
    }

    /// The task this app is showing, told to teammates.
    private var viewing: String?

    func view(task id: String?) {
        guard id != viewing else { return }
        viewing = id
        send(.presence(.init(viewing: id)))
    }

    /// Puts who's online on the sidebar and who's looking at each task on it.
    private func applyPresence() {
        let people = online.map { (person: LiveAdapter.person($0.login, members: members), viewing: $0.viewing) }
        FactoryData.livePresence = server == nil ? nil : people
        // Only the tasks someone came to or left change, in one write: a ping that moves no one redraws nothing.
        let changes = Self.viewerChanges(factoryTasks, viewers: Self.viewers(online, me: me?.login, members: members))
        guard !changes.isEmpty else { return }
        var tasks = factoryTasks
        for change in changes { tasks[change.index].viewers = change.viewers }
        factoryTasks = tasks
    }

    /// The goal a view knows by name.
    func goal(named name: String) -> Wire.Goal? { goals.first { $0.name == name } }

    func send(_ message: Wire.ClientMessage) {
        guard let socket, let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Commands

    func openSession(machine: String, agent: String, cwd: String) {
        send(.sessionOpen(.init(machine: machine, agent: agent, cwd: cwd, cols: 120, rows: 36)))
    }

    func killSession(machine: String, id: String) {
        send(.sessionKill(.init(machine: machine, id: id)))
    }

    /// The commands to run on a new machine, with a fresh one-time code.
    func enrollment() async throws -> Enrollment {
        try await api("/api/machines/enroll", method: "POST")
    }

    /// Forgets a machine and revokes its token. Its owner or an admin.
    func removeMachine(_ id: String) async {
        do {
            let _: Empty = try await api("/api/machines/\(id)", method: "DELETE")
        } catch {
            notice = FactoryClient.describe(error)
        }
    }

    private struct Empty: Decodable {}

    /// A socket request for one session's terminal.
    func terminalRequest(machine: String, session: String, cols: Int, rows: Int) -> URLRequest? {
        guard let server, let token else { return nil }
        var components = URLComponents(url: Self.websocketURL(server, path: "/client/terminal"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "machine", value: machine), .init(name: "session", value: session),
            .init(name: "cols", value: String(cols)), .init(name: "rows", value: String(rows)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The factory's statistics over the last `days`; the answer lands in `stats`.
    func loadStats(days: Int, goal: String? = nil) {
        send(.statsGet(.init(days: UInt32(days), goal: goal)))
    }

    /// Reads a CI check's log from GitHub again; the answer (or a refusal) lands in `checkLogs`.
    func loadCheckLog(_ request: CheckLogRequest) {
        checkLogs[request.id] = .loading
        send(.taskCheckLog(.init(id: request.taskID, check: request.check)))
    }

    /// Drops a check's log once it's run again: the one held is the old run's.
    func forgetCheckLog(_ request: CheckLogRequest) {
        checkLogs[request.id] = nil
    }

    /// Each task's diff as last fetched, and the change it was fetched for.
    private(set) var diffs: [String: (key: String, files: [DiffFile])] = [:]

    /// Agent time per goal over the last week (`GET /api/usage/goals`).
    struct GoalTime: Decodable {
        struct TaskTime: Decodable { let id: String; let ms: Double }
        let goal: String
        let name: String
        let ms: Double
        let tasks: [TaskTime]
    }

    func goalTime() async -> [GoalTime] {
        (try? await api("/api/usage/goals")) ?? []
    }

    /// Fetches a task's diff unless the one held is for the same change (`key`).
    func loadDiff(task id: String, key: String) async {
        guard diffs[id]?.key != key, let server, let token else { return }
        var request = URLRequest(url: server.appending(path: "/api/tasks/\(id)/diff"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        diffs[id] = (key, DiffFile.parse(String(decoding: data, as: UTF8.self)))
    }

    /// Each task's GitHub review threads as last fetched, and the change they were fetched for.
    private(set) var threads: [String: (key: String, threads: [Wire.ReviewThread])] = [:]

    /// Fetches the review threads on a task's pull request unless the ones held are for the same
    /// change (`key`, as for the diff); `force` reads them again regardless.
    func loadThreads(task id: String, key: String, force: Bool = false) async {
        guard force || threads[id]?.key != key else { return }
        guard let found: [Wire.ReviewThread] = try? await api("/api/tasks/\(id)/threads") else { return }
        threads[id] = (key, found)
    }

    /// A file pasted or dropped into a brief or note, as the factory keeps it (`POST /api/attachments`).
    struct Attachment: Decodable {
        let id: String
        let name: String
        let mime: String
        let size: Int
        /// `/attachments/<id>/<name>`: what the note links to.
        let path: String
    }

    /// The factory's limit for one attachment.
    nonisolated static let maxAttachment = 25 * 1024 * 1024

    func upload(data: Data, filename: String, mime: String) async throws -> Attachment {
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        guard data.count <= Self.maxAttachment else { throw ClientError.message("It's over 25 MB.") }
        var components = URLComponents(url: server.appending(path: "/api/attachments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "name", value: filename)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await Self.load(request)
    }

    /// Attachments fetched this run, by path; they never change once stored. Screenshots and recordings
    /// add up, so it keeps at most 64 MB of them, each costing its size.
    private static let attachmentCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = attachmentCacheLimit
        return cache
    }()
    nonisolated static let attachmentCacheLimit = 64 * 1024 * 1024

    /// An attachment's bytes (`/attachments/…`), with this app's token: AsyncImage can't send one.
    func attachment(_ path: String) async throws -> Data {
        if let cached = Self.attachmentCache.object(forKey: path as NSString) { return cached as Data }
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        guard Self.attachmentLink(path) != nil, let url = URL(string: path, relativeTo: server)?.absoluteURL else {
            throw ClientError.message("Not an attachment.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClientError.message(status == 404 ? "It isn't there anymore." : "The server answered \(status).") }
        Self.attachmentCache.setObject(data as NSData, forKey: path as NSString, cost: data.count)
        return data
    }

    /// `/attachments/<uuid>/<name>`, as the server's LINK pattern has it: its id and name, or nil for
    /// anything else (`..`, other server paths), so the token never goes elsewhere.
    nonisolated static func attachmentLink(_ path: String) -> (id: String, name: String)? {
        guard let match = path.wholeMatch(of: /\/attachments\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([\w.\-]{1,120})/),
              !match.2.contains(".."), !match.2.hasPrefix(".") else { return nil }
        return (String(match.1), String(match.2))
    }

    /// Opened in their app with a click; anything else (scripts, .command, .app, .jar…) is only shown in Finder.
    nonisolated static let safeToOpen: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "pdf",
                                                      "txt", "log", "md", "json", "csv", "mp4", "mov", "webm"]

    /// Saves an attachment to a temporary folder, quarantined like a browser download, then opens it in
    /// its app if it's a known-safe type or shows it in Finder otherwise.
    func open(attachment path: String) async {
        do {
            guard let link = Self.attachmentLink(path) else { throw ClientError.message("Not an attachment.") }
            let data = try await attachment(path)
            let folder = FileManager.default.temporaryDirectory.appending(path: "maple-attachments/\(link.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: link.name)
            try data.write(to: file)
            Self.quarantine(file)
            if Self.safeToOpen.contains(file.pathExtension.lowercased()) {
                NSWorkspace.shared.open(file)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } catch {
            notice = Self.describe(error)
        }
    }

    /// Marks a file as downloaded (`com.apple.quarantine`), so Gatekeeper checks it before it runs.
    nonisolated static func quarantine(_ file: URL) {
        let stamp = String(format: "0083;%08x;Maple Factory;", Int(Date().timeIntervalSince1970))
        _ = file.withUnsafeFileSystemRepresentation { path in
            stamp.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
    }

    private func api<T: Decodable>(_ path: String, method: String = "GET") async throws -> T {
        guard let server, let token else { throw ClientError.message("Not signed in.") }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await Self.load(request)
    }

    // MARK: Before signing in

    struct Health: Decodable {
        let ok: Bool
        let protocolVersion: Int
        let org: String?
        /// "github", "dev" (a local server signs you in as its DEV_LOGIN) or "unconfigured".
        let signIn: String
        let devLogin: String?

        enum CodingKeys: String, CodingKey { case ok, org, signIn, devLogin, protocolVersion = "protocol" }
    }

    struct SignInResult: Decodable {
        var server: URL = URL(string: "about:blank")!
        let token: String
        let member: Wire.Member
        let org: String

        enum CodingKeys: String, CodingKey { case token, member, org }
    }

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: URL
        let interval: Int
        let expiresIn: Int
    }

    struct Enrollment: Decodable {
        let code: String
        let expiresAt: Double
        let commands: [String]
    }

    enum ClientError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }

    /// "localhost:8787" → http://localhost:8787; anything else is https unless it says otherwise.
    nonisolated static func serverURL(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasSuffix(".local") || text.contains(".local:")
            text = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    nonisolated static func websocketURL(_ server: URL, path: String) -> URL {
        var components = URLComponents(url: server.appending(path: path), resolvingAgainstBaseURL: false)!
        components.scheme = server.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    nonisolated static func probe(_ server: URL) async throws -> (Health, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        var request = URLRequest(url: server.appending(path: "/healthz"))
        request.timeoutInterval = 8
        let health: Health = try await load(request)
        return (health, clock.now - start)
    }

    /// `-devAs <login>` signs in as that member instead (made a plain member if they're new), for screenshots of what a non-admin sees.
    nonisolated static func devSignIn(_ server: URL) async throws -> SignInResult {
        var url = server.appending(path: "/dev/token")
        if let login = AppDefaults.string(forKey: "devAs"), !login.isEmpty { url.append(queryItems: [URLQueryItem(name: "as", value: login)]) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var result: SignInResult = try await load(request)
        result.server = server
        return result
    }

    nonisolated static func startDeviceFlow(_ server: URL) async throws -> DeviceCode {
        var request = URLRequest(url: server.appending(path: "/auth/device/start"))
        request.httpMethod = "POST"
        return try await load(request)
    }

    /// Nil while GitHub is still waiting on the person.
    nonisolated static func pollDeviceFlow(_ server: URL, code: String) async throws -> SignInResult? {
        var request = URLRequest(url: server.appending(path: "/auth/device/poll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceCode": code, "label": Host.current().localizedName ?? "Mac"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 202 { return nil }
        guard status == 200 else { throw ClientError.message(String(data: data, encoding: .utf8) ?? "Sign-in failed (\(status)).") }
        var result = try JSONDecoder().decode(SignInResult.self, from: data)
        result.server = server
        return result
    }

    nonisolated private static func load<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ClientError.message(text.isEmpty || text.hasPrefix("<") ? "The server answered \(status)." : text)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.message("That doesn't look like a Maple factory.")
        }
    }

    nonisolated static let tooNewMessage = "This factory is newer than this app — update Maple Factory."

    nonisolated static func describe(_ error: Error, response: URLResponse? = nil) -> String {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { return "Your sign-in expired." }
        if error is DecodingError { return tooNewMessage }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "Can't reach the factory."
        case NSURLErrorNotConnectedToInternet: return "You're offline."
        case NSURLErrorTimedOut: return "The factory took too long to answer."
        case NSURLErrorNetworkConnectionLost: return "The connection dropped."
        default: return (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        }
    }
}

/// A factory signed into on this Mac. Its token is in the Keychain under `server`.
struct SavedFactory: Codable, Equatable, Identifiable, Sendable {
    var server: URL
    var org: String
    /// The org's name, or the host when it has none.
    var name: String
    var lastUsed: Date
    /// The factory's icon as this Mac last cached it (a file path); nil shows the letter tile.
    var icon: String? = nil

    var id: String { Self.key(server) }
    var host: String { id }

    /// One entry per host and port: http and https to the same place are the same factory.
    static func key(_ url: URL) -> String { "\(url.host() ?? "")\(url.port.map { ":\($0)" } ?? "")" }
}

/// Where factory icons are cached: Application Support/Maple Factory/Factory Icons/<host:port>/<id>,
/// one image per factory (a headless run keeps its own, in its temporary folder).
enum FactoryIcons {
    static func folder(for server: URL) -> URL {
        let base = Headless.isOn
            ? FileManager.default.temporaryDirectory.appending(path: Headless.suiteName)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Maple Factory")
        return base.appending(path: "Factory Icons").appending(path: SavedFactory.key(server))
    }

    /// The id in `/icon/<uuid>`, or nil for anything else.
    static func id(_ link: String) -> String? {
        link.wholeMatch(of: /\/icon\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/).map { String($0.1) }
    }

    @MainActor private static var images: [String: NSImage] = [:]

    /// The cached image at `path`, read once per run.
    @MainActor static func image(_ path: String) -> NSImage? {
        if let image = images[path] { return image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images[path] = image
        return image
    }
}

/// The saved-factory list's rules, kept pure so they can be tested; stored in defaults under `factories`.
enum SavedFactories {
    static let defaultsKey = "factories"

    static func load(_ defaults: UserDefaults = AppDefaults) -> [SavedFactory]? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([SavedFactory].self, from: $0) }
    }

    static func store(_ list: [SavedFactory], _ defaults: UserDefaults = AppDefaults) {
        defaults.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
    }

    /// The list as saved, or, before there was one, the single factory this Mac was signed into.
    static func migrate(_ saved: [SavedFactory]?, currentURL: String?, currentOrg: String?, now: Date = Date()) -> [SavedFactory] {
        if let saved { return saved }
        guard let currentURL, let url = URL(string: currentURL), url.host() != nil else { return [] }
        let org = currentOrg ?? ""
        let name = org.isEmpty || org == "local" ? url.host() ?? "Factory" : org
        return [SavedFactory(server: url, org: org, name: name, lastUsed: now)]
    }

    /// Adds the factory, or replaces the entry for the same host and port where it stands.
    static func upsert(_ factory: SavedFactory, into list: [SavedFactory]) -> [SavedFactory] {
        var list = list
        if let index = list.firstIndex(where: { $0.id == factory.id }) {
            list[index] = factory
        } else {
            list.append(factory)
        }
        return list
    }

    static func remove(_ server: URL, from list: [SavedFactory]) -> [SavedFactory] {
        list.filter { $0.id != SavedFactory.key(server) }
    }

    /// The factory to open after signing out of one: the most recently used of those left.
    static func fallback(_ list: [SavedFactory]) -> SavedFactory? {
        list.max { $0.lastUsed < $1.lastUsed }
    }
}

/// The factory token, in the login keychain under the factory's URL. A plain-http (local dev)
/// factory's token goes in defaults instead: every rebuild of an unsigned dev app would otherwise
/// ask for keychain access, and a localhost dev token guards nothing. A headless run keeps every
/// token in its own wiped defaults, so it never replaces the real app's keychain item for a URL.
enum Keychain {
    private static let service = "dev.maplefactory.app"
    private static let devKey = "devFactoryTokens"

    static func isDev(_ account: String, headless: Bool = Headless.isOn) -> Bool { headless || account.hasPrefix("http://") }

    static func read(account: String) -> String? {
        if isDev(account) { return (AppDefaults.dictionary(forKey: devKey) as? [String: String])?[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        if isDev(account) {
            var tokens = AppDefaults.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = value
            AppDefaults.set(tokens, forKey: devKey)
            return
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(account: String) {
        if isDev(account) {
            var tokens = AppDefaults.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = nil
            AppDefaults.set(tokens, forKey: devKey)
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

extension FactoryClient {
    /// Whether the machine's runner is older than the latest release ("0.2.0" < "0.10.1").
    func runnerOutdated(_ machine: Wire.Machine) -> Bool {
        guard let version = machine.version, let latest = runnerLatest else { return false }
        return Self.version(version, isOlderThan: latest)
    }

    /// Compares release numbers only ("0.2.0" < "0.10.1"); a prerelease counts as its release.
    static func version(_ a: String, isOlderThan b: String) -> Bool {
        let parts = { (v: String) in v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q }
        }
        return false
    }

    /// The releases after `version` up to `through` (the latest, by default), newest first: what an
    /// update from `version` brings. Every release up to `through` when `version` is nil.
    func releases(newerThan version: String?, through: String? = nil) -> [Wire.RunnerRelease] {
        Self.releases(runnerReleases, newerThan: version, through: through ?? runnerLatest)
    }

    static func releases(_ all: [Wire.RunnerRelease], newerThan version: String?, through: String?) -> [Wire.RunnerRelease] {
        all.filter { release in
            (version.map { Self.version($0, isOlderThan: release.version) } ?? true)
                && (through.map { !Self.version($0, isOlderThan: release.version) } ?? true)
        }
        .sorted { Self.version($1.version, isOlderThan: $0.version) }
    }

    /// The release a machine runs, when the changelog has it.
    func release(_ version: String?) -> Wire.RunnerRelease? {
        version.flatMap { v in runnerReleases.first { $0.version == v } }
    }

    static func loginKey(_ machine: String, _ agent: String) -> String { "\(machine):\(agent)" }

    func agentLogin(machine: String, agent: String) -> Wire.AgentLoginStatus? {
        agentLogins[Self.loginKey(machine, agent)]
    }

    /// Signs one of your machine's agents in: its card shows the link and code the machine sends back.
    func signIn(machine: String, agent: String) {
        let key = Self.loginKey(machine, agent)
        agentLogins[key] = .init(agent: agent, state: .starting)
        send(.machineAgentLogin(.init(machine: machine, agent: agent)))
        // A machine that never answers (offline, an older runner) mustn't leave it starting forever.
        Task {
            try? await Task.sleep(for: .seconds(20))
            if agentLogins[key]?.state == .starting {
                agentLogins[key] = .init(agent: agent, state: .failed, message: "The machine didn't answer. Is its runner up to date?")
            }
        }
    }

    func cancelSignIn(machine: String, agent: String) {
        agentLogins[Self.loginKey(machine, agent)] = nil
        send(.machineAgentLogin(.init(machine: machine, agent: agent, cancel: true)))
    }

    /// Closes a finished sign-in's panel.
    func dismissSignIn(machine: String, agent: String) {
        let key = Self.loginKey(machine, agent)
        if let state = agentLogins[key]?.state, state != .starting, state != .waiting { agentLogins[key] = nil }
    }

    /// What the runner menu item does: install a newer release the app knows of, or only look for one.
    enum RunnerAction: Equatable {
        case check
        case update(String)
    }

    func runnerAction(_ machine: Wire.Machine) -> RunnerAction {
        Self.runnerAction(machine, latest: runnerLatest)
    }

    static func runnerAction(_ machine: Wire.Machine, latest: String?) -> RunnerAction {
        guard let version = machine.version, let latest, Self.version(version, isOlderThan: latest) else { return .check }
        return .update(latest)
    }

    /// Runs the runner menu item: a check never installs anything, so it doesn't need the machine online.
    func perform(_ action: RunnerAction, on machine: Wire.Machine) {
        switch action {
        case .check: send(.runnerCheck(.init(machine: machine.id)))
        case .update: send(.machineUpdate(.init(machine: machine.id)))
        }
    }

    /// Where a machine's runner update is, as its card and Settings › Runner show it.
    func updatePhase(_ machine: Wire.Machine) -> RunnerUpdatePhase {
        Self.updatePhase(machine, latest: runnerLatest)
    }

    /// What the machine's sidebar row shows about its runner: a newer release, or an update under way.
    /// Nothing while it's offline, where the offline icon says enough.
    static func sidebarUpdateBadge(_ machine: Wire.Machine, latest: String?) -> SidebarUpdateBadge? {
        guard machine.online else { return nil }
        let phase = updatePhase(machine, latest: latest)
        if case .outdated(let version) = phase { return .available(version) }
        return phase.isBusy ? .updating : nil
    }

    static func updatePhase(_ machine: Wire.Machine, latest: String?) -> RunnerUpdatePhase {
        let outdated = { () -> RunnerUpdatePhase in
            guard let version = machine.version, let latest, Self.version(version, isOlderThan: latest) else { return .current }
            return .outdated(latest)
        }
        guard let update = machine.update else { return outdated() }
        switch update.state {
        case .checking: return .checking
        case .installing: return .installing(update.target)
        // Offline here is the runner swapping itself out, not the machine gone.
        case .restarting: return .restarting(update.target)
        case .updated: return machine.online ? .updated(update.target ?? machine.version ?? "", from: update.from) : outdated()
        case .upToDate: return outdated() == .current ? .upToDate(machine.version ?? update.target) : outdated()
        case .failed: return .failed(update.message, target: update.target)
        case .other: return outdated()
        }
    }
}

/// A machine's runner in its sidebar row.
enum SidebarUpdateBadge: Equatable {
    /// This newer release is out.
    case available(String)
    /// Checking, installing or restarting.
    case updating

    /// The line it adds to the row's tooltip.
    var helpLine: String {
        switch self {
        case .available(let version): "Runner update available: \(version)"
        case .updating: "Updating its runner…"
        }
    }
}

/// A machine's runner, as far as updating it goes.
enum RunnerUpdatePhase: Equatable {
    /// On the latest release (or there's none to compare with), nothing in flight.
    case current
    /// A newer release is out.
    case outdated(String)
    case checking
    case installing(String?)
    /// Swapping itself out: offline for a moment, sessions still running in tmux.
    case restarting(String?)
    /// Came back on `version`, from `from` when known.
    case updated(String, from: String?)
    /// Asked, and it already runs the latest.
    case upToDate(String?)
    case failed(String?, target: String?)

    /// Checking, installing or restarting: no second update until it's done.
    var isBusy: Bool {
        switch self {
        case .checking, .installing, .restarting: true
        default: false
        }
    }

    /// The line the card shows while it's busy.
    var progressText: String? {
        switch self {
        case .checking: "Checking for a runner update…"
        case .installing(let v): "Installing runner \(v ?? "update")…"
        case .restarting(let v): "Restarting into runner \(v ?? "the update")… (sessions keep running)"
        default: nil
        }
    }
}

extension FactoryClient {
    /// This Mac's machine in this factory, when its runner is enrolled here.
    var thisMac: Wire.Machine? {
        guard let server, LocalRunner.isEnrolled(with: server), let id = LocalRunner.enrolled?.runnerId else { return nil }
        return machines.first { $0.id == id }
    }
}

extension FactoryClient {
    /// A machine's nickname (or id, when it has none or isn't known).
    func machineName(_ id: String) -> String {
        machines.first { $0.id == id }?.name ?? id
    }
}

extension FactoryClient {
    /// What the task's worker session is doing, from its machine's live sessions: nil when there's no
    /// worker, its machine isn't known, or the machine doesn't list that session.
    func workerActivity(for worker: FactoryTask.Worker?) -> Wire.Activity? {
        Self.workerActivity(for: worker, in: machines)
    }

    static func workerActivity(for worker: FactoryTask.Worker?, in machines: [Wire.Machine]) -> Wire.Activity? {
        guard let worker else { return nil }
        return machines.first { $0.id == worker.machine }?.sessions.first { $0.session.id == worker.session }?.activity ?? nil
    }

    /// Answers the permission prompt the task's worker is waiting on: Yes or No in its session.
    func answerPrompt(taskID: String, choice: Wire.PromptChoice) {
        send(.taskAnswerPrompt(.init(id: taskID, choice: choice)))
    }
}

/// What a waiting agent wants permission for, from the runner's `question.permission`.
struct PermissionPrompt: Equatable {
    let tool: String
    let summary: String
    let detail: String?
    let warning: String?
}

extension Wire.Activity {
    /// The permission prompt it's stopped at, when it's waiting on one.
    var permission: PermissionPrompt? {
        guard state == .waiting, case .object(let q)? = question, case .object(let p)? = q["permission"], case .string(let tool)? = p["tool"] else { return nil }
        let text = { (key: String) -> String? in
            if case .string(let s)? = p[key], !s.isEmpty { return s }
            return nil
        }
        return PermissionPrompt(tool: tool, summary: text("summary") ?? tool, detail: text("detail"), warning: text("warning"))
    }
}
