import SwiftUI

/// The review findings behind the Statistics page's "Review findings by kind" card: where they land, what
/// happened to them and which agent's work drew them, with a list to dig into. Pick a grid cell or a
/// folder to filter the list; tap a finding to open its task, or tick some to make a task from them.
struct FindingsView: View {
    @Environment(AppState.self) private var state
    let summary: Wire.StatsSummary
    let narrow: Bool
    /// The findings ticked in the list, by `pickKey`; StatisticsView pins the bar that makes a task from them.
    @Binding var picked: Set<String>
    let back: () -> Void

    @State private var kind: Wire.FindingKind?
    @State private var severity: Wire.Severity?
    @State private var area: String?
    /// A legend item clicked in What happened to them: only findings of that status.
    @State private var status: Wire.FindingStatus?
    /// The list's Hide fixed chip: what's left to deal with.
    @State private var hideFixed = false
    @State private var query = ""

    private static let severities: [Wire.Severity] = [.blocker, .major, .minor]

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: AppState.demoFindings)) { demo($0.object as? [String] ?? []) }
    }

    /// A demo script's step, as the click it stands for (AppState.demoFindings); StatisticsView scrolls to the list.
    private func demo(_ parts: [String]) {
        guard let f = summary.findings, let verb = parts.first else { return }
        let arg = parts.dropFirst().joined(separator: ":")
        withAnimation(.snappy(duration: 0.3)) {
            switch verb {
            case "cell" where parts.count == 3:
                kind = Wire.FindingKind(rawValue: parts[1])
                severity = Wire.Severity(rawValue: parts[2])
            case "area": area = area == arg ? nil : arg
            case "severity": severity = severity?.rawValue == arg ? nil : Wire.Severity(rawValue: arg)
            case "hidefixed": setHideFixed(!hideFixed)
            case "status": setStatus(status?.rawValue == arg ? nil : Wire.FindingStatus(rawValue: arg))
            case "clearfilters": kind = nil; severity = nil; area = nil; status = nil; hideFixed = false; query = ""
            case "row": if let r = visible(f).dropFirst(Int(arg) ?? 0).first { open(r.task) }
            case "select": if let r = visible(f).dropFirst(Int(arg) ?? 0).first { toggle(r) }
            case "selectall": selectAll(visible(f))
            case "clear": picked = []
            case "compose": compose(f)
            default: break
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button(action: back) {
                Label("Statistics", systemImage: "chevron.left")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Statistics")

            HStack(alignment: .firstTextBaseline) {
                Text("Review findings")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(counted(Int(summary.totals.findings), "finding")) in \(counted(Int(summary.totals.reviewRounds), "round"))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            }

            if let f = summary.findings {
                twoUp {
                    grid(f.matrix)
                    VStack(spacing: 18) {
                        outcomes(f.outcomes)
                        agents(f.byAgent)
                    }
                }
                areas(f.areas)
                list(f).id("findings-list")
            } else {
                StatsCard {
                    Text("This server doesn't break findings down yet; it will once it's updated.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private func twoUp<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        (narrow ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 18))) { content() }
    }

    // MARK: Kind × severity

    private func grid(_ cells: [Wire.StatsFindingCell]) -> some View {
        let kinds = Self.kindsByCount(cells)
        let top: UInt32 = max(1, cells.map(\.count).max() ?? 1)
        let count: (Wire.FindingKind, Wire.Severity) -> UInt32 = { k, s in cells.first { $0.kind == k && $0.severity == s }?.count ?? 0 }

        return StatsCard {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Kind × severity", note: "click a cell to filter")
                if cells.isEmpty { empty }
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(Self.severities, id: \.self) { s in
                            Text(severityTitle(s))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(kinds, id: \.self) { k in
                        GridRow {
                            Text(k.rawValue.capitalized)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                                .frame(width: 56, alignment: .leading)
                            ForEach(Self.severities, id: \.self) { s in
                                cell(kind: k, severity: s, count: count(k, s), top: top)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The kinds with the most findings first.
    private static func kindsByCount(_ cells: [Wire.StatsFindingCell]) -> [Wire.FindingKind] {
        var totals: [Wire.FindingKind: Int] = [:]
        for c in cells { totals[c.kind, default: 0] += Int(c.count) }
        return totals.keys.sorted { (totals[$0]!, $1.rawValue) > (totals[$1]!, $0.rawValue) }
    }

    private func cell(kind k: Wire.FindingKind, severity s: Wire.Severity, count n: UInt32, top: UInt32) -> some View {
        let selected = kind == k && severity == s
        let share = Double(n) / Double(top)
        return Text(n == 0 ? "–" : "\(n)")
            .font(.system(size: 13, weight: n == 0 ? .regular : .semibold).monospacedDigit())
            .foregroundStyle(n == 0 ? Theme.textFaint : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(n == 0 ? Theme.fillSubtle : severityColor(s).opacity(0.1 + 0.45 * share))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.text : .clear, lineWidth: 1.5))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard n > 0 else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    if selected { kind = nil; severity = nil } else { kind = k; severity = s }
                }
            }
            .help("\(k.rawValue.capitalized) · \(severityTitle(s)): \(n)")
    }

    // MARK: What happened to them

    private func outcomes(_ o: Wire.StatsFindingOutcomes) -> some View {
        let parts: [(String, UInt32, Color, Wire.FindingStatus?)] = [("Fixed", o.fixed, Theme.State.merged, .fixed),
                                                                     ("Disputed", o.disputed, Theme.State.awaitingApproval, .disputed),
                                                                     ("Open", o.open, Theme.State.cancelled, .open), ("Unknown", o.unknown, Theme.textFaint, nil)]
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        return StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("What happened to them", note: (o.roundsToFixMedian.map { "fixed in \(rounds($0)) (median) · " } ?? "") + "click to filter")
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                            Rectangle().fill(p.2).frame(width: max(3, (geo.size.width - 6) * CGFloat(p.1) / CGFloat(total)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                HStack(spacing: 6) {
                    ForEach(parts.filter { $0.1 > 0 || $0.3 != nil }, id: \.0) { p in
                        let selected = p.3 != nil && status == p.3
                        HStack(spacing: 5) {
                            Circle().fill(p.2).frame(width: 7, height: 7)
                            Text(p.0).foregroundStyle(selected ? Theme.text : Theme.textMuted)
                            Text("\(p.1)").foregroundStyle(Theme.text).monospacedDigit()
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.fillSelected : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let s = p.3 else { return }
                            withAnimation(.snappy(duration: 0.2)) { setStatus(selected ? nil : s) }
                        }
                        .help(p.3 == nil ? "Findings of tasks that are gone, whose status wasn't kept"
                              : selected ? "Show every finding again" : "\(p.0): \(p.1) · click to show only these")
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private func agents(_ rows: [Wire.StatsFindingAgent]) -> some View {
        let top = max(0.01, rows.compactMap(\.perRound).max() ?? 1)
        return StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Findings per round, by agent", note: nil)
                if rows.isEmpty { empty }
                ForEach(rows, id: \.agent) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(r.agent.capitalized).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(r.findings) in \(counted(Int(r.rounds), "round")) · \(r.serious) serious").foregroundStyle(Theme.textFaint)
                            Text(r.perRound.map { String(format: "%.1f", $0) } ?? "–")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                        }
                        .font(.system(size: 12.5))
                        bar(share: (r.perRound ?? 0) / top, color: Theme.accent)
                    }
                    .help("\(r.agent.capitalized): \(r.findings) findings over \(r.rounds) review rounds, \(r.serious) blockers or majors")
                }
            }
        }
    }

    // MARK: Where they land

    private func areas(_ rows: [Wire.StatsFindingArea]) -> some View {
        let top = max(1, rows.map(\.count).max() ?? 1)
        return StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Where findings land", note: "by folder · click to filter")
                if rows.isEmpty { empty }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: narrow ? 1 : 2), alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.key) { r in
                        let selected = area == r.key
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(r.key)
                                    .font(.system(size: 12, design: r.key.hasPrefix("(") ? .default : .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(counted(Int(r.tasks), "task")) · \(r.serious) serious").foregroundStyle(Theme.textFaint)
                                Text("\(r.count)")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                            }
                            .font(.system(size: 12))
                            bar(share: Double(r.count) / Double(top), color: selected ? Theme.text : Theme.accent)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.fillSelected : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { area = selected ? nil : r.key } }
                        .help("\(r.key): \(r.count) findings on \(counted(Int(r.tasks), "task"))")
                    }
                }
            }
        }
    }

    // MARK: The list

    /// The list's findings under the filters and search.
    private func visible(_ f: Wire.StatsFindings) -> [Wire.StatsFindingRow] {
        Self.visible(f.recent, kind: kind, severity: severity, area: area, status: status, hideFixed: hideFixed, query: query)
    }

    /// The rows the filters keep. A status filter never matches a finding whose task is gone (no status).
    static func visible(_ rows: [Wire.StatsFindingRow], kind: Wire.FindingKind?, severity: Wire.Severity?, area: String?,
                        status: Wire.FindingStatus?, hideFixed: Bool, query: String) -> [Wire.StatsFindingRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { r in
            (kind == nil || r.kind == kind) && (severity == nil || r.severity == severity) && (area == nil || r.area == area)
                && (status == nil || r.status == status) && !(hideFixed && r.status == .fixed)
                && (needle.isEmpty || [r.text, r.file ?? "", r.task, r.title].contains { $0.lowercased().contains(needle) })
        }
    }

    private func list(_ f: Wire.StatsFindings) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = visible(f)
        let kinds = Wire.FindingKind.allCases.filter { k in f.recent.contains { $0.kind == k } }
        let fixed = f.recent.filter { $0.status == .fixed }.count

        return StatsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle("Findings", note: f.recent.count < Int(summary.totals.findings) ? "the newest \(f.recent.count)" : nil)
                    .padding(.bottom, 12)
                HStack(spacing: 6) {
                    ForEach(kinds, id: \.self) { k in
                        chip(k.rawValue.capitalized, active: kind == k) { kind = kind == k ? nil : k }
                    }
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    ForEach(Self.severities, id: \.self) { s in
                        chip(severityTitle(s), dot: severityColor(s), active: severity == s) { severity = severity == s ? nil : s }
                    }
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    chip("Hide fixed · \(fixed)", icon: "eye.slash", active: hideFixed) { setHideFixed(!hideFixed) }
                        .help(hideFixed ? "Show fixed findings again" : "Hide the findings that were fixed, to see what's left")
                    if let status {
                        let (title, color) = Self.statusStyle(status)
                        chip(title, dot: color, active: true, removable: true) { setStatus(nil) }
                    }
                    if let area {
                        Divider().frame(height: 16).padding(.horizontal, 4)
                        chip(area, icon: "folder", active: true) { self.area = nil }
                    }
                    Spacer(minLength: 8)
                    TextField("Search findings", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .frame(maxWidth: 200)
                }
                .padding(.bottom, 10)
                let filtered = kind != nil || severity != nil || area != nil || status != nil || hideFixed || !needle.isEmpty
                if filtered || !rows.isEmpty {
                    HStack(spacing: 8) {
                        if filtered {
                            Text("\(counted(rows.count, "finding")) shown")
                            Button("Clear filters") { withAnimation(.snappy(duration: 0.2)) { kind = nil; severity = nil; area = nil; status = nil; hideFixed = false; query = "" } }
                                .buttonStyle(.link)
                        }
                        Spacer()
                        if !rows.isEmpty {
                            let all = rows.allSatisfy { picked.contains($0.pickKey) }
                            Button(all ? "Deselect shown" : "Select all shown") {
                                withAnimation(.snappy(duration: 0.2)) { if all { picked.subtract(rows.map(\.pickKey)) } else { selectAll(rows) } }
                            }
                            .buttonStyle(.link)
                        }
                        if !picked.isEmpty {
                            Button("Clear selection") { withAnimation(.snappy(duration: 0.2)) { picked = [] } }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.bottom, 8)
                }
                if rows.isEmpty {
                    Text(f.recent.isEmpty ? "No findings in this range." : "No findings match.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.vertical, 8)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Hairline() }
                    row(r)
                }
            }
        }
    }

    private func row(_ r: Wire.StatsFindingRow) -> some View {
        let on = picked.contains(r.pickKey)
        return HStack(alignment: .top, spacing: 12) {
            Button { withAnimation(.snappy(duration: 0.15)) { toggle(r) } } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Theme.accent : Theme.textFaint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(on ? "Deselect" : "Select, to make a task from it")
            Circle()
                .fill(severityColor(r.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(severityTitle(r.severity))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.text.isEmpty ? "(no text kept)" : r.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(r.text.isEmpty ? Theme.textFaint : Theme.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(r.kind.rawValue.capitalized + " · " + severityTitle(r.severity))
                    if let file = r.file {
                        Text(file).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                HStack(spacing: 6) {
                    Text(r.task).font(.system(size: 11, design: .monospaced))
                    Text(r.title).lineLimit(1)
                    Text("· round \(r.raisedIn)")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 8)
            statusBadge(r.status)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.fillSelected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { open(r.task) }
        .help("Open \(r.task)")
        .contextMenu {
            Button("Make a task from this finding") { picked.remove(r.pickKey); state.composeFromFindings([r]) }
            Button("Open \(r.task)") { open(r.task) }
        }
    }

    private func toggle(_ r: Wire.StatsFindingRow) {
        if picked.contains(r.pickKey) { picked.remove(r.pickKey) } else { picked.insert(r.pickKey) }
    }

    private func selectAll(_ rows: [Wire.StatsFindingRow]) { picked.formUnion(rows.map(\.pickKey)) }

    /// The ticked findings, made into a New Task; the selection is done with then.
    private func compose(_ f: Wire.StatsFindings) {
        let rows = Self.picked(picked, in: f)
        guard !rows.isEmpty else { return }
        state.composeFromFindings(rows)
        picked = []
    }

    /// The ticked findings, in the list's order.
    static func picked(_ keys: Set<String>, in f: Wire.StatsFindings) -> [Wire.StatsFindingRow] {
        var seen = Set<String>()
        return f.recent.filter { keys.contains($0.pickKey) && seen.insert($0.pickKey).inserted }
    }

    /// Hide fixed, on or off; it and a Fixed status filter never both hold.
    private func setHideFixed(_ on: Bool) {
        hideFixed = on
        if on, status == .fixed { status = nil }
        unpickHidden()
    }

    /// A status filter, or none; Fixed turns Hide fixed off.
    private func setStatus(_ s: Wire.FindingStatus?) {
        status = s
        if s == .fixed { hideFixed = false }
        unpickHidden()
    }

    /// Unticks the findings Hide fixed or the status filter just hid, so the pick bar counts what's on screen.
    private func unpickHidden() {
        guard let f = summary.findings else { return }
        let hidden = f.recent.filter { r in (hideFixed && r.status == .fixed) || (status != nil && r.status != status) }
        picked.subtract(hidden.map(\.pickKey))
    }

    static func statusStyle(_ s: Wire.FindingStatus?) -> (String, Color) {
        switch s {
        case .fixed: ("Fixed", Theme.State.merged)
        case .disputed: ("Disputed", Theme.State.awaitingApproval)
        case .open: ("Open", Theme.State.cancelled)
        case .other(let v): (v.capitalized, Theme.textMuted)
        case nil: ("Task gone", Theme.textFaint)
        }
    }

    @ViewBuilder private func statusBadge(_ s: Wire.FindingStatus?) -> some View {
        let (title, color) = Self.statusStyle(s)
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    /// Its task, when there is one to open: live, or the mockup's own (signed out).
    private func open(_ task: String) {
        if state.isLive || state.tasks.contains(where: { $0.id == task }) { state.openFocus(task) }
    }

    // MARK: Pieces

    private var empty: some View {
        Text("None in this range.")
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textMuted)
    }

    private func bar(share: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(min(1, share))))
            }
        }
        .frame(height: 6)
    }

    private func chip(_ title: String, dot: Color? = nil, icon: String? = nil, active: Bool, removable: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(title).lineLimit(1)
            if active && (icon != nil || removable) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textMuted) }
        }
        .font(.system(size: 12, weight: active ? .medium : .regular))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            Capsule()
                .fill(active ? Theme.fillSelected : .clear)
                .overlay(Capsule().strokeBorder(active ? .clear : Theme.stroke))
        )
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { action() } }
    }

    private func severityTitle(_ s: Wire.Severity) -> String { s.rawValue.capitalized }

    private func severityColor(_ s: Wire.Severity) -> Color {
        switch s {
        case .blocker: Theme.State.cancelled
        case .major: Theme.State.awaitingApproval
        case .minor, .other: Theme.textMuted
        }
    }

    private func rounds(_ n: Double) -> String {
        n == n.rounded() ? counted(Int(n), "round") : String(format: "%.1f rounds", n)
    }

    /// "1 round", "2 rounds".
    private func counted(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Pinned under Review findings while some are ticked: how many, and Make a task from them.
struct FindingsPickBar: View {
    @Environment(AppState.self) private var state
    let findings: Wire.StatsFindings
    @Binding var picked: Set<String>

    var body: some View {
        let rows = FindingsView.picked(picked, in: findings)
        HStack(spacing: 14) {
            Image(systemName: "checkmark.square.fill").foregroundStyle(Theme.accent)
            Text("\(rows.count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Button("Clear") { withAnimation(.snappy(duration: 0.2)) { picked = [] } }
                .buttonStyle(.link)
                .font(.system(size: 12.5))
            PrimaryButton(title: "Make a task from \(rows.count == 1 ? "1 finding" : "\(rows.count) findings")", icon: "plus", color: Theme.accent) {
                state.composeFromFindings(rows)
                withAnimation(.snappy(duration: 0.2)) { picked = [] }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}
