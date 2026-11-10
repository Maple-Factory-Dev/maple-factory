import MapleKit
import SwiftUI

/// A goal's shared docs (MF-370), from the goal overview's Docs row.
struct DocsListRoute: Hashable { let goal: String }
/// One doc's screen, on a tab: what a doc link or push opens.
struct DocRoute: Hashable { let id: String; var tab: DocTab = .doc }

enum DocTab: String, Hashable, CaseIterable { case doc, comments, decisions }

/// The goal's active docs, newest edit first, each with its open-thread and open-decision badges.
struct DocsListView: View {
    @Environment(FactoryStore.self) private var store
    let goal: String

    var body: some View {
        let docs = store.feed.docs(goal: goal)
        List {
            if docs.isEmpty {
                ContentUnavailableView("No docs yet", systemImage: "doc.richtext",
                                       description: Text("Plans, specs and notes your team writes together. Make one on the Mac or the web."))
            }
            ForEach(docs) { doc in
                NavigationLink(value: DocRoute(id: doc.id)) { DocListRow(doc: doc, openDecisions: openDecisions(doc.id)) }
                    .accessibilityIdentifier("doc-\(doc.id)")
            }
        }
        .navigationTitle("Docs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openDecisions(_ doc: String) -> Int {
        store.feed.decisions.filter { $0.doc == doc && $0.status == .proposed }.count
    }
}

private struct DocListRow: View {
    let doc: Wire.Doc
    let openDecisions: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(doc.title.isEmpty ? "Untitled" : doc.title, systemImage: "doc.richtext").font(.body.weight(.medium))
            HStack(spacing: 8) {
                Text("Edited \(Date(timeIntervalSince1970: Double(doc.updatedAt) / 1000).formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let n = doc.openThreads, n > 0 { Badge(text: "\(n)", icon: "text.bubble", tint: Theme.accent) }
                if openDecisions > 0 { Badge(text: "\(openDecisions)", icon: "checkmark.seal", tint: .orange) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Badge: View {
    let text: String, icon: String, tint: Color
    var body: some View {
        Label(text, systemImage: icon).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// One doc: the shared editor in a web view, and native lists of its comment threads and decisions.
struct DocScreen: View {
    @Environment(FactoryStore.self) private var store
    let id: String
    @State private var tab: DocTab

    init(id: String, initialTab: DocTab = .doc) {
        self.id = id
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        let doc = store.feed.docs.first { $0.id == id }
        let threads = store.feed.docThreads[id] ?? []
        let decisions = store.feed.decisions.filter { $0.doc == id }
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Doc").tag(DocTab.doc)
                Text("Comments \(threads.filter { $0.resolved != true }.count)").tag(DocTab.comments)
                Text("Decisions \(decisions.filter { $0.status == .proposed }.count)").tag(DocTab.decisions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            .accessibilityIdentifier("doc-tabs")
            switch tab {
            case .doc: DocWebTab(id: id, threads: threads, decisions: decisions)
            case .comments: DocCommentsList(doc: id, threads: threads)
            case .decisions: DocDecisionsList(decisions: decisions)
            }
        }
        .navigationTitle(doc?.title ?? "Doc")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { store.send(.docThreads(.init(doc: id))) }
        .onAppear { store.visibleDoc = id }
        .onDisappear { if store.visibleDoc == id { store.visibleDoc = nil } }
    }
}

/// Open threads, each with its quote, comments, a reply field and Resolve; resolved ones behind a toggle, with Reopen.
struct DocCommentsList: View {
    @Environment(FactoryStore.self) private var store
    let doc: String
    let threads: [Wire.DocThread]
    @State private var showResolved = false

    var body: some View {
        let open = threads.filter { $0.resolved != true }
        let resolved = threads.filter { $0.resolved == true }
        List {
            if open.isEmpty { Text("No open comments.").foregroundStyle(.secondary) }
            ForEach(open, id: \.id) { ThreadCard(doc: doc, thread: $0) }
            if !resolved.isEmpty {
                Toggle("Show resolved (\(resolved.count))", isOn: $showResolved).accessibilityIdentifier("show-resolved")
                if showResolved { ForEach(resolved, id: \.id) { ThreadCard(doc: doc, thread: $0) } }
            }
        }
    }
}

private struct ThreadCard: View {
    @Environment(FactoryStore.self) private var store
    let doc: String
    let thread: Wire.DocThread
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = thread.anchor?.quote, !quote.isEmpty {
                Text(quote).font(.callout).italic().foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
            }
            ForEach(thread.comments, id: \.id) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.author).font(.subheadline.weight(.semibold))
                        if let agent = c.agent {
                            Label(agent, systemImage: "sparkles").font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.purple.opacity(0.12)))
                        }
                        Text(Date(timeIntervalSince1970: Double(c.at) / 1000).formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(c.text).font(.subheadline)
                }
            }
            if thread.resolved == true {
                HStack {
                    Text("Resolved\(thread.resolvedBy.map { " by \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reopen") { store.send(.docReopen(.init(doc: doc, thread: thread.id))) }.buttonStyle(.bordered)
                }
            } else {
                HStack {
                    TextField("Reply", text: $reply, axis: .vertical).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reply-\(thread.id)")
                    Button("Send") {
                        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        store.send(.docComment(.init(doc: doc, thread: thread.id, text: text)))
                        reply = ""
                    }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Resolve") { store.send(.docResolve(.init(doc: doc, thread: thread.id))) }
                        .accessibilityIdentifier("resolve-\(thread.id)")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The doc's decisions, open first: question, options with notes, rationale; Accept and Reject while proposed.
struct DocDecisionsList: View {
    let decisions: [Wire.Decision]

    var body: some View {
        let sorted = decisions.sorted { a, b in
            (a.status == .proposed ? 0 : 1, b.proposedAt) < (b.status == .proposed ? 0 : 1, a.proposedAt)
        }
        List {
            if sorted.isEmpty { Text("No decisions in this doc.").foregroundStyle(.secondary) }
            ForEach(sorted, id: \.id) { DecisionCard(decision: $0) }
        }
    }
}

private struct DecisionCard: View {
    @Environment(FactoryStore.self) private var store
    let decision: Wire.Decision
    @State private var accepting = false
    @State private var rejecting = false
    @State private var choice = ""
    @State private var why = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(decision.status.rawValue.capitalized).font(.caption.weight(.semibold))
                    .foregroundStyle(decision.status == .proposed ? .orange : decision.status == .accepted ? .green : .secondary)
                if let agent = decision.agent { Text("· \(agent) for \(decision.proposedBy)").font(.caption).foregroundStyle(.secondary) }
                else { Text("· \(decision.proposedBy)").font(.caption).foregroundStyle(.secondary) }
            }
            Text(decision.question).font(.headline)
            ForEach(decision.options, id: \.id) { o in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: o.id == decision.chosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(o.id == decision.chosen ? Theme.accent : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.label).font(.subheadline.weight(o.id == decision.chosen ? .semibold : .regular))
                        if let note = o.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !decision.rationale.isEmpty { Text(decision.rationale).font(.callout).foregroundStyle(.secondary) }
            if let why = decision.why, !why.isEmpty {
                Text("Why: \(why)\(decision.decidedBy.map { " — \($0)" } ?? "")").font(.callout)
            }
            if decision.status == .proposed {
                HStack {
                    Button("Accept…") { choice = decision.chosen ?? decision.options.first?.id ?? ""; why = ""; accepting = true }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("accept-\(decision.id)")
                    Button("Reject…", role: .destructive) { why = ""; rejecting = true }.buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $accepting) {
            NavigationStack {
                Form {
                    Picker("Option", selection: $choice) {
                        ForEach(decision.options, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                    Section("Why (optional)") { TextField("Why", text: $why, axis: .vertical).accessibilityIdentifier("accept-why") }
                }
                .navigationTitle("Accept decision").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { accepting = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Accept") {
                            store.send(.decisionAccept(.init(id: decision.id, chosen: choice, why: why.isEmpty ? nil : why)))
                            accepting = false
                        }
                        .accessibilityIdentifier("accept-confirm")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $rejecting) {
            NavigationStack {
                Form { Section("Why (optional)") { TextField("Why", text: $why, axis: .vertical) } }
                    .navigationTitle("Reject decision").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rejecting = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Reject", role: .destructive) {
                                store.send(.decisionReject(.init(id: decision.id, why: why.isEmpty ? nil : why)))
                                rejecting = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }
}
