import SwiftUI

// MARK: Model

/// A computer that runs agent sessions. Its owner decides how many slots the team can use;
/// the rest only run the owner's own tasks.
struct Machine: Identifiable {
    enum Kind {
        case laptop, desktop, mini

        var icon: String {
            switch self {
            case .laptop: "laptopcomputer"
            case .desktop: "macstudio"
            case .mini: "macmini"
            }
        }
    }

    enum Status: Equatable {
        case online, onBattery, sleeping
        /// Dropped off mid-flight: lid closed, Wi-Fi lost, crashed.
        case offline(since: String)

        var title: String {
            switch self {
            case .online: "Online"
            case .onBattery: "On battery"
            case .sleeping: "Asleep"
            case .offline(let since): "Offline · \(since)"
            }
        }

        var color: Color {
            switch self {
            case .online: Theme.State.merged
            case .onBattery: Theme.State.awaitingApproval
            case .sleeping: Theme.textFaint
            case .offline: Theme.State.cancelled
            }
        }

        var isOffline: Bool { if case .offline = self { true } else { false } }
        /// Can take new work right now.
        var accepting: Bool { self == .online || self == .onBattery }
    }

    var id: String
    let kind: Kind
    let model: String
    let owner: Person
    var status: Status
    var capacity: Int
    /// Slots anyone on the team can fill. The rest are the owner's.
    var teamSlots: Int
    /// Let team work borrow idle personal slots (it finishes before the owner needs them back).
    var lendIdle: Bool
    var sessions: [Session]
    /// Secrets only this machine holds, so some tasks can only run here.
    var secrets: [String] = []
    /// Per-account caps: past these, the factory stops starting new sessions here.
    var limits: [UsageLimit] = []
    var limitScope: UsageLimit.Scope = .all
    /// CPU and memory pressure right now, 0...1.
    var load: Double = 0.4
    /// Above this, the machine stops picking up teammates' work. Its owner's tasks can still start.
    var loadCap: Double = 0.85

    var highLoad: Bool { load >= loadCap }
    /// Set while the owner has paused new work here.
    var pause: Pause? = nil
    /// Online, not paused: can start new sessions.
    var takingWork: Bool { status.accepting && pause == nil }

    struct Pause {
        /// "1:15 AM", "tomorrow 9 AM", or nil until resumed by hand.
        let until: String?
        /// Teammates' sessions were handed to other machines instead of finishing here.
        let handedOff: Bool
    }

    var personalSlots: Int { capacity - teamSlots }
    var teamUsed: Int { sessions.filter { $0.kind == .team }.count }
    var lentUsed: Int { sessions.filter { $0.kind == .lent }.count }
    var personalUsed: Int { sessions.filter { $0.kind == .personal }.count + lentUsed }
    var freeTeam: Int { max(teamSlots - teamUsed, 0) }
    var freePersonal: Int { max(personalSlots - personalUsed, 0) }
    var canLend: Bool { lendIdle && status == .online }
    var stranded: [Session] { sessions.filter { $0.stranded != nil } }
    var isMine: Bool { owner.id == FactoryData.me.id }
}

/// One agent working one task in one slot.
struct Session: Identifiable {
    enum Kind { case personal, team, lent }

    let taskID: String
    var kind: Kind
    var elapsed: String
    /// Review passes run as their own sessions under the review agent.
    var isReview = false
    /// Set when the machine dropped off while this session was running.
    var stranded: Stranded? = nil
    var id: String { taskID + (isReview ? "-review" : "") }
}

/// How much of an account's plan the factory may use on a machine, leaving the rest for its owner.
struct UsageLimit: Identifiable {
    enum Scope: String, CaseIterable {
        case all = "All factory work"
        case team = "Only teammates' work"
    }

    let accountID: String
    /// Share of the 5-hour session; nil when off or the plan has no session window.
    var session: Double?
    /// Share of the weekly limit; nil when off.
    var weekly: Double?
    var id: String { accountID }
}

/// What survives a machine going dark: agents push a checkpoint after every plan step,
/// so a session can pick up on another machine from the last one.
struct Stranded {
    let lastSeen: String
    let checkpoint: String
    /// Work done since the checkpoint that only exists on the dark machine.
    let unpushed: String?
    /// Team sessions move on their own after the grace period; personal ones wait for the owner.
    let autoResumeIn: String?
}

/// Approved work waiting for a slot. Each machine takes its owner's tasks first,
/// then tasks teammates marked shareable.
struct QueuedTask: Identifiable {
    let taskID: String
    /// A secret only some machines hold, e.g. Stripe test keys.
    var requires: String? = nil
    let approved: String
    var id: String { taskID }
}

extension FactoryData {
    static let seedMachines: [Machine] = [
        Machine(id: "factory-mini", kind: .mini, model: "Mac mini · M4 Pro", owner: me, status: .online,
                capacity: 4, teamSlots: 4, lendIdle: false,
                sessions: [
                    Session(taskID: "ATL-144", kind: .team, elapsed: "52m"),
                    Session(taskID: "BIL-93", kind: .team, elapsed: "38m"),
                    Session(taskID: "ATL-158", kind: .team, elapsed: "24m"),
                    Session(taskID: "DOC-5", kind: .team, elapsed: "1h 20m"),
                ],
                secrets: ["Stripe test keys", "Litmus"],
                limits: [UsageLimit(accountID: "claude-andrea", session: 0.8, weekly: 0.8)], limitScope: .team,
                load: 0.64),
        Machine(id: "mbp-14", kind: .laptop, model: "MacBook Pro 14″", owner: me, status: .onBattery,
                capacity: 3, teamSlots: 1, lendIdle: true,
                sessions: [
                    Session(taskID: "ONB-21", kind: .personal, elapsed: "11m"),
                    Session(taskID: "ATL-149", kind: .team, elapsed: "17m"),
                ],
                limits: [UsageLimit(accountID: "claude-andrea", session: 0.6, weekly: 0.7)],
                load: 0.88, loadCap: 0.8),
        Machine(id: "chris-studio", kind: .desktop, model: "Mac Studio · M3 Ultra", owner: chris, status: .online,
                capacity: 4, teamSlots: 2, lendIdle: false,
                sessions: [
                    Session(taskID: "ATL-160", kind: .team, elapsed: "31m"),
                    Session(taskID: "ATL-150", kind: .team, elapsed: "6m", isReview: true),
                    Session(taskID: "DOC-6", kind: .personal, elapsed: "44m"),
                    Session(taskID: "BIL-91", kind: .personal, elapsed: "2h 5m"),
                ],
                limits: [UsageLimit(accountID: "claude-chris", session: 0.75, weekly: 0.9)],
                load: 0.71),
        Machine(id: "chris-mbp", kind: .laptop, model: "MacBook Air 13″", owner: chris, status: .offline(since: "7m"),
                capacity: 2, teamSlots: 1, lendIdle: false,
                sessions: [
                    Session(taskID: "DOC-7", kind: .team, elapsed: "48m",
                            stranded: Stranded(lastSeen: "7m ago", checkpoint: "Step 2 of 5 · pushed 9m ago",
                                               unpushed: "~40 lines in step 3", autoResumeIn: "3m")),
                ],
                limits: [UsageLimit(accountID: "claude-chris", session: nil, weekly: 0.9)],
                load: 0),
    ]

    static let seedQueue: [QueuedTask] = [
        QueuedTask(taskID: "BIL-95", requires: "Stripe test keys", approved: "18m"),
        QueuedTask(taskID: "ONB-24", approved: "9m"),
        QueuedTask(taskID: "PRF-15", approved: "4m"),
    ]

    /// Approved tasks that haven't started yet because every eligible slot is busy,
    /// plus one whose machine went dark mid-build.
    static let queuedTasks: [FactoryTask] = [
        FactoryTask(id: "DOC-7", goal: "Docs site", title: "Version switcher for the docs", state: .building,
                    agent: agents[2], owner: chris, detail: "Machine offline · resumes in 3m", progress: 0.4, span: 9...16, updated: "7m",
                    brief: "Let readers switch between v1 and v2 docs without losing their place.",
                    plan: [
                        PlanStep(text: "Add version to the docs route", file: "app/docs/[version]/layout.tsx", progress: .done),
                        PlanStep(text: "Version switcher component", file: "components/docs/VersionSwitcher.tsx", progress: .done),
                        PlanStep(text: "Map pages between versions", file: "lib/docs/versions.ts", progress: .active),
                        PlanStep(text: "Redirect missing pages to the version index", file: "middleware.ts"),
                        PlanStep(text: "Tests for the page map", file: "tests/docs/versions.test.ts"),
                    ],
                    activity: [
                        ActivityItem(who: "Maple-3", text: "Lost contact with chris-mbp", when: "7m"),
                        ActivityItem(who: "Maple-3", text: "Pushed checkpoint after step 2", when: "9m"),
                    ],
                    footprint: (7, 290, false)),
        FactoryTask(id: "BIL-95", goal: "Billing v2", title: "Dunning emails for failed payments", state: .building,
                    agent: agents[1], owner: chris, detail: "Queued · needs Stripe keys", span: 11...17, updated: "18m",
                    brief: "Email customers on the 1st, 3rd and 7th day after a payment fails, then pause the workspace.",
                    footprint: (5, 240, true), areas: ["Billing"]),
        FactoryTask(id: "ONB-24", goal: "Onboarding revamp", title: "Empty states for new workspaces", state: .building,
                    agent: agents[2], owner: chris, detail: "Queued · next team slot", span: 11...14, updated: "9m",
                    brief: "Friendly empty states with a next step for goals, inbox and scratchpad.",
                    footprint: (6, 210, true)),
        FactoryTask(id: "PRF-15", goal: "Performance budget", title: "Lazy-load the editor on the remaining 9 routes", state: .building,
                    agent: agents[0], owner: chris, detail: "Queued · Chris's machines", span: 11...15, updated: "4m",
                    brief: "Follow-up split out of PRF-12.", footprint: (11, 330, true), splitFrom: "PRF-12"),
    ]

    /// Tasks their owners let run in teammates' team slots. Everything else stays on the owner's machines.
    /// Tasks that are part of a bigger effort.
    static let seedEfforts: [String: String] = [
        "ATL-136": "Login revamp", "ATL-138": "Login revamp", "ATL-149": "Login revamp", "ATL-152": "Login revamp", "ATL-163": "Login revamp",
        "BIL-91": "Stripe hardening", "BIL-85": "Stripe hardening",
    ]

    /// Tasks that build only once others merge: the Login revamp lands in order.
    static let seedAfter: [String: [String]] = [
        "ATL-152": ["ATL-149", "ATL-163"],
    ]

    static let seedShareable: Set<String> = [
        "ATL-144", "ATL-149", "ATL-150", "ATL-158", "ATL-160", "BIL-93", "BIL-95", "DOC-5", "DOC-7", "ONB-21", "ONB-24",
    ]
}

// MARK: Scheduling

extension AppState {
    var queuedIDs: Set<String> { Set(queue.map(\.taskID)) }

    func session(for taskID: String) -> (machine: Machine, session: Session)? {
        for machine in machines {
            if let session = machine.sessions.first(where: { $0.taskID == taskID && !$0.isReview }) {
                return (machine, session)
            }
        }
        return nil
    }

    var fleet: (slots: Int, team: Int, running: Int, teamUsed: Int) {
        let online = machines.filter { $0.status.accepting }
        return (online.map(\.capacity).reduce(0, +),
                online.map(\.teamSlots).reduce(0, +),
                online.map(\.sessions.count).reduce(0, +),
                online.map(\.teamUsed).reduce(0, +))
    }

    /// Why a queued task is still waiting, in words.
    func waitingReason(_ item: QueuedTask) -> String {
        let task = task(item.taskID)
        let whose = task.owner.id == FactoryData.me.id ? "your" : "\(task.owner.firstName)'s"
        if let secret = item.requires {
            let holders = machines.filter { $0.secrets.contains(secret) }
            let names = holders.map(\.id).joined(separator: ", ")
            return "Only \(names) has \(secret), and it's full."
        }
        let own = machines.filter { $0.owner.id == task.owner.id }
            .map { machine in
                switch machine.status {
                case .offline: "\(machine.id) is offline"
                case .sleeping: "\(machine.id) is asleep"
                default: machine.pause != nil ? "\(machine.id) is paused"
                    : limitHit(machine) != nil ? "\(machine.id) is at its usage limit" : "\(machine.id) is full"
                }
            }
            .joined(separator: ", ")
        let busyWithFreeSlots = machines.filter { $0.takingWork && $0.highLoad && ($0.freeTeam > 0 || ($0.canLend && $0.freePersonal > 0)) }
        if task.shareable, let busy = busyWithFreeSlots.first {
            return "Shareable, but \(whose) machines are busy (\(own)). \(busy.id) has a free team slot but is under heavy load (\(Int(busy.load * 100))%), so it isn't taking team work."
        }
        return task.shareable
            ? "Shareable, but \(whose) machines are busy (\(own)) and every team slot is taken."
            : "Not shareable, so it waits for \(whose) machines: \(own)."
    }

    /// The first usage cap this machine has hit, if any, in words.
    func limitHit(_ machine: Machine) -> String? {
        for limit in machine.limits {
            guard let account = FactoryData.usageAccounts.first(where: { $0.id == limit.accountID }) else { continue }
            if let cap = limit.session, let window = account.sessionWindow, window.used >= cap {
                return "\(account.product.name) session at \(Int(window.used * 100))% (limit \(Int(cap * 100))%) · resets \(window.resetsAt)"
            }
            if let cap = limit.weekly, let window = account.weekWindow, window.used >= cap {
                return "\(account.product.name) week at \(Int(window.used * 100))% (limit \(Int(cap * 100))%) · resets \(window.resetsAt)"
            }
        }
        return nil
    }

    /// Whether a usage cap stops this machine from starting a task from this owner.
    private func blockedByLimit(_ machine: Machine, ownerID: String) -> Bool {
        guard limitHit(machine) != nil else { return false }
        return machine.limitScope == .all || ownerID != machine.owner.id
    }

    func saveMachine(_ machine: Machine) {
        withAnimation(.snappy(duration: 0.3)) {
            if let index = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[index] = machine
            } else {
                machines.append(machine)
            }
        }
        showToast("\(machine.id) saved · \(machine.capacity) slots, \(machine.teamSlots) for the team", icon: "cpu")
        dispatch()
    }

    /// Stops a machine from starting new sessions. Running ones finish their task, unless `handOff`
    /// moves teammates' sessions to another machine after their current step.
    func pauseMachine(_ machineID: String, until: String?, handOff: Bool = false) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else { return }
        let owner = machines[index].owner.id
        let movable = handOff ? machines[index].sessions.filter { !$0.isReview && task($0.taskID).owner.id != owner } : []

        withAnimation(.snappy(duration: 0.3)) {
            machines[index].pause = Machine.Pause(until: until, handedOff: handOff)
            machines[index].sessions.removeAll { session in movable.contains { $0.id == session.id } }
            queue.insert(contentsOf: movable.map { QueuedTask(taskID: $0.taskID, approved: "now") }, at: 0)
        }
        for session in movable {
            update(session.taskID) { task in
                task.detail = "Handing off · resumes elsewhere"
                task.activity.insert(ActivityItem(who: task.agent?.name ?? "Agent", text: "Checkpointed and left \(machineID) (paused by its owner)", when: "now"), at: 0)
            }
        }
        showToast("\(machineID) paused\(until.map { " until \($0)" } ?? "")\(movable.isEmpty ? "" : " · handed off \(movable.count) team session\(movable.count == 1 ? "" : "s")")",
                  icon: "pause.circle.fill", color: Theme.State.awaitingApproval)
        dispatch()
    }

    func resumeMachine(_ machineID: String) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else { return }
        withAnimation(.snappy(duration: 0.3)) { machines[index].pause = nil }
        showToast("\(machineID) is taking work again", icon: "play.circle.fill", color: Theme.State.merged)
        dispatch()
    }

    func setShareable(_ id: String, _ shareable: Bool) {
        if let client, isLive {
            client.send(.taskEdit(.init(id: id, title: nil, brief: nil, shareable: shareable)))
            showToast(shareable ? "\(id) can use team slots now" : "\(id) will only run on its owner's machines",
                      icon: shareable ? "person.3.fill" : "lock.fill")
            return
        }
        update(id) { task in
            task.shareable = shareable
            task.activity.insert(ActivityItem(who: FactoryData.me.name,
                                              text: shareable ? "Let it run on teammates' machines" : "Kept it to their own machines", when: "now"), at: 0)
        }
        showToast(shareable ? "\(id) can use team slots now" : "\(id) will only run on its owner's machines",
                  icon: shareable ? "person.3.fill" : "lock.fill")
        dispatch()
    }

    /// A live task whose machine went offline, was paused or removed while it was mid-flight.
    func liveStranded(_ taskID: String) -> (name: String, why: String, lastSeen: UInt64?)? {
        guard isLive, let client else { return nil }
        let task = task(taskID)
        guard let id = task.machine, [.planning, .building, .reviewing].contains(task.state), task.hand == nil else { return nil }
        guard let machine = client.machines.first(where: { $0.id == id }) else { return (id, "was removed", nil) }
        if !machine.online { return (machine.name, "went offline", machine.lastSeen) }
        if machine.settings?.paused == true { return (machine.name, "was paused", nil) }
        return nil
    }

    func stranded(_ taskID: String) -> (machine: Machine, session: Session)? {
        if isLive { return nil }
        guard let found = session(for: taskID), found.session.stranded != nil else { return nil }
        return found
    }

    /// Demo switch: pretend a machine's lid closed (or opened again).
    func toggleOffline(_ machineID: String) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else { return }
        let goingDark = !machines[index].status.isOffline
        withAnimation(.snappy(duration: 0.3)) {
            machines[index].status = goingDark ? .offline(since: "now") : .online
            for s in machines[index].sessions.indices {
                let session = machines[index].sessions[s]
                machines[index].sessions[s].stranded = goingDark
                    ? Stranded(lastSeen: "just now", checkpoint: "Last step pushed 3m ago",
                               unpushed: session.kind == .personal ? nil : "~25 lines",
                               autoResumeIn: session.kind == .personal ? nil : "10m")
                    : nil
            }
        }
        for session in machines[index].sessions where !session.isReview {
            update(session.taskID) { task in
                task.detail = goingDark
                    ? (session.kind == .personal ? "Machine offline · waiting for it" : "Machine offline · resumes elsewhere in 10m")
                    : "Back online"
                task.activity.insert(ActivityItem(who: task.agent?.name ?? "Agent",
                                                  text: goingDark ? "Lost contact with \(machineID)" : "Reconnected to \(machineID)", when: "now"), at: 0)
            }
        }
        showToast(goingDark ? "\(machineID) went offline · \(machines[index].sessions.count) sessions paused" : "\(machineID) is back online",
                  icon: goingDark ? "wifi.slash" : "wifi", color: goingDark ? Theme.State.cancelled : Theme.State.merged)
    }

    /// Moves a stranded session off its dark machine: it re-queues at the front and resumes from the checkpoint.
    func resumeElsewhere(_ taskID: String) {
        if let client, isLive {
            client.send(.taskMove(.init(id: taskID)))
            showToast("\(taskID) moves to the next free machine\(task(taskID).pushed == nil ? "" : " · carries on from its last push")",
                      icon: "arrow.uturn.forward.circle.fill", color: Theme.State.building)
            return
        }
        guard let found = session(for: taskID),
              let index = machines.firstIndex(where: { $0.id == found.machine.id }) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            machines[index].sessions.removeAll { $0.taskID == taskID }
            queue.insert(QueuedTask(taskID: taskID, approved: "now"), at: 0)
        }
        update(taskID) { task in
            task.detail = "Queued · resuming from checkpoint"
            task.activity.insert(ActivityItem(who: FactoryData.me.name, text: "Moved it off \(found.machine.id) to resume elsewhere", when: "now"), at: 0)
        }
        showToast("\(taskID) is first in the queue · resumes from its last checkpoint", icon: "arrow.uturn.forward.circle.fill", color: Theme.State.building)
        dispatch()
    }

    func setTeamSlots(_ machineID: String, to count: Int) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else { return }
        let used = machines[index].sessions.filter { $0.kind == .personal }.count
        machines[index].teamSlots = min(max(count, 0), machines[index].capacity - used)
        dispatch()
    }

    func setLendIdle(_ machineID: String, _ on: Bool) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else { return }
        machines[index].lendIdle = on
        dispatch()
    }

    /// Fills free slots from the queue. Each machine takes its owner's own tasks first (personal slots,
    /// then team slots); team slots and lendable idle slots then take teammates' shareable tasks.
    func dispatch() {
        var started: [(String, String)] = []
        var placed = true
        while placed {
            placed = false
            for index in machines.indices where machines[index].takingWork {
                let machine = machines[index]
                let eligible = queue.filter { item in
                    (item.requires.map { machine.secrets.contains($0) } ?? true)
                        && !blockedByLimit(machine, ownerID: task(item.taskID).owner.id)
                }
                var pick: (QueuedTask, Session.Kind)?

                if machine.freePersonal > 0 || machine.freeTeam > 0,
                   let own = eligible.first(where: { task($0.taskID).owner.id == machine.owner.id }) {
                    pick = (own, machine.freePersonal > 0 ? .personal : .team)
                } else if !machine.highLoad,
                          let shared = eligible.first(where: { task($0.taskID).shareable && task($0.taskID).owner.id != machine.owner.id }) {
                    if machine.freeTeam > 0 {
                        pick = (shared, .team)
                    } else if machine.canLend, machine.freePersonal > 0 {
                        pick = (shared, .lent)
                    }
                }

                guard let (item, kind) = pick else { continue }
                withAnimation(.snappy(duration: 0.35)) {
                    machines[index].sessions.append(Session(taskID: item.taskID, kind: kind, elapsed: "now"))
                    queue.removeAll { $0.taskID == item.taskID }
                }
                startQueued(item.taskID)
                started.append((item.taskID, machine.id))
                placed = true
                break
            }
        }
        if let (taskID, machine) = started.first {
            showToast("\(taskID) started on \(machine)\(started.count > 1 ? " · +\(started.count - 1) more" : "")",
                      icon: "play.circle.fill", color: Theme.State.building)
        }
    }
}
