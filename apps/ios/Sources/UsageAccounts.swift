import Foundation
import MapleKit

/// One rate-limit window on a plan, e.g. the 5-hour session or the 7-day week.
struct PlanWindow: Identifiable, Equatable {
    /// "Current session", "This week", "This week · Fable".
    let label: String
    /// "5h", "7d", "spend".
    let span: String
    /// 0...1.
    let used: Double
    let resetsIn: String
    let resetsAt: String
    /// How far through the window we are (0...1).
    let elapsed: Double
    /// When it runs dry at this pace, if before it resets.
    let runsOutAt: String?
    var id: String { label }

    var runsOutEarly: Bool { runsOutAt != nil }
}

/// A plan account: machines signed in to the same account share its limits.
struct PlanAccount: Identifiable, Equatable {
    /// "<agent>-<account id, or the machine's id when none was reported>".
    let id: String
    let agent: String
    let plan: String
    let accountName: String?
    /// The login of whoever owns the machine that sent the newest reading.
    let owner: String
    /// Every machine signed in to it, by id, in feed order.
    let machines: [String]
    /// The machine that sent the newest reading, and when.
    let updatedFrom: String
    let observedAt: UInt64
    let source: String
    let resetCredits: Int?
    let windows: [PlanWindow]
    /// Task ids running with this agent on its machines.
    let running: [String]

    var product: String { agent == "codex" ? "Codex" : agent == "claude" ? "Claude Code" : agent }
}

/// The iPhone's copy of the Mac's usage grouping: LiveAdapter.usageAccounts(machines:members:tasks:)
/// and LiveAdapter.window(_:) in apps/mac/Sources/MapleFactory/Live/LiveAdapter.swift. Keep the two in step.
enum UsageAccounts {
    /// One account per agent + account id across every machine's readings; the newest reading wins.
    /// Claude Code first.
    static func accounts(machines: [Wire.Machine], tasks: [Wire.Task] = [], now: Date = Date()) -> [PlanAccount] {
        var byAccount: [String: (reading: Wire.AgentUsage, machine: Wire.Machine, machines: [Wire.Machine])] = [:]
        for machine in machines {
            for reading in machine.usage {
                let key = "\(reading.agent)-\(reading.account?.id ?? machine.id)"
                if let seen = byAccount[key] {
                    let newer = reading.observedAt > seen.reading.observedAt
                    byAccount[key] = (newer ? reading : seen.reading, newer ? machine : seen.machine, seen.machines + [machine])
                } else {
                    byAccount[key] = (reading, machine, [machine])
                }
            }
        }
        return byAccount.map { key, entry in
            let r = entry.reading
            let ids = Set(entry.machines.map(\.id))
            var running: [String] = []
            for machine in entry.machines {
                for live in machine.sessions where live.session.agent == r.agent {
                    if let id = live.session.taskId, !running.contains(id) { running.append(id) }
                }
            }
            for task in tasks {
                guard let w = task.worker, ids.contains(w.machine), w.agent == r.agent, !running.contains(task.id) else { continue }
                running.append(task.id)
            }
            return PlanAccount(
                id: key, agent: r.agent, plan: r.plan ?? "plan", accountName: r.account?.name,
                owner: entry.machine.owner, machines: entry.machines.map(\.id),
                updatedFrom: entry.machine.id, observedAt: r.observedAt,
                source: r.source == "statusline" ? "From the status line of Claude Code sessions." : "From Codex's own usage reports.",
                resetCredits: r.resetCredits.map(Int.init),
                windows: r.windows.map { window($0, now: now) },
                running: running
            )
        }
        .sorted { ($0.agent == "claude" ? 0 : 1, $0.id) < ($1.agent == "claude" ? 0 : 1, $1.id) }
    }

    /// A reading's window: how far through it we are, when it resets, and when it runs dry at this pace.
    static func window(_ w: Wire.UsageReading, now: Date = Date()) -> PlanWindow {
        let resets = w.resetsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let minutes = Double(w.windowMinutes ?? (w.label == "5h" ? 300 : w.label == "7d" ? 10080 : 0))
        let left = resets.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let elapsed = minutes > 0 ? min(1, max(0, 1 - left / (minutes * 60))) : 0
        let label = switch w.label {
        case "5h": "Current session"
        case "7d": w.name.map { "This week · \($0)" } ?? "This week"
        case "spend": "Spend"
        default: w.label
        }
        let h = Int(left) / 3600, m = Int(left) % 3600 / 60
        let resetsIn = h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
        let resetsAt = resets.map {
            Calendar.current.isDate($0, inSameDayAs: now) ? $0.formatted(date: .omitted, time: .shortened) : $0.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } ?? ""
        let used = w.usedPercent / 100
        let runsOut: String? = {
            guard elapsed > 0.05, used / elapsed > 1, minutes > 0, let resets else { return nil }
            let dry = now.addingTimeInterval((1 - used) / (used / (elapsed * minutes * 60)))
            guard dry < resets else { return nil }
            return Calendar.current.isDate(dry, inSameDayAs: now) ? dry.formatted(date: .omitted, time: .shortened) : dry.formatted(.dateTime.weekday(.abbreviated).hour())
        }()
        return PlanWindow(label: label, span: w.label, used: used, resetsIn: resetsIn, resetsAt: resetsAt, elapsed: elapsed, runsOutAt: runsOut)
    }
}
