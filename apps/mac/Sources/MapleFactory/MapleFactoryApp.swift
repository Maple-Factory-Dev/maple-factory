import SwiftUI
import AppKit

@main
struct MapleFactoryApp: App {
    /// `-width 820` opens a narrow window, e.g. to check the half-screen layout.
    private let launchWidth: CGFloat = {
        let width = UserDefaults.standard.double(forKey: "width")
        return width > 0 ? width : 1600
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @State private var client = FactoryClient()

    var body: some Scene {
        WindowGroup("Maple Factory") {
            ContentView()
                .environment(state)
                .environment(client)
                .task {
                    state.client = client
                    client.connect()
                }
                .frame(minWidth: 720, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: launchWidth, height: 1000)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(state.showInspector ? "Hide Task Panel" : "Show Task Panel") {
                    withAnimation(.snappy(duration: 0.25)) { state.showInspector.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button(state.isComposing ? "Send to Planning" : state.focusedTask == nil ? "Open Task Full View" : "Close Task Full View") {
                    if state.isComposing {
                        state.submitDraft(sendToPlanning: true)
                    } else if state.focusedTask == nil {
                        state.openFocus(state.selectedTask)
                    } else {
                        state.closeFocus()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button(state.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") { state.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .control])

                Button("Connect to Another Factory…") { state.startOnboarding() }
                if client.isSignedIn {
                    Button("Sign Out of \(client.server?.host() ?? "Factory")") { client.signOut() }
                }

                Button("New Task") { state.startCompose() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` has no bundle, so promote to a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = MapleIcon.dockImage
        NSApp.applicationIconImage = MapleIcon.dockImage
        NSApp.activate(ignoringOtherApps: true)
        // macOS restores the last window frame, so `-width` resizes after the window exists.
        let width = UserDefaults.standard.double(forKey: "width")
        if width > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    var body: some View {
        if state.showOnboarding {
            OnboardingView()
                .transition(.opacity)
                .onAppear { NSApp.appearance = appearance.nsAppearance }
        } else {
            workspace
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        }
    }

    private var workspace: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Group {
                    if state.sidebarCollapsed || state.isCompact {
                        SidebarRail().transition(.opacity)
                    } else {
                        FactorySidebar().transition(.opacity)
                    }
                }
                .frame(width: state.sidebarSpace)
                .zIndex(1)

                slab
            }
            .overlay(alignment: .leading) { floatingSidebar }
            .onAppear { state.windowResized(to: geo.size.width) }
            .onChange(of: geo.size.width) { _, width in state.windowResized(to: width) }
        }
        .overlay(alignment: .top) {
            if let toast = state.toast {
                ToastView(toast: toast)
                    .padding(.top, 66)
                    .padding(.leading, state.sidebarSpace)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .background(VisualEffect(material: .sidebar))
        .ignoresSafeArea()
        .onAppear { NSApp.appearance = appearance.nsAppearance }
        .onChange(of: appearance) { NSApp.appearance = appearance.nsAppearance }
        .onChange(of: state.destination) { if state.sidebarFloating { state.toggleSidebar() } }
        .sheet(item: Binding(get: { state.machineSheet }, set: { state.machineSheet = $0 })) { sheet in
            MachineSetupSheet(sheet: sheet, machine: {
                if case .edit(let id) = sheet, let machine = state.machines.first(where: { $0.id == id }) { return machine }
                return FactoryData.thisMac
            }())
            .environment(state)
        }
    }

    private var slab: some View {
        VStack(spacing: 0) {
            FactoryTopBar()
            HStack(spacing: 0) {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.inspectorInline {
                    HStack(spacing: 0) {
                        Hairline(vertical: true)
                        inspector
                    }
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) { floatingInspector }
            .clipped()
            Hairline()
            FactoryStatusBar()
        }
        .background(Theme.editorBG)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: Theme.slabShadow, radius: 12, x: -2)
    }

    private var inspector: some View {
        TaskInspector(task: state.task(state.selectedTask))
            .id(state.selectedTask)
    }

    /// In a narrow window the task panel slides over the content instead of squeezing it.
    @ViewBuilder private var floatingInspector: some View {
        if state.isCompact, state.showInspector, state.focusedTask == nil, !state.isComposing,
           ![.scratchpad, .usage, .needsHand, .machines, .intake].contains(state.destination) {
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { state.showInspector = false } }
                inspector
                    .frame(width: min(380, state.contentWidth - 48))
                    .frame(maxHeight: .infinity)
                    .background(Theme.editorBG)
                    .overlay(alignment: .leading) { Hairline(vertical: true) }
                    .shadow(color: .black.opacity(0.18), radius: 20, x: -4)
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    /// The full sidebar, floating over a narrow window when expanded from the rail.
    @ViewBuilder private var floatingSidebar: some View {
        if state.sidebarFloating {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggleSidebar() }
                FactorySidebar()
                    .frame(width: 250)
                    .frame(maxHeight: .infinity)
                    .background(VisualEffect(material: .sidebar))
                    .overlay(alignment: .trailing) { Hairline(vertical: true) }
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 4)
            }
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }
}

extension ContentView {
    @ViewBuilder fileprivate var mainContent: some View {
        if state.isComposing {
            ComposeView()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let focused = state.focusedTask {
            TaskFocusView(task: state.task(focused))
                .id(focused)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
        } else {
            destinationContent
                .transition(.opacity)
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch state.destination {
        case .inbox: InboxView()
        case .myTasks: MyTasksView()
        case .activity: PlaceholderView(title: "Activity", icon: "waveform.path.ecg")
        case .scratchpad: ScratchpadView()
        case .usage: UsageView()
        case .needsHand: NeedsHandView()
        case .machines:
            if client.isSignedIn { LiveMachinesView() } else { MachinesView() }
        case .intake: IntakeView()
        case .goal(let name): GoalView(goal: FactoryData.goal(named: name))
        }
    }
}

/// Bridges NSVisualEffectView so the sidebar picks up the desktop wallpaper behind the window.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
