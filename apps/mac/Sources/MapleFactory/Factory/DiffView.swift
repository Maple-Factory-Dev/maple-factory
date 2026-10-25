import SwiftUI

/// Changed files on the left, a unified diff on the right. Each file and hunk is tagged with the plan
/// step it implements so the review reads against the approved plan.
struct DiffView: View {
    let task: FactoryTask
    let files: [DiffFile]
    @State private var selected: String
    /// Hunks fetched on demand for files that arrive collapsed (large or generated files).
    @State private var loaded: [String: [DiffHunk]] = [:]
    @State private var loading: Set<String> = []

    init(task: FactoryTask, files: [DiffFile]) {
        self.task = task
        self.files = files
        _selected = State(initialValue: files.first { !$0.hunks.isEmpty }?.path ?? files.first?.path ?? "")
    }

    /// The picked file, else the first with hunks (files can arrive after the view does).
    private var current: DiffFile? { files.first { $0.path == selected } ?? files.first { !$0.hunks.isEmpty } ?? files.first }

    var body: some View {
        // A single file needs no list beside it; its header already says what changed.
        if files.count == 1, let current {
            fileDiff(current)
        } else {
            HStack(alignment: .top, spacing: 16) {
                fileList.frame(width: 250)
                if let current { fileDiff(current) }
            }
        }
    }

    // MARK: File list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(title: files.count == 1 ? "1 file" : "\(files.count) files")
                Spacer()
                Text("+\(files.map(\.added).reduce(0, +))").foregroundStyle(Theme.State.merged)
                Text("−\(files.map(\.removed).reduce(0, +))").foregroundStyle(Theme.State.cancelled)
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())

            VStack(spacing: 1) {
                ForEach(files) { file in fileRow(file) }
            }
        }
    }

    private func fileRow(_ file: DiffFile) -> some View {
        let active = file.path == current?.path
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent

        return HStack(spacing: 8) {
            Image(systemName: file.inProgress ? "pencil.circle" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(file.inProgress ? Theme.State.building : Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let step = file.step { stepTag(step) }
            VStack(alignment: .trailing, spacing: 1) {
                Text("+\(file.added)").foregroundStyle(Theme.State.merged)
                Text("−\(file.removed)").foregroundStyle(Theme.State.cancelled)
            }
            .font(.system(size: 10.5).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.fillSelected : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = file.path
            if file.hunks.isEmpty, loaded[file.path] == nil, !loading.contains(file.path) { load(file) }
        }
    }

    private func stepTag(_ step: Int) -> some View {
        Text("S\(step)")
            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
            .foregroundStyle(Theme.State.planning)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.State.planning.opacity(0.13)))
            .help(task.plan.indices.contains(step - 1) ? "Step \(step): \(task.plan[step - 1].text)" : "Step \(step)")
    }

    // MARK: Diff

    private func fileDiff(_ file: DiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.inProgress {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("\(task.agent?.name ?? "Agent") is editing")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.State.building)
                }
                Spacer()
                Text("+\(file.added)").foregroundStyle(Theme.State.merged)
                Text("−\(file.removed)").foregroundStyle(Theme.State.cancelled)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.fillSubtle)
            .overlay(alignment: .bottom) { Hairline() }

            let hunks = file.hunks.isEmpty ? loaded[file.path] ?? [] : file.hunks
            if hunks.isEmpty {
                collapsedPlaceholder(file)
            } else {
                ForEach(hunks) { hunk in hunkView(hunk, path: file.path) }
            }
        }
        .background(Theme.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
    }

    private func collapsedPlaceholder(_ file: DiffFile) -> some View {
        VStack(spacing: 8) {
            if loading.contains(file.path) {
                ProgressView().controlSize(.small)
                Text("Loading \(file.added + file.removed) lines…")
            } else {
                Text("Collapsed: \(file.added + file.removed) changed lines")
                Text("Load diff")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.fill)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { load(file) }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: .infinity)
        .frame(height: 100)
    }

    private func load(_ file: DiffFile) {
        loading.insert(file.path)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.snappy(duration: 0.25)) {
                loaded[file.path] = FactoryData.loadHunks(for: file)
                loading.remove(file.path)
            }
        }
    }

    /// Files read as text rather than code: no syntax colours, which only scramble prose.
    private static let proseExtensions: Set<String> = ["md", "markdown", "mdx", "txt", "rst", "adoc", ""]

    private func hunkView(_ hunk: DiffHunk, path: String) -> some View {
        let prose = Self.proseExtensions.contains((path as NSString).pathExtension.lowercased())
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Spacer()
                if let step = hunk.step, task.plan.indices.contains(step - 1) {
                    HStack(spacing: 5) {
                        stepTag(step)
                        Text(task.plan[step - 1].text).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.State.planning.opacity(0.05))

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                lineView(line, prose: prose)
            }
        }
    }

    private func lineView(_ line: DiffLine, prose: Bool) -> some View {
        let (sign, tint): (String, Color?) = switch line.kind {
        case .added: ("+", Theme.State.merged)
        case .removed: ("−", Theme.State.cancelled)
        case .context: (" ", nil)
        }

        // Long lines wrap inside the box (numbers stay on the first row) rather than running off it.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.old.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
            Text(line.new.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
            Text(sign)
                .foregroundStyle(tint ?? Theme.textFaint)
                .frame(width: 22)
            Group {
                if prose { Text(line.text).foregroundStyle(Theme.text) } else { Text(SyntaxHighlighter.highlight(line.text)) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Theme.textFaint)
        .padding(.vertical, 2)
        .frame(minHeight: 20)
        .background(tint.map { $0.opacity(0.09) } ?? .clear)
        .overlay(alignment: .leading) {
            if let tint { Rectangle().fill(tint.opacity(0.7)).frame(width: 2) }
        }
    }
}
