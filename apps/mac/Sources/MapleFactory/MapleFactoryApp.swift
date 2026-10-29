import SwiftUI
import AppKit

@main
struct MapleFactoryApp: App {
    /// `-width 820` opens a narrow window, e.g. to check the half-screen layout.
    private let launchWidth: CGFloat = {
        let width = AppDefaults.double(forKey: "width")
        return width > 0 ? width : 1600
    }()
    private let launchHeight: CGFloat = {
        let height = AppDefaults.double(forKey: "height")
        return height > 0 ? height : 1000
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState
    @State private var client: FactoryClient

    init() {
        // Together from the first frame, so a signed-in app never flashes the mockup's data.
        let client = FactoryClient()
        let state = AppState()
        state.client = client
        // A fresh install is signed out: connect to a factory, never the mockup, unless this is a demo.
        if AppState.launchesToOnboarding(signedIn: client.isSignedIn, demo: state.demoLaunch) {
            state.showOnboarding = true
        }
        _client = State(initialValue: client)
        _state = State(initialValue: state)
        if Headless.isOn { AppDelegate.headless = (state, client) }
    }

    var body: some Scene {
        WindowGroup("Maple Factory") {
            ContentView()
                .environment(state)
                .environment(client)
                // A maplefactory:// link opens in the window that's there rather than a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .task { client.connect() }
                .frame(minWidth: 720, minHeight: 620)
                // Every @AppStorage reads the headless run's own suite when there is one.
                .defaultAppStorage(AppDefaults)
                .background { if Headless.isOn { HeadlessWindow() } }
        }
        // Links never make a window of their own; the one there (or the one launch opens) takes them.
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: launchWidth, height: launchHeight)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheck)
            }
            CommandGroup(after: .sidebar) {
                Button(state.showInspector ? "Hide Task Panel" : "Show Task Panel") {
                    state.toggleTaskPanel()
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

                Button("Add New Factory…") { state.startOnboarding() }
                if client.isSignedIn {
                    Button("Sign Out of \(client.workspaceName)") {
                        state.signOut()
                    }
                }

                Button("New Task") { state.startCompose() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Goal…") { state.goalSheet = .new }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!client.isSignedIn)
            }
        }

        Settings {
            OrgSettingsView()
                .environment(state)
                .environment(client)
                .defaultAppStorage(AppDefaults)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// What a `-snapshot` run drives; set by the app before launch finishes.
    @MainActor static var headless: (AppState, FactoryClient)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless: no Dock icon, no activation, no updates or banners; the user keeps the screen.
        if let (state, client) = Self.headless {
            Headless.start(state: state, client: client)
            return
        }
        // Running from `swift run` has no bundle, so promote to a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = MapleIcon.dockImage
        Updater.shared.start()
        Notifier.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        // macOS restores the last window frame, so `-width` resizes after the window exists.
        let width = AppDefaults.double(forKey: "width")
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
                .onChange(of: viewing, initial: true) { _, id in client.view(task: id) }
                .onOpenURL { url in
                    // maplefactory://task/<id>, from a copied link (the server's /t/<id> page opens it).
                    guard url.scheme == "maplefactory", url.host() == "task", let id = url.pathComponents.dropFirst().first else { return }
                    let goal = Destination.goal(state.task(id).goal)
                    if state.destination != goal { state.destination = goal }
                    state.isComposing = false
                    state.selectedTask = id
                    state.focusedTask = id
                }
                .onChange(of: Notifier.shared.opening?.id) {
                    // A clicked banner: its task, in the list that holds it.
                    guard let opening = Notifier.shared.opening else { return }
                    Notifier.shared.opening = nil
                    state.destination = opening.hand ? .needsHand : .inbox
                    state.selectedTask = opening.id
                    // Needs a hand has no selection of its own, so the task opens full size.
                    if opening.hand { state.focusedTask = opening.id }
                }
                .onChange(of: [state.destination.hashValue, state.tasks.count], initial: true) { state.keepSelectionInGoal() }
                .onChange(of: client.hasSnapshot ? client.factoryGoals.map(\.name) : nil, initial: true) { _, names in
                    // The page this factory was last on, the first time its goals land; else, the mock's starting goal
                    // isn't one of the workspace's: open the focused task's goal, the first, or the inbox.
                    guard client.isSignedIn, let names else {
                        // Loading a factory (switched to, or joined in onboarding): its own last page comes back once it lands.
                        if client.isSignedIn { state.pageRestored = false }
                        return
                    }
                    let open = state.focusedTask
                    let remembered = state.pageRestored || state.demoLaunch ? nil : client.server.flatMap { LastPage.load(factory: $0) }
                    defer { state.pageRestored = true }
                    guard let next = AppState.destinationAfterSnapshot(state.destination, goals: names, focusedGoal: open.map { state.task($0).goal },
                                                                       remembered: remembered) else { return }
                    state.destination = next
                    state.focusedTask = open
                }
        }
    }

    /// The task on screen, for teammates' presence: open full-size, or in the inspector.
    private var viewing: String? {
        guard client.isSignedIn else { return nil }
        if let focused = state.focusedTask { return focused }
        guard state.inspectorInline || state.showInspector, case .goal = state.destination else { return nil }
        return state.tasks.contains { $0.id == state.selectedTask } ? state.selectedTask : nil
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
            // An update on offer stays up until it's answered; passing toasts show beneath it.
            VStack(spacing: 8) {
                if Updater.shared.showsToast {
                    UpdateToastView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let toast = state.toast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .padding(.top, 66)
            .padding(.leading, state.sidebarSpace)
            .animation(.snappy(duration: 0.25), value: Updater.shared.showsToast)
        }
        .background(VisualEffect(material: .sidebar))
        .ignoresSafeArea()
        .onAppear { NSApp.appearance = appearance.nsAppearance }
        .onChange(of: appearance) { NSApp.appearance = appearance.nsAppearance }
        .onChange(of: state.destination) { if state.sidebarFloating { state.toggleSidebar() } }
        // Only checks you start reach up to date (Sparkle's showUpdateNotFound), so background checks stay quiet.
        .onChange(of: Updater.shared.phase) { _, phase in
            guard phase == .upToDate else { return }
            state.showToast(UpdatePhase.upToDateToast, icon: "checkmark.circle.fill", color: Theme.approve)
        }
        .onChange(of: client.notice) { _, notice in
            guard let notice else { return }
            state.serverRefused(notice)
            // Cleared once shown, so the same refusal again still reaches the buttons.
            client.notice = nil
        }
        .confirmationDialog(
            "Archive \(state.archiving ?? "")?",
            isPresented: Binding(get: { state.archiving != nil }, set: { if !$0 { state.archiving = nil } }),
            titleVisibility: .visible
        ) {
            Button("End Them & Clean Up", role: .destructive) { state.finishArchiving(.cleanup) }
            Button("End Them, Keep Worktrees") { state.finishArchiving(.cancel) }
            Button("Let Them Finish") { state.finishArchiving(.finish) }
            Button("Don't Archive", role: .cancel) { state.archiving = nil }
        } message: {
            let unfinished = state.unfinishedTasks(in: state.archiving ?? "")
            let ids = unfinished.prefix(6).map(\.id).joined(separator: ", ") + (unfinished.count > 6 ? " and \(unfinished.count - 6) more" : "")
            Text("\(ids) \(unfinished.count == 1 ? "isn't" : "aren't") finished. Ending cancels \(unfinished.count == 1 ? "it" : "them"): sessions stop and pull requests close. Cleaning up also removes \(unfinished.count == 1 ? "its worktree" : "their worktrees"), but never anything uncommitted or unpushed. Letting them finish archives the goal and leaves the work running.")
        }
        .sheet(item: Binding(get: { state.goalSheet }, set: { state.goalSheet = $0 })) { sheet in
            if case .edit(let id) = sheet { GoalSheet(editing: client.goals.first { $0.id == id }) } else { GoalSheet(prefill: state.goalPrefill) }
        }
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
                Group {
                    if state.isLoadingFactory {
                        FactoryLoadingView().transition(.opacity)
                    } else {
                        mainContent.transition(.opacity)
                    }
                }
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
            .animation(.easeInOut(duration: 0.3), value: state.isLoadingFactory)
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
        if state.isCompact, state.showInspector, !state.isLoadingFactory, state.focusedTask == nil, !state.isComposing,
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
        case .activity: ActivityView()
        case .scratchpad: ScratchpadView()
        case .usage: UsageView()
        case .needsHand: NeedsHandView()
        case .machines:
            if client.isSignedIn { LiveMachinesView() } else { MachinesView() }
        case .intake: IntakeView()
        case .allGoals: AllGoalsView()
        case .goal(let name): GoalView(name: name)
        }
    }
}

/// Moves a headless run's window off screen as soon as it has one, before it's ever drawn on screen.
struct HeadlessWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewWillMove(toWindow window: NSWindow?) {
            super.viewWillMove(toWindow: window)
            if let window { Headless.hide(window) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { Headless.hide(window) }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
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
