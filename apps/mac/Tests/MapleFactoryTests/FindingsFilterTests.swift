import Testing
@testable import MapleFactory

/// The Review findings list's filters (MF-97): Hide fixed and a status from the What happened to them legend,
/// alone and with the kind, severity, folder and search filters.
@MainActor struct FindingsFilterTests {
    private func finding(_ task: String, _ status: Wire.FindingStatus?, kind: Wire.FindingKind = .code, severity: Wire.Severity = .major,
                         area: String = "apps/mac", text: String = "") -> Wire.StatsFindingRow {
        Wire.StatsFindingRow(task: task, title: "", kind: kind, severity: severity, text: text.isEmpty ? "\(task) finding" : text,
                             area: area, status: status, raisedIn: 1, at: 0)
    }

    private var rows: [Wire.StatsFindingRow] {
        [
            finding("MF-1", .fixed),
            finding("MF-2", .open),
            finding("MF-3", .disputed),
            finding("MF-4", nil),
            finding("MF-5", .fixed, kind: .risk, severity: .blocker, area: "server/src"),
            finding("MF-6", .open, kind: .risk, severity: .blocker, area: "server/src", text: "Retry loop never backs off"),
            finding("MF-7", .other("waived")),
        ]
    }

    private func visible(kind: Wire.FindingKind? = nil, severity: Wire.Severity? = nil, area: String? = nil,
                         status: Wire.FindingStatus? = nil, hideFixed: Bool = false, query: String = "") -> [String] {
        FindingsView.visible(rows, kind: kind, severity: severity, area: area, status: status, hideFixed: hideFixed, query: query).map(\.task)
    }

    @Test func noFiltersKeepEveryRow() {
        #expect(visible() == ["MF-1", "MF-2", "MF-3", "MF-4", "MF-5", "MF-6", "MF-7"])
    }

    @Test func hideFixedDropsOnlyFixedRows() {
        #expect(visible(hideFixed: true) == ["MF-2", "MF-3", "MF-4", "MF-6", "MF-7"])
    }

    @Test func aStatusFilterKeepsOnlyThatStatusAndNeverATaskThatsGone() {
        #expect(visible(status: .open) == ["MF-2", "MF-6"])
        #expect(visible(status: .disputed) == ["MF-3"])
        #expect(visible(status: .fixed) == ["MF-1", "MF-5"])
        for s in Wire.FindingStatus.allCases { #expect(!visible(status: s).contains("MF-4")) }
    }

    @Test func theyCombineWithTheOtherFilters() {
        #expect(visible(kind: .risk, hideFixed: true) == ["MF-6"])
        #expect(visible(severity: .blocker, status: .fixed) == ["MF-5"])
        #expect(visible(area: "apps/mac", hideFixed: true) == ["MF-2", "MF-3", "MF-4", "MF-7"])
        #expect(visible(status: .open, query: "retry") == ["MF-6"])
        #expect(visible(kind: .code, status: .open, hideFixed: true) == ["MF-2"])
        #expect(visible(kind: .risk, severity: .major, status: .open).isEmpty)
    }

    @Test func selectingAllShownWithHideFixedPicksNoFixedFinding() {
        let shown = FindingsView.visible(rows, kind: nil, severity: nil, area: nil, status: nil, hideFixed: true, query: "")
        let f = Wire.StatsFindings(outcomes: .init(fixed: 2, disputed: 1, open: 2, unknown: 1), recent: rows)
        let picked = FindingsView.picked(Set(shown.map(\.pickKey)), in: f)
        #expect(picked.count == 5)
        #expect(!picked.contains { $0.status == .fixed })
    }
}
