import SwiftUI

// MF-296: an HTML mockup or HTML/SVG artifact opened large, laid out at a Desktop, Tablet or Mobile
// width to see how it responds. It rides on the proof lightbox (`ProofLightbox.page`), so Esc, the
// backdrop and showLightbox/closeLightbox work the same. Each kind keeps its sandbox: a mockup runs
// no scripts (HTMLMock), an artifact runs its own in the no-network SandboxedPage.

/// The widths a page is shown at.
enum PageViewport: String, CaseIterable, Identifiable {
    case desktop, tablet, mobile, fit

    var id: String { rawValue }

    /// The layout width in points; nil for Fit, which takes the room's.
    var width: CGFloat? {
        switch self {
        case .desktop: 1280
        case .tablet: 834
        case .mobile: 390
        case .fit: nil
        }
    }

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .tablet: "Tablet"
        case .mobile: "Mobile"
        case .fit: "Fit"
        }
    }

    var icon: String {
        switch self {
        case .desktop: "desktopcomputer"
        case .tablet: "ipad"
        case .mobile: "iphone"
        case .fit: "arrow.left.and.right"
        }
    }

    /// Remembered across openings; `-pageviewport mobile` picks it at launch, for screenshots.
    static let defaultsKey = "pageviewport"

    static var saved: PageViewport {
        get { AppDefaults.string(forKey: defaultsKey).flatMap { PageViewport(rawValue: $0.lowercased()) } ?? .desktop }
        set { AppDefaults.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Where the page goes in the room it has.
    struct Layout: Equatable {
        /// The width and height the page lays out at, before scaling.
        var page: CGSize
        /// How much it's shrunk to fit the room (1 when it fits as it is; never more than 1).
        var scale: CGFloat
        /// What it takes up on screen once scaled.
        var shown: CGSize { CGSize(width: page.width * scale, height: page.height * scale) }
    }

    /// The page lays out at `width` (or the room's for Fit) and fills the room's height; when the room is
    /// narrower it's scaled down by room/width, so its height grows by as much to keep filling the room.
    nonisolated static func layout(width: CGFloat?, room: CGSize) -> Layout {
        guard room.width > 0, room.height > 0 else { return Layout(page: .zero, scale: 1) }
        let laid = max(1, width ?? room.width)
        let scale = min(1, room.width / laid)
        return Layout(page: CGSize(width: laid, height: room.height / scale), scale: scale)
    }
}

struct PageViewerView: View {
    /// A demo script's `pageviewer:open`: the first HTML mockup or artifact on screen opens itself here.
    static let demoOpen = Notification.Name("PageViewerView.demoOpen")
    /// A demo script's `pageviewer:desktop` (or `tablet`, `mobile`, `fit`).
    static let demoPreset = Notification.Name("PageViewerView.demoPreset")
    static let padding: CGFloat = 32
    static let barHeight: CGFloat = 44

    let html: String
    let caption: String
    let scripts: Bool
    @Environment(AppState.self) private var state
    @State private var viewport = PageViewport.saved

    var body: some View {
        GeometryReader { geo in
            let room = CGSize(width: geo.size.width - Self.padding * 2,
                              height: geo.size.height - Self.padding * 2 - Self.barHeight)
            let layout = PageViewport.layout(width: viewport.width, room: room)
            ZStack {
                Color.black.opacity(0.75)
                    .contentShape(Rectangle())
                    .onTapGesture { state.closeLightbox() }

                VStack(spacing: 12) {
                    bar(layout)
                    page
                        .frame(width: layout.page.width, height: layout.page.height)
                        .scaleEffect(layout.scale, anchor: .topLeading)
                        .frame(width: layout.shown.width, height: layout.shown.height, alignment: .topLeading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: viewport == .mobile ? 18 : 8))
                        .overlay(RoundedRectangle(cornerRadius: viewport == .mobile ? 18 : 8).strokeBorder(.white.opacity(0.18)))
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                        .animation(.snappy(duration: 0.3), value: viewport)
                }
                .padding(Self.padding)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: viewport) { PageViewport.saved = viewport }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPreset)) { note in
            if let name = note.object as? String, let preset = PageViewport(rawValue: name) { viewport = preset }
        }
    }

    @ViewBuilder private var page: some View {
        if scripts { SandboxedPage(html: html) } else { HTMLMock(html: html) }
    }

    private func bar(_ layout: PageViewport.Layout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: scripts ? "chart.bar.doc.horizontal" : "rectangle.on.rectangle")
            Text(caption).lineLimit(1)
            Spacer(minLength: 16)
            Picker("", selection: $viewport) {
                ForEach(PageViewport.allCases) { preset in
                    Text(preset.width.map { "\(preset.title) \(Int($0))" } ?? preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(layout.scale < 0.995 ? "scaled to \(Int((layout.scale * 100).rounded()))%" : "\(Int(layout.page.width.rounded())) pt")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(minWidth: 96, alignment: .leading)
            Spacer(minLength: 16)
            Button { state.closeLightbox() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.85))
        .frame(height: Self.barHeight - 12)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// The corner button that opens a page large.
struct ExpandPageButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open large")
        .padding(8)
    }
}
