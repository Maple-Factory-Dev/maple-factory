import SwiftUI

/// Creates or edits a goal: its name, the prefix its task ids start with, and where its code is.
struct GoalSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let editing: Wire.Goal?

    @State private var name = ""
    @State private var prefix = ""
    @State private var summary = ""
    @State private var source: Source = .folder
    @State private var folder = ""
    @State private var repo = ""
    @State private var base = ""
    @State private var color = 0
    @State private var prefixEdited = false
    @State private var repoFilter = ""

    enum Source: String, CaseIterable { case folder = "A folder on my machines", repo = "A GitHub repo" }

    private static let colors: [(name: String, hex: String)] = [
        ("Green", "#2EA043"), ("Blue", "#3B82F6"), ("Violet", "#8B5CF6"), ("Amber", "#F59E0B"), ("Pink", "#EC4899"), ("Teal", "#14B8A6"),
    ]

    init(editing: Wire.Goal? = nil) {
        self.editing = editing
        guard let goal = editing else { return }
        _name = State(initialValue: goal.name)
        _prefix = State(initialValue: goal.prefix)
        _prefixEdited = State(initialValue: true)
        _summary = State(initialValue: goal.summary)
        _source = State(initialValue: goal.repo == nil ? .folder : .repo)
        _folder = State(initialValue: goal.folder ?? "")
        _repo = State(initialValue: (goal.repos.isEmpty ? [goal.repo].compactMap { $0 } : goal.repos).joined(separator: ", "))
        _base = State(initialValue: goal.base ?? "")
        _color = State(initialValue: Self.colors.firstIndex { $0.hex.caseInsensitiveCompare(goal.color) == .orderedSame } ?? 0)
    }

    private var valid: Bool {
        !name.trimmed.isEmpty && prefix.range(of: "^[A-Z][A-Z0-9]{0,5}$", options: .regularExpression) != nil
            && (source == .folder ? !folder.trimmed.isEmpty : !repos.isEmpty && repos.allSatisfy { $0.range(of: "^[\\w.-]+/[\\w.-]+$", options: .regularExpression) != nil })
    }

    /// The goal's repos in order, the default first: "acme/api, acme/web".
    private var repos: [String] { repo.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init) }

    /// The org's repos (Settings → Repositories), ticked for this goal; the first ticked is the default.
    private var repoPicker: some View {
        // Picked ones first, then whatever matches the filter: an org can have hundreds.
        let query = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let picked = client.repos.filter { r in repos.contains { $0.caseInsensitiveCompare(r.name) == .orderedSame } }
        let rest = client.repos.filter { r in !picked.contains { $0.name == r.name } && (query.isEmpty || r.name.lowercased().contains(query)) }
        let shown = picked + rest
        return VStack(spacing: 6) {
        TextField("Filter \(client.repos.count) repositories", text: $repoFilter)
            .textFieldStyle(.roundedBorder)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(shown, id: \.name) { org in
                    let picked = repos.contains { $0.caseInsensitiveCompare(org.name) == .orderedSame }
                    HStack(spacing: 8) {
                        Image(systemName: picked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(picked ? Theme.accent : Theme.textFaint)
                        Text(org.name)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        if picked && repos.first?.caseInsensitiveCompare(org.name) == .orderedSame {
                            Text("Default").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                        } else if picked {
                            Text("Make default")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                                .onTapGesture { repo = ([org.name] + repos.filter { $0.caseInsensitiveCompare(org.name) != .orderedSame }).joined(separator: ", ") }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        repo = (picked ? repos.filter { $0.caseInsensitiveCompare(org.name) != .orderedSame } : repos + [org.name]).joined(separator: ", ")
                    }
                }
            }
        }
        .frame(height: min(CGFloat(max(shown.count, 1)) * 28, 168))
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(editing == nil ? "New goal" : "Edit goal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("A goal groups tasks with a shared outcome, and says where their code lives.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(alignment: .top, spacing: 12) {
                field("Name") {
                    TextField("Auth overhaul", text: $name)
                        .onChange(of: name) { _, value in if !prefixEdited { prefix = Self.prefix(for: value) } }
                }
                field("Task ids", width: 110) {
                    TextField("ATL", text: Binding(get: { prefix }, set: { prefix = $0.uppercased(); prefixEdited = true }))
                }
            }

            field("What it's for") {
                TextField("Move every surface to passkeys ahead of the security review.", text: $summary, axis: .vertical)
                    .lineLimit(2...3)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Code").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                Picker("", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if source == .folder {
                    HStack(spacing: 12) {
                        input { TextField("~/Projects/atlas", text: $folder) }
                        input { TextField("Base branch (default)", text: $base) }.frame(width: 190)
                    }
                } else if client.repos.isEmpty {
                    HStack(spacing: 12) {
                        input { TextField("acme/api, acme/web", text: $repo) }
                        input { TextField("Base branch (default)", text: $base) }.frame(width: 190)
                    }
                } else {
                    repoPicker
                    input { TextField("Base branch (each repo's default)", text: $base) }.frame(width: 240)
                }
                Text(source == .folder
                     ? "The same path on each machine that works on it. Tasks branch from origin/<base> in their own worktrees."
                     : client.repos.isEmpty
                        ? "One or more repos, the first the default. Add the org's in Settings → Repositories to pick from them."
                        : "Each task changes one of these; work across them becomes linked tasks. Machines use their own checkouts, or clone.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }

            HStack(spacing: 8) {
                Text("Color").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                ForEach(Self.colors.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(hexString: Self.colors[index].hex) ?? .gray)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Theme.text.opacity(color == index ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .contentShape(Circle())
                        .onTapGesture { color = index }
                        .help(Self.colors[index].name)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                Text(editing == nil ? "Create goal" : "Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(valid ? 1 : 0.4)))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: save)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func save() {
        guard valid else { return }
        let goal = Wire.Goal(
            id: editing?.id ?? "",
            name: name.trimmed,
            prefix: prefix,
            color: Self.colors[color].hex,
            summary: summary.trimmed,
            lead: editing?.lead ?? client.me?.login ?? "",
            due: editing?.due,
            repo: source == .repo ? repos.first : nil,
            repos: source == .repo ? repos : [],
            folder: source == .folder ? folder.trimmed : nil,
            base: base.trimmed.isEmpty ? nil : base.trimmed,
            archived: editing?.archived
        )
        client.send(.goalSave(.init(goal: goal)))
        dismiss()
    }

    /// "Auth overhaul" → "AO"; one word → its first three letters.
    static func prefix(for name: String) -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? words.prefix(4).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(3) ?? "")
        return String(letters.drop { !$0.isLetter })
    }

    private func field<Content: View>(_ label: String, width: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
            input(content)
        }
        .frame(width: width)
    }

    private func input<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
