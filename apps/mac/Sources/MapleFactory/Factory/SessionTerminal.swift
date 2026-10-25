import SwiftUI

// MARK: Model

/// One line of a live agent session as the runner's tmux pane shows it.
/// A real build would stream the PTY into libghostty; the mock fakes the screen with styled lines.
enum TermLine: Hashable {
    case banner(String)
    case user(String)
    case assistant(String)
    case tool(String, String)
    case output(String)
    case added(String)
    case removed(String)
    case question(String, [String])
    case system(String)
}

/// Who has the keyboard. Everyone attached sees the same pane; only the driver's keys reach it.
enum SessionDriver: Equatable {
    case agent
    case person(Person.ID)
}

extension FactoryData {
    static func transcript(for task: FactoryTask, cli: String) -> [TermLine] {
        switch task.id {
        case "ATL-144":
            return [
                .banner("\(cli) · ~/maple/worktrees/atl-144 · \(task.agent?.name ?? "agent")"),
                .assistant("Step 3 is done: 12 routes under /api/projects use withAuth now. Moving on to /api/billing."),
                .tool("Read", "app/api/billing/invoices/route.ts"),
                .output("  ⎿  Read 84 lines"),
                .tool("Search", "requireSession\\( in app/api/billing"),
                .output("  ⎿  Found 3 matches in 2 files"),
                .assistant("Both billing handlers check the session and then the role inline. Swapping them for withAuth({ role: \"billing_admin\" })."),
                .tool("Update", "app/api/billing/invoices/route.ts"),
                .removed("-  const session = await requireSession(req)"),
                .removed("-  if (session.role !== \"billing_admin\") return forbidden()"),
                .added("+export const GET = withAuth({ role: \"billing_admin\" }, async (req, { session }) => {"),
                .output("  ⎿  Updated with 1 addition and 2 removals"),
                .tool("Bash", "pnpm vitest run tests/auth --reporter=dot"),
                .output("  ⎿  ··········································· 31 passed (4.1s)"),
                .assistant("Tests still pass. Next: app/api/billing/plans/route.ts."),
            ]
        case "ATL-160":
            return [
                .banner("\(cli) · ~/maple/worktrees/atl-160 · \(task.agent?.name ?? "agent")"),
                .tool("Read", "lib/auth/sso/saml.ts"),
                .output("  ⎿  Read 212 lines"),
                .tool("Read", "docs/adr/0007-teams-and-invites.md"),
                .output("  ⎿  Read 46 lines"),
                .assistant("Drafted 3 of 5 plan steps. The ADR says every member joins through an invite, but SAML sign-ins arrive without one."),
                .question("How should users who sign in through SAML join the org?", [
                    "Auto-provision them into the org's default team",
                    "Require an invite first, and show \"ask your admin\"",
                    "Let each org choose in its SSO settings",
                ]),
            ]
        default:
            return [
                .banner("\(cli) · ~/maple/worktrees/\(task.id.lowercased()) · \(task.agent?.name ?? "agent")"),
                .assistant(task.liveLog ?? task.detail),
                .tool("Read", task.plan.first(where: { $0.progress == .active })?.file ?? "README.md"),
                .output("  ⎿  Read 120 lines"),
            ]
        }
    }
}

extension AppState {
    func driver(of taskID: String) -> SessionDriver { sessionDrivers[taskID] ?? .agent }

    /// Interrupts the agent (like pressing Esc in the CLI) and gives you the keyboard.
    func takeWheel(_ taskID: String) {
        let me = FactoryData.me
        withAnimation(.snappy(duration: 0.2)) {
            sessionDrivers[taskID] = .person(me.id)
            sessionLines[taskID, default: []].append(.system("\(me.firstName) took the wheel · \(task(taskID).agent?.name ?? "agent") paused after its current tool call"))
        }
        update(taskID) { task in
            task.activity.insert(ActivityItem(who: me.name, text: "Took over the live session", when: "now"), at: 0)
        }
    }

    /// Gives the keyboard back. The agent reads what happened while you drove and carries on.
    func handBack(_ taskID: String) {
        let agent = task(taskID).agent?.name ?? "Agent"
        withAnimation(.snappy(duration: 0.2)) {
            sessionDrivers[taskID] = .agent
            sessionLines[taskID, default: []].append(.system("Handed back to \(agent) · it picks up from your last message"))
        }
        update(taskID) { task in
            task.activity.insert(ActivityItem(who: FactoryData.me.name, text: "Handed the session back to \(agent)", when: "now"), at: 0)
        }
    }

    func sendToSession(_ taskID: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(.snappy(duration: 0.15)) { sessionLines[taskID, default: []].append(.user(trimmed)) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.snappy(duration: 0.15)) {
                sessionLines[taskID, default: []].append(.assistant(reply(to: trimmed, taskID: taskID)))
            }
        }
    }

    /// Picking an option in the agent's question prompt answers the task's open question too.
    func answerInSession(_ taskID: String, option: String) {
        withAnimation(.snappy(duration: 0.15)) {
            sessionLines[taskID, default: []].append(.user(option))
        }
        update(taskID) { task in
            task.question = nil
            task.needsYou = false
            task.detail = "Drafting plan"
            task.liveLog = "Planning with your answer: \(option)"
            task.activity.insert(ActivityItem(who: FactoryData.me.name, text: "Answered in the live session: \(option)", when: "now"), at: 0)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.snappy(duration: 0.15)) {
                sessionLines[taskID, default: []].append(.assistant("Got it. Updating step 4 so SAML users \(option.lowercased().hasPrefix("auto") ? "land in the default team" : "follow that rule"), then I'll finish the plan."))
                sessionLines[taskID, default: []].append(.tool("Update", "plan.md"))
            }
        }
        showToast("Answered \(taskID) from the session", icon: "terminal.fill", color: Theme.State.planning)
    }

    private func reply(to text: String, taskID: String) -> String {
        let lower = text.lowercased()
        if lower.contains("why") { return "Because the billing handlers also check the workspace plan, and withAuth didn't support that yet. I can add a plan option to it if you want." }
        if lower.contains("stop") || lower.contains("wait") { return "Stopped. Nothing is half-written; the last change is saved. Tell me what to do next." }
        if lower.contains("test") { return "Running the full auth suite now instead of just the touched files." }
        return "Understood. I'll do that next and note it in the plan so the reviewer sees why."
    }
}

// MARK: View

/// A live view of the agent's terminal on whichever machine runs it, attached through the factory relay.
struct SessionTerminal: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    @State private var input = ""
    @FocusState private var focused: Bool

    private var placement: (machine: Machine, session: Session)? { state.session(for: task.id) }
    private var cli: String { task.agent?.name == "Maple-5" ? "codex" : "claude" }
    private var lines: [TermLine] { FactoryData.transcript(for: task, cli: cli) + state.sessionLines[task.id, default: []] }
    private var driving: Bool { state.driver(of: task.id) == .person(FactoryData.me.id) }
    private var canDrive: Bool {
        guard let placement else { return false }
        // Task owners can always drive; teammates can drive sessions running in team slots.
        return task.owner.id == FactoryData.me.id || placement.machine.isMine || placement.session.kind != .personal
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            screen
            statusLine
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(driving ? Theme.State.planning.opacity(0.7) : Term.border, lineWidth: driving ? 1.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Theme.State.merged).frame(width: 7, height: 7)
                Text("LIVE").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.State.merged)
            }
            if let placement {
                Label(placement.machine.id, systemImage: placement.machine.kind.icon)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Term.text)
            }
            Text("tmux · maple:\(task.id.lowercased()) · \(cli)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Term.dim)
            Text("38 ms")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Term.dim)
                .help("Relayed through maple.atlas.dev")

            Spacer()

            HStack(spacing: 6) {
                Facepile(people: watchers, size: 20, ringColor: Term.chrome)
                Text(watchers.count == 1 ? "watching" : "\(watchers.count) watching")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Term.dim)
            }

            driverChip

            iconButton("doc.on.doc", help: "Copy attach command: ssh \(placement?.machine.id ?? "") -t tmux attach -t maple:\(task.id.lowercased())") {
                state.showToast("Copied the tmux attach command", icon: "doc.on.doc")
            }
            iconButton("arrow.up.forward.app", help: "Pop out into its own window") {
                state.showToast("Pop-out windows aren't mocked up yet", icon: "macwindow")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Term.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Term.border).frame(height: 1) }
    }

    private var watchers: [Person] {
        var people = [FactoryData.me]
        if task.viewers.contains(where: { $0.id == FactoryData.chris.id }) || task.owner.id == FactoryData.chris.id {
            people.append(FactoryData.chris)
        }
        return people
    }

    @ViewBuilder private var driverChip: some View {
        if driving {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard.fill").font(.system(size: 10))
                    Text("You're driving")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Term.violet)
                chipButton("Hand back to \(task.agent?.name ?? "agent")", primary: true) { state.handBack(task.id) }
            }
        } else {
            HStack(spacing: 8) {
                if let agent = task.agent {
                    HStack(spacing: 5) {
                        AgentAvatar(agent: agent, size: 16)
                        Text("\(agent.name) driving")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Term.text)
                }
                if canDrive {
                    chipButton("Take the wheel", primary: false) {
                        state.takeWheel(task.id)
                        focused = true
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                } else {
                    Label("Watch only", systemImage: "lock")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Term.dim)
                        .help("This runs in \(placement?.machine.owner.firstName ?? "someone")'s personal slot. Only they can type here.")
                }
            }
        }
    }

    // MARK: Screen

    private var screen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    render(line)
                }
                promptLine
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .background(Term.bg)
        .contentShape(Rectangle())
        .onTapGesture { if driving { focused = true } }
    }

    @ViewBuilder private func render(_ line: TermLine) -> some View {
        switch line {
        case .banner(let text):
            HStack(spacing: 8) {
                Text("✻").foregroundStyle(Term.orange)
                Text(text).foregroundStyle(Term.dim)
            }
            .font(Term.font)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Term.orange.opacity(0.5)))
            .padding(.bottom, 8)
        case .user(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(">").foregroundStyle(Term.dim)
                Text(text).foregroundStyle(Term.text)
            }
            .font(Term.font)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
            .padding(.vertical, 4)
        case .assistant(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("⏺").foregroundStyle(Term.text)
                Text(text).foregroundStyle(Term.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(Term.font)
            .padding(.top, 6)
        case .tool(let name, let arg):
            HStack(spacing: 0) {
                Text("⏺ ").foregroundStyle(Term.green)
                Text(name).foregroundStyle(Term.text).fontWeight(.bold)
                Text("(\(arg))").foregroundStyle(Term.text)
            }
            .font(Term.font)
            .padding(.top, 6)
        case .output(let text):
            Text(text).font(Term.font).foregroundStyle(Term.dim)
        case .added(let text):
            Text("     \(text)").font(Term.font).foregroundStyle(Term.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.green.opacity(0.09))
        case .removed(let text):
            Text("     \(text)").font(Term.font).foregroundStyle(Term.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.red.opacity(0.09))
        case .question(let title, let options):
            questionBox(title, options)
        case .system(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Term.violet.opacity(0.5)).frame(height: 1).frame(maxWidth: 30)
                Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Term.violet)
                Rectangle().fill(Term.violet.opacity(0.5)).frame(height: 1)
            }
            .padding(.vertical, 8)
        }
    }

    private func questionBox(_ title: String, _ options: [String]) -> some View {
        let answered = task.question == nil

        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Term.font).foregroundStyle(Term.text).fontWeight(.bold)
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                HStack(spacing: 8) {
                    Text(index == 0 && !answered ? "❯" : " ").foregroundStyle(Term.violet)
                    Text("\(index + 1). \(option)")
                        .foregroundStyle(index == 0 && !answered ? Term.violet : Term.text)
                }
                .font(Term.font)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !answered, driving || canDrive {
                        if !driving { state.takeWheel(task.id) }
                        state.answerInSession(task.id, option: option)
                    }
                }
            }
            if !answered {
                Text(driving ? "Enter to confirm · Esc to cancel" : "Take the wheel (or click an option) to answer here")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Term.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Term.violet.opacity(answered ? 0.25 : 0.6)))
        .opacity(answered ? 0.6 : 1)
        .padding(.vertical, 8)
    }

    private var promptLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(">").foregroundStyle(driving ? Term.text : Term.dim)
            if driving {
                TextField("", text: $input, prompt: Text("Type to \(task.agent?.name ?? "the agent")…").foregroundStyle(Term.dim))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Term.text)
                    .focused($focused)
                    .onSubmit {
                        state.sendToSession(task.id, input)
                        input = ""
                    }
            } else {
                Text(canDrive ? "Watching. Take the wheel to type." : "Watching.")
                    .foregroundStyle(Term.dim)
            }
            Spacer()
        }
        .font(Term.font)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(driving ? Term.violet.opacity(0.6) : Term.border))
        .padding(.top, 12)
    }

    /// tmux's status bar, as the runner's pane shows it.
    private var statusLine: some View {
        HStack(spacing: 0) {
            Text(" [maple] ").foregroundStyle(Term.bg).background(Term.green)
            Text(" 0:\(cli)* ").foregroundStyle(Term.text)
            Text(" 1:shell ").foregroundStyle(Term.dim)
            Text(" 2:logs ").foregroundStyle(Term.dim)
            Spacer()
            Text("\(placement?.machine.id ?? "") · \(task.id.lowercased()) · 00:41 ").foregroundStyle(Term.dim)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(height: 22)
        .background(Term.chrome)
    }

    // MARK: Pieces

    private func chipButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? .white : Term.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Term.violet : Color.white.opacity(0.09)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(Term.dim)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }
}

/// Terminal palette. Terminals stay dark in both appearances.
/// The terminal palette, dark in both appearances like a real terminal, leaning plum to match the app.
enum Term {
    static let bg = Color(hex: 0x121017)
    static let chrome = Color(hex: 0x1B1821)
    static let nsBG = NSColor(red: 0x12 / 255, green: 0x10 / 255, blue: 0x17 / 255, alpha: 1)
    static let nsText = NSColor(red: 0xD8 / 255, green: 0xDC / 255, blue: 0xE3 / 255, alpha: 1)
    static let nsCaret = NSColor(red: 1, green: 0x7A / 255, blue: 0x48 / 255, alpha: 1)
    static let border = Color.white.opacity(0.09)
    static let text = Color(hex: 0xD8DCE3)
    static let dim = Color(hex: 0x7D8590)
    static let green = Color(hex: 0x4ED38B)
    static let red = Color(hex: 0xF47C7C)
    static let orange = Color(hex: 0xE38B5E)
    static let violet = Color(hex: 0xA48BFA)
    static let font = Font.system(size: 13, design: .monospaced)
}
