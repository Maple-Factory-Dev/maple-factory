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

/// The sidebar's Slack-style header: the factory's name in bold with a chevron; opens the factory menu.
struct WorkspaceSwitcher: View {
    @Environment(FactoryClient.self) private var client
    @State private var hovering = false

    var body: some View {
        Menu {
            FactoryMenu()
        } label: {
            HStack(spacing: 5) {
                Text(client.workspaceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.fillSelected : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

/// The factory's icon on a rounded tile; without one, its first letter on an accent tile.
struct FactoryIcon: View {
    let name: String
    var image: NSImage?
    var size: CGFloat = 22

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27))
        } else {
            Text(Self.initial(name))
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.27).fill(Theme.accent))
        }
    }

    static func initial(_ name: String) -> String { name.first.map { String($0).uppercased() } ?? "F" }

    /// The same tile as an image, for a menu row (menus draw images, not views).
    static func menuImage(name: String, image: NSImage?, size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.27, yRadius: size * 0.27)
            tile.addClip()
            if let image {
                image.draw(in: aspectFill(image.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                NSColor(Theme.accent).setFill()
                tile.fill()
                let letter = NSAttributedString(string: initial(name), attributes: [
                    .font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold), .foregroundColor: NSColor.white,
                ])
                let fits = letter.size()
                letter.draw(at: NSPoint(x: rect.midX - fits.width / 2, y: rect.midY - fits.height / 2))
            }
            return true
        }
    }

    /// `size` scaled to cover `rect`, centred on it.
    static func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let fit = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2, width: fit.width, height: fit.height)
    }
}

/// The factories signed into on this Mac, the current one checked, then adding one and signing out.
struct FactoryMenu: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    var body: some View {
        ForEach(client.savedFactories) { factory in
            let current = client.isSignedIn && client.server.map(SavedFactory.key) == factory.id
            // A toggle, so the current one keeps its checkmark beside its icon.
            Toggle(isOn: Binding(get: { current }, set: { _ in
                guard !current else { return }
                if client.switchTo(factory) {
                    state.didSwitchFactory()
                } else {
                    state.startOnboarding()
                }
            })) {
                Label {
                    Text("\(factory.name) — \(factory.host)")
                } icon: {
                    Image(nsImage: FactoryIcon.menuImage(name: factory.name, image: current ? client.icon : factory.icon.flatMap(FactoryIcons.image)))
                }
            }
        }
        if !client.savedFactories.isEmpty { Divider() }
        Button("Add new factory…", systemImage: "plus") { state.startOnboarding() }
        if client.isSignedIn {
            Button("Sign out of \(client.workspaceName)") { state.signOut() }
        }
    }
}
