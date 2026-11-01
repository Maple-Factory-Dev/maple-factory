import MapleKit
import SwiftUI

/// Settings → Usage: each plan account's rate-limit windows and the machines that share them, so you
/// can tell from the phone why work stalled. Read-only; the Mac's Usage screen is where limits are set.
struct UsageView: View {
    @Environment(FactoryStore.self) private var store

    private var accounts: [PlanAccount] { UsageAccounts.accounts(machines: store.feed.machines, tasks: store.feed.tasks) }

    var body: some View {
        List {
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No usage readings yet", systemImage: "gauge.with.dots.needle.0percent")
                } description: {
                    Text("Each machine's runner reads its agents' plan limits — from Claude Code's status line and Codex's usage reports — and sends them here. Run a session on a machine to see its windows.")
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("usage-empty")
            }
            ForEach(accounts) { account in
                AccountSection(account: account)
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }
}

private struct AccountSection: View {
    @Environment(FactoryStore.self) private var store
    let account: PlanAccount

    private func machine(_ id: String) -> Wire.Machine? { store.feed.machines.first { $0.id == id } }
    private func name(_ id: String) -> String { machine(id)?.name ?? id }

    var body: some View {
        Section {
            ForEach(account.windows) { window in
                WindowRow(window: window, tint: account.agent == "claude" ? Theme.accent : Color(light: 0x2F6FEB, dark: 0x6B9BF5))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("usage-window-\(account.id)-\(window.span)\(window.label.contains("·") ? "-" + window.label.split(separator: "·").last!.trimmingCharacters(in: .whitespaces) : "")")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Shared by").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(account.machines, id: \.self) { id in
                    let online = machine(id)?.online ?? false
                    HStack(spacing: 6) {
                        Circle().fill(online ? Theme.approve : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                        Text(name(id)).font(.subheadline)
                        Spacer()
                        Text(online ? "Online" : "Offline").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage-machines-\(account.id)")
            HStack(spacing: 6) {
                Image(systemName: account.running.isEmpty ? "moon.zzz" : "bolt.fill")
                    .foregroundStyle(account.running.isEmpty ? Color.secondary : Theme.accent)
                Text(account.running.isEmpty ? "No agents running here" : "\(account.running.joined(separator: ", ")) running on this account")
                    .foregroundStyle(account.running.isEmpty ? .secondary : .primary)
            }
            .font(.subheadline)
            if let credits = account.resetCredits {
                Label(credits == 1 ? "1 reset credit" : "\(credits) reset credits", systemImage: "arrow.counterclockwise.circle")
                    .font(.subheadline)
            }
        } header: {
            header
        } footer: {
            Text("Updated \(updated) from \(name(account.updatedFrom)). \(account.source)")
        }
        .accessibilityIdentifier("usage-account-\(account.id)")
    }

    private var updated: String {
        let ago = When.ago(account.observedAt)
        return ago == "now" ? "just now" : "\(ago.replacingOccurrences(of: "m", with: " min").replacingOccurrences(of: "h", with: " h").replacingOccurrences(of: "d", with: " d")) ago"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.product).font(.headline).foregroundStyle(.primary)
                Text(account.plan)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            let owner = store.feed.member(account.owner)?.name ?? account.owner
            Text([account.accountName ?? "Account not reported", owner,
                  account.machines.count == 1 ? "on \(name(account.machines[0]))" : "on \(account.machines.count) machines"].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

private struct WindowRow: View {
    let window: PlanWindow
    let tint: Color

    private var color: Color {
        if window.used >= 0.9 { return Theme.danger }
        if window.used >= 0.75 || window.runsOutEarly { return Theme.warning }
        return tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label).font(.subheadline.weight(.medium))
                Text(window.span).font(.caption.monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int((window.used * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(window.used >= 0.75 ? color : .primary)
            }
            Meter(value: window.used, color: color, pace: window.used > 0 ? min(window.elapsed, 1) : nil)
            Text("Resets in \(window.resetsIn)\(window.resetsAt.isEmpty ? "" : " (\(window.resetsAt))")")
                .font(.caption).foregroundStyle(.secondary)
            if let when = window.runsOutAt {
                Label("Out \(when) at this pace", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A capsule meter with a tick where an even pace through the window would be.
private struct Meter: View {
    let value: Double
    let color: Color
    let pace: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color).frame(width: max(value > 0 ? 6 : 0, geo.size.width * min(value, 1)))
                if let pace {
                    Rectangle().fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width * pace - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
