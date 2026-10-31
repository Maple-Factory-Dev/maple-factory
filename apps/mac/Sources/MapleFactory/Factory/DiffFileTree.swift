import SwiftUI

/// A folder or file in the diff's tree. Folders with a single folder inside fold into one row
/// (`lib/auth`), the way GitHub and editors show them.
struct DiffTreeNode: Identifiable, Equatable {
    /// The full path: a file's own, or the folder's.
    let id: String
    /// What the row says: the file's name, or the folder's (possibly several, `lib/auth`).
    let name: String
    let file: DiffFile?
    var children: [DiffTreeNode] = []

    var isFolder: Bool { file == nil }

    static func == (a: DiffTreeNode, b: DiffTreeNode) -> Bool {
        a.id == b.id && a.name == b.name && a.children == b.children && a.file?.path == b.file?.path
    }

    /// The tree of `files`: folders first, then files, each by name.
    static func build(_ files: [DiffFile]) -> [DiffTreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [DiffFile] = []
        }
        let root = Folder()
        for file in files {
            var folder = root
            for part in file.path.split(separator: "/").dropLast().map(String.init) {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append(file)
        }

        func nodes(_ folder: Folder, prefix: String) -> [DiffTreeNode] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> DiffTreeNode in
                var label = name
                var path = prefix + name
                var inner = folder.folders[name]!
                // A folder holding just one folder (and no files) folds into it.
                while inner.files.isEmpty, inner.folders.count == 1, let only = inner.folders.first {
                    label += "/" + only.key
                    path += "/" + only.key
                    inner = only.value
                }
                return DiffTreeNode(id: path, name: label, file: nil, children: nodes(inner, prefix: path + "/"))
            }
            let leaves = folder.files
                .sorted { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
                .map { DiffTreeNode(id: $0.path, name: ($0.path as NSString).lastPathComponent, file: $0) }
            return folders + leaves
        }
        return nodes(root, prefix: "")
    }

    /// The files under this node, in tree order.
    var files: [DiffFile] { file.map { [$0] } ?? children.flatMap(\.files) }
}

/// The diff's changed files as a tree: collapsible folders, and files with their +/− counts, plan
/// step and a dot when they have comments waiting to be sent.
struct DiffFileTree: View {
    let task: FactoryTask
    let nodes: [DiffTreeNode]
    let selected: String?
    /// Paths with draft comments.
    let pending: Set<String>
    /// Paths with GitHub review threads.
    let threaded: Set<String>
    let onSelect: (DiffFile) -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(nodes) { node in rows(node, depth: 0) }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
    }

    private func rows(_ node: DiffTreeNode, depth: Int) -> AnyView {
        if node.isFolder {
            let open = !collapsed.contains(node.id)
            return AnyView(VStack(alignment: .leading, spacing: 1) {
                folderRow(node, depth: depth, open: open)
                if open {
                    ForEach(node.children) { child in rows(child, depth: depth + 1) }
                }
            })
        }
        return AnyView(fileRow(node, depth: depth))
    }

    private func folderRow(_ node: DiffTreeNode, depth: Int, open: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 10)
            Image(systemName: open ? "folder" : "folder.fill")
                .font(.system(size: 11))
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !open, node.files.contains(where: { pending.contains($0.path) }) { pendingDot }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.15)) {
                if open { collapsed.insert(node.id) } else { collapsed.remove(node.id) }
            }
        }
        .help(node.id)
    }

    private func fileRow(_ node: DiffTreeNode, depth: Int) -> some View {
        let file = node.file!
        let active = file.path == selected
        return HStack(spacing: 6) {
            Color.clear.frame(width: 10)
            Image(systemName: file.inProgress ? "pencil.circle" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(file.inProgress ? Theme.State.building : Theme.textMuted)
            Text(node.name)
                .font(.system(size: 12.5, weight: active ? .medium : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if pending.contains(file.path) { pendingDot }
            if threaded.contains(file.path) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textMuted)
                    .help("Review threads on GitHub")
            }
            if let step = file.step { StepTag(task: task, step: step) }
            HStack(spacing: 4) {
                Text("+\(file.added)").foregroundStyle(Theme.State.merged)
                Text("−\(file.removed)").foregroundStyle(Theme.State.cancelled)
            }
            .font(.system(size: 10.5).monospacedDigit())
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.fillSelected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(file) }
        .help(file.path)
    }

    private var pendingDot: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 6, height: 6)
            .help("Comments waiting to be sent")
    }
}

/// A plan step's tag, `S2`, with the step's text on hover.
struct StepTag: View {
    let task: FactoryTask
    let step: Int

    var body: some View {
        Text("S\(step)")
            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
            .foregroundStyle(Theme.State.planning)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.State.planning.opacity(0.13)))
            .help(task.plan.indices.contains(step - 1) ? "Step \(step): \(task.plan[step - 1].text)" : "Step \(step)")
    }
}
