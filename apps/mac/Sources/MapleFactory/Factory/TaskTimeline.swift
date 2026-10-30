import SwiftUI

/// Everything that happened on a task in one place, oldest first so it reads down into the composer:
/// comments, change requests to the agent, and pipeline events.
struct TaskTimeline: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    let comments: [Comment]
    let requests: [ChangeRequest]
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", discussion = "Discussion", changes = "Changes", events = "Events" }

    private enum Entry {
        case comment(Comment)
        case request(ChangeRequest)
        case event(ActivityItem)

        var when: String {
            switch self {
            case .comment(let comment): comment.when
            case .request(let request): request.when
            case .event(let item): item.when
            }
        }
    }

    private var entries: [Entry] {
        // Change requests show as their own cards, so skip the matching one-line events.
        let events = task.activity.filter { !$0.text.contains("a change") }.map(Entry.event)
        let all = comments.map(Entry.comment) + requests.map(Entry.request) + events
        let filtered = all.filter { entry in
            switch (filter, entry) {
            case (.all, _), (.discussion, .comment), (.changes, .request), (.events, .event): true
            default: false
            }
        }
        // Stable sort: oldest first; same-age items keep the order they were recorded in.
        return filtered.enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (age(lhs.element.when), age(rhs.element.when))
                return l != r ? l > r : lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    private func age(_ when: String) -> Int { when == "now" ? 0 : appState.minutesAgo(when) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                SectionLabel(title: "Timeline")
                Spacer()
                ForEach(Filter.allCases, id: \.self) { option in
                    let active = filter == option
                    Text(option.rawValue)
                        .font(.system(size: 11.5, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Theme.text : Theme.textMuted)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(active ? Theme.fillSelected : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { filter = option } }
                }
            }

            if entries.isEmpty {
                Text("Nothing yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    row(entry, last: index == entries.count - 1)
                }
            }
        }
    }

    @ViewBuilder private func row(_ entry: Entry, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // The rail: an avatar for things people said, a small dot for events.
            VStack(spacing: 0) {
                gutter(entry)
                if !last {
                    Rectangle().fill(Theme.stroke).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 28)

            Group {
                switch entry {
                case .comment(let comment): commentCard(comment)
                case .request(let request): requestCard(request)
                case .event(let item): eventLine(item)
                }
            }
            .padding(.bottom, last ? 0 : 16)
        }
        // Keeps the connector line from stretching rows taller than their content.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func gutter(_ entry: Entry) -> some View {
        switch entry {
        case .comment(let comment):
            AgentAvatar(agent: comment.author, size: 28)
        case .request(let request):
            AgentAvatar(agent: request.author, size: 28)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Theme.State.awaitingApproval))
                        .offset(x: 3, y: 3)
                }
        case .event(let item):
            let who = FactoryData.identity(named: item.who)
            ZStack {
                Circle().fill(Theme.editorBG).frame(width: 20, height: 20)
                Image(systemName: eventIcon(item))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(who?.isHuman == false ? who?.color ?? Theme.textMuted : Theme.textMuted)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.fill))
            }
            .frame(height: 22)
        }
    }

    private func commentCard(_ comment: Comment) -> some View {
        // A review comment on lines of the diff: its file and lines, the code, then what was said.
        let code = comment.anchor.flatMap(DiffReview.parseAnchor)
        let split = code == nil ? nil : DiffReview.splitSnippet(comment.text)
        return VStack(alignment: .leading, spacing: 0) {
            header(name: comment.author.id == FactoryData.me.id ? "You" : comment.author.firstName,
                   verb: comment.via.map { "replied in \($0)" } ?? (code != nil ? "commented on" : comment.author.isHuman ? "commented" : "replied"),
                   anchor: code == nil ? comment.anchor : nil, code: code, when: comment.when)
            Hairline()
            if let split {
                snippet(split.snippet)
                Hairline()
                MarkdownPreview(source: split.body, baseSize: 13)
                    .padding(12)
            } else {
                MarkdownPreview(source: comment.text, baseSize: 13)
                    .padding(12)
            }
        }
        .background(card(Theme.stroke))
    }

    /// Diff lines as the comment quoted them, coloured like the Diff tab.
    private func snippet(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let tint: Color? = line.hasPrefix("+") ? Theme.State.merged : line.hasPrefix("-") ? Theme.State.cancelled : nil
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    .background(tint.map { $0.opacity(0.09) } ?? .clear)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.editorBG)
    }

    private func requestCard(_ request: ChangeRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(name: request.author.id == FactoryData.me.id ? "You" : request.author.firstName,
                   verb: "asked \(task.agent?.name ?? "the agent") for a change", anchor: request.anchor, when: request.when)
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                MarkdownPreview(source: request.text, baseSize: 13)
                HStack(spacing: 6) {
                    ChangeStatusChip(status: request.status)
                    if let timing = request.timing {
                        Text(timing)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(12)
        }
        .background(card(Theme.State.awaitingApproval.opacity(0.35)))
    }

    private func eventLine(_ item: ActivityItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            (Text(FactoryData.identity(named: item.who).map { $0.id == FactoryData.me.id ? "You" : $0.isHuman ? $0.firstName : $0.name } ?? item.who)
                .foregroundStyle(Theme.text).fontWeight(.medium)
             + Text(" \(item.text.prefix(1).lowercased() + item.text.dropFirst())").foregroundStyle(Theme.textMuted))
                .font(.system(size: 12.5))
            Spacer(minLength: 8)
            Text(item.when)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
        }
        .frame(minHeight: 22)
    }

    private func header(name: String, verb: String, anchor: String?, code: (path: String, lines: String)? = nil, when: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text(verb).font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
            if let code {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").font(.system(size: 9.5))
                    Text(code.path).truncationMode(.middle)
                    Text(code.lines).foregroundStyle(Theme.textMuted)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(Capsule().fill(Theme.fill))
                .help("\(code.path), \(code.lines)")
            }
            if let anchor {
                Text(anchor)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(Theme.fill))
            }
            Spacer()
            Text(when).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.fillSubtle)
    }

    private func card(_ border: Color) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.cardBG)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func eventIcon(_ item: ActivityItem) -> String {
        let text = item.text.lowercased()
        if text.contains("approved") { return "checkmark" }
        if text.contains("merged") { return "arrow.triangle.merge" }
        if text.contains("pr") && text.contains("open") { return "arrow.triangle.pull" }
        if text.contains("proof") { return "checkmark.seal" }
        if text.contains("plan") { return "list.bullet" }
        if text.contains("question") || text.contains("answered") { return "questionmark" }
        if text.contains("step") { return "hammer" }
        if text.contains("moved") { return "arrow.right" }
        return "circle.fill"
    }
}
