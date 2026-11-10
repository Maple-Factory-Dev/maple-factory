import Foundation

/// The one-line usage readout ("34% session · 41% week") shared by the status bar and the collapsed
/// sidebar's Usage tooltip, so both show the same account and the same numbers (MF-410).
enum UsageSummary {
    /// The plan account closest to its 5-hour limit: yours first, anyone's if your machines report none.
    /// Accounts without a session reading don't count.
    static func busiest(_ accounts: [UsageAccount], me: String?) -> UsageAccount? {
        let accounts = accounts.filter { $0.sessionWindow != nil }
        let mine = accounts.filter { $0.owner?.github == me }
        return (mine.isEmpty ? accounts : mine).max { ($0.sessionWindow?.used ?? 0) < ($1.sessionWindow?.used ?? 0) }
    }

    /// "34% session · 41% week", or "34% · 41%" when compact. The week part is left out when the account
    /// has no weekly window; nil when it has no session window.
    static func text(_ account: UsageAccount, compact: Bool) -> String? {
        guard let session = account.sessionWindow else { return nil }
        let week = account.weekWindow
        return compact
            ? "\(percent(session.used))\(week.map { " · \(percent($0.used))" } ?? "")"
            : "\(percent(session.used)) session\(week.map { " · \(percent($0.used)) week" } ?? "")"
    }

    static func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }

    /// The made-up readout for the signed-out demo. Never shown on a live factory.
    static func demoText(compact: Bool) -> String { compact ? "34% · 41%" : "34% session · 41% week" }
}
