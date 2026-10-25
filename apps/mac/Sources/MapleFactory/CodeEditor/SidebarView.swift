import SwiftUI

struct SidebarView: View {
    @State private var selectedNav = "Explorer"
    @State private var collapsed = MockData.initiallyCollapsed
    @State private var selectedFile: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceSwitcher()
                .padding(.top, 48)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                navRow("Search", icon: "magnifyingglass")
                navRow("Explorer", icon: "doc")
                navRow("Source control", icon: "arrow.triangle.branch", badge: "3")
                navRow("Extensions", icon: "square.grid.2x2")
            }

            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Text(MockData.workspace)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 8)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(MockData.tree) { node in
                        treeRows(node, depth: 0)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
    }

    private func navRow(_ title: String, icon: String, badge: String? = nil) -> some View {
        let selected = selectedNav == title
        return HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(title).font(Theme.uiFont)
            Spacer()
            if let badge {
                Text(badge).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.78))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.fillSelected : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedNav = title }
    }

    private func treeRows(_ node: FileNode, depth: Int) -> AnyView {
        let isFolder = node.children != nil
        let isOpen = isFolder && !collapsed.contains(node.name)

        let row = HStack(spacing: 6) {
            if isFolder {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: icon(for: node))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 14)
            Text(node.name)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.text.opacity(0.85))
            Spacer()
            if let status = node.status {
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedFile == node.name ? Theme.fillSelected : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isFolder {
                if collapsed.contains(node.name) { collapsed.remove(node.name) } else { collapsed.insert(node.name) }
            } else {
                selectedFile = node.name
            }
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                row
                if isOpen, let children = node.children {
                    ForEach(children) { child in treeRows(child, depth: depth + 1) }
                }
            }
        )
    }

    private func icon(for node: FileNode) -> String {
        switch node.kind {
        case .folder: "folder"
        case .file: "doc.text"
        case .css: "number"
        case .config: "chevron.left.forwardslash.chevron.right"
        case .test: "testtube.2"
        case .env: "key"
        case .markdown: "doc.plaintext"
        }
    }
}

struct WorkspaceSwitcher: View {
    @Environment(FactoryClient.self) private var client

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(client.workspaceName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        )
    }
}
