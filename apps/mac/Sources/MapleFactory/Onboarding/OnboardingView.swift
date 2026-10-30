import SwiftUI

/// Joining a factory: point the app at its URL, sign in with GitHub, land in the workspace.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var step: Step
    @State private var url = ""
    @State private var checks: [Check] = []
    @State private var error: String?
    @FocusState private var urlFocused: Bool
    /// The factory found at the address, once it answered.
    @State private var server: URL?
    @State private var health: FactoryClient.Health?
    @State private var device: FactoryClient.DeviceCode?
    @State private var signedIn: FactoryClient.SignInResult?
    @State private var signInTask: Task<Void, Never>?
    /// Went back to the workspace: anything still in flight lands nowhere.
    @State private var cancelled = false
    /// `-onboardingAuto` and `-onboardingStep` play the scripted demo instead of talking to a server.
    private static var autoConnected = false
    private let demo = AppDefaults.bool(forKey: "onboardingAuto") || AppDefaults.string(forKey: "onboardingStep") != nil

    enum Step: Int { case url, connecting, signIn, authorizing, ready }

    struct Check: Identifiable {
        let text: String
        var detail: String? = nil
        var done = false
        var id: String { text }
    }

    init() {
        // `-onboardingStep signin|ready` jumps ahead, for screenshots and demos.
        let start: Step = switch AppDefaults.string(forKey: "onboardingStep") {
        case "signin": .signIn
        case "authorizing": .authorizing
        case "ready": .ready
        default: .url
        }
        _step = State(initialValue: start)
        _url = State(initialValue: start == .url ? "" : "maple.atlas.dev")
    }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                StepDots(current: step)
                    .padding(.top, 56)

                Spacer(minLength: 24)

                Group {
                    switch step {
                    case .url, .connecting: connectCard
                    case .signIn, .authorizing: signInCard
                    case .ready: readyCard
                    }
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                        removal: .opacity.combined(with: .offset(x: -24))))
                .id(step == .connecting ? Step.url : step == .authorizing ? .signIn : step)

                Spacer(minLength: 24)

                footer.padding(.bottom, 22)
            }

            if state.onboardingCanCancel && step != .ready {
                backButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 50)
                    .padding(.leading, 24)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // `-onboardingURL localhost:8788` fills in a real address and connects; add
            // `-onboardingContinue YES` to sign in too. For screenshots of the real flow.
            // Once a launch: signed out again later, it stays on the connect screen like the real app.
            if let address = AppDefaults.string(forKey: "onboardingURL"), !Self.autoConnected {
                Self.autoConnected = true
                url = address
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.8))
                    connect()
                }
            }
            // `-onboardingAuto YES` plays the flow at demo pace and stops on Ready, so every step can be seen.
            guard AppDefaults.bool(forKey: "onboardingAuto") else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                for character in "maple.atlas.dev" {
                    url.append(character)
                    try? await Task.sleep(for: .milliseconds(70))
                }
                try? await Task.sleep(for: .seconds(1.2))
                connect()
            }
        }
        .onChange(of: step) {
            guard step == .signIn, AppDefaults.bool(forKey: "onboardingAuto") || AppDefaults.bool(forKey: "onboardingContinue") else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                signIn()
            }
        }
    }

    // MARK: Steps

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                MapleMark(size: 44)
                Text("Connect to a factory")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Enter the address your team runs Maple at. You'll sign in with GitHub next.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text(url.hasPrefix("localhost") || url.hasPrefix("127.") ? "http://" : "https://")
                        .foregroundStyle(Theme.textFaint)
                    TextField("maple.yourcompany.dev", text: $url)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.text)
                        .focused($urlFocused)
                        .disabled(step == .connecting)
                        .onSubmit(connect)
                    if step == .connecting {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.system(size: 15, design: .monospaced))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.cardBG)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(error != nil ? Theme.State.cancelled : urlFocused ? Theme.accent.opacity(0.6) : Theme.stroke,
                                          lineWidth: urlFocused || error != nil ? 1.5 : 1))
                )

                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.State.cancelled)
                } else if step == .url {
                    HStack(spacing: 6) {
                        Text("Recent")
                            .foregroundStyle(Theme.textFaint)
                        ForEach(recents, id: \.self) { recent in
                            Text(recent)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(Capsule().fill(Theme.fill))
                                .contentShape(Capsule())
                                .onTapGesture { url = recent }
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(checks) { check in
                        HStack(spacing: 9) {
                            ZStack {
                                if check.done {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.State.merged)
                                } else {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .frame(width: 16)
                            Text(check.text).foregroundStyle(check.done ? Theme.text : Theme.textMuted)
                            Spacer()
                            if let detail = check.detail, check.done {
                                Text(detail)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                        .font(.system(size: 13))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fillSubtle))
            }

            PrimaryWideButton(title: step == .connecting ? "Connecting…" : "Connect", icon: "arrow.right",
                              enabled: !url.trimmingCharacters(in: .whitespaces).isEmpty && step == .url, action: connect)
        }
        .onAppear { urlFocused = true }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            factoryHeader

            VStack(alignment: .leading, spacing: 8) {
                Text(step == .authorizing ? "Finish signing in on GitHub" : "Sign in to join")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(signInBlurb)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == .authorizing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for GitHub…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("Enter \(device?.userCode ?? "WDJB-MJHT") on github.com/login/device")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text("Open again")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .onTapGesture { if let device { NSWorkspace.shared.open(device.verificationUri) } }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fillSubtle))
            } else if health?.signIn == "dev" {
                HStack(spacing: 10) {
                    Image(systemName: "hammer").font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(width: 18)
                    Text("Local dev server: signs you in as @\(health?.devLogin ?? "dev"), an admin, without GitHub.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    permission("person.crop.circle", "Your name and avatar")
                    permission("building.2", "Membership in \(orgName), to match your team")
                    permission("lock.shield", "Nothing else. Agents use the factory's own GitHub App for PRs.")
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.State.cancelled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GitHubButton(waiting: step == .authorizing, title: health?.signIn == "dev" ? "Continue as @\(health?.devLogin ?? "dev")" : nil) { signIn() }

            HStack(spacing: 4) {
                Text("Wrong factory?")
                    .foregroundStyle(Theme.textFaint)
                Text("Change address")
                    .foregroundStyle(Theme.textMuted)
                    .underline()
                    .onTapGesture {
                        signInTask?.cancel()
                        withAnimation(.snappy) { step = .url; checks = []; error = nil; device = nil }
                    }
            }
            .font(.system(size: 12))
        }
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: -10) {
                    if let member = signedIn?.member {
                        MemberAvatar(member: member, size: 52)
                            .overlay(Circle().stroke(Theme.editorBG, lineWidth: 3))
                    } else {
                        AgentAvatar(agent: FactoryData.me, size: 52)
                            .overlay(Circle().stroke(Theme.editorBG, lineWidth: 3))
                    }
                    MapleMark(size: 52)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.editorBG, lineWidth: 3))
                }
                Text("You're in, \(firstName)")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Signed in as @\(signedIn?.member.login ?? "afomera") on \(server?.host() ?? "maple.atlas.dev").")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted)
            }

            if signedIn != nil {
                liveSummary
            } else {
                demoSummary
            }

            PrimaryWideButton(title: "Open workspace", icon: "arrow.right", enabled: true) {
                if signedIn != nil { state.destination = .machines }
                state.finishOnboarding(workspace: signedIn != nil ? client.workspaceName : "Studio Workspace")
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// What's live in the factory you just joined.
    private var liveSummary: some View {
        let online = client.machines.filter(\.online)
        let mine = client.machines.filter { $0.owner == signedIn?.member.login }
        let sessions = online.flatMap(\.sessions).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MapleMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(orgName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(client.machines.count) machines · \(signedIn?.member.role == "admin" ? "you're an admin" : "member")\(signedIn?.member.teams.isEmpty == false ? " · " + signedIn!.member.teams.joined(separator: ", ") : "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                ConnectionPill()
            }
            .padding(14)
            Hairline()
            VStack(alignment: .leading, spacing: 10) {
                waiting("desktopcomputer", Theme.State.merged, "\(online.count) of \(client.machines.count) machines online")
                waiting("terminal", Theme.State.building, sessions == 1 ? "1 session running" : "\(sessions) sessions running")
                waiting(mine.isEmpty ? "plus.circle" : "person.crop.circle", Theme.accent,
                        mine.isEmpty ? "None of them are yours yet. Add one from Machines." : "\(mine.count) of them \(mine.count == 1 ? "is" : "are") yours")
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        )
    }

    private var demoSummary: some View {
        VStack(alignment: .leading, spacing: 22) {

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Studio Workspace").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("\(FactoryData.goals.count) goals · \(FactoryData.agents.count) agents · afomera/atlas-platform")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Facepile(people: FactoryData.people, size: 24, ringColor: Theme.cardBG)
                }
                .padding(14)
                Hairline()
                VStack(alignment: .leading, spacing: 10) {
                    waiting("hand.raised.fill", Theme.State.cancelled, "\(state.myHandRaises.count) agents need a hand from you")
                    waiting("checkmark.circle", Theme.State.awaitingApproval, "\(state.inbox(.approval, mine: true).count) plans waiting on your approval")
                    waiting("eye", Theme.State.reviewing, "Chris is looking at ATL-147 right now")
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            )

        }
    }

    // MARK: Pieces

    /// Opened from the workspace by accident: back out without touching the connected factory. Escape too.
    private var backButton: some View {
        Button(action: goBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text("Back to \(client.workspaceName)")
                Text("esc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke))
                    .padding(.leading, 3)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Theme.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Back to the workspace (Esc)")
    }

    private var orgName: String {
        let org = signedIn?.org ?? health?.org ?? ""
        return org.isEmpty ? "Atlas Factory" : org
    }

    private var firstName: String {
        guard let member = signedIn?.member else { return "Andrea" }
        return member.name?.split(separator: " ").first.map(String.init) ?? member.login
    }

    private var signInBlurb: String {
        if step == .authorizing {
            return "We opened github.com in your browser. Enter the code there and approve Maple; you'll come straight back here."
        }
        switch health?.signIn {
        case "dev": return "No GitHub needed here."
        case "unconfigured": return "This factory hasn't finished setup: GitHub sign-in isn't configured yet."
        default: return "Members of \(orgName) sign in with GitHub. Your org membership and teams decide what you can do here."
        }
    }

    private var recents: [String] {
        let saved = AppDefaults.stringArray(forKey: "recentFactories") ?? []
        return Array((saved + (demo ? ["maple.atlas.dev"] : ["localhost:8788"])).reduce(into: [String]()) { list, item in
            if !list.contains(item) { list.append(item) }
        }.prefix(3))
    }

    private var factoryHeader: some View {
        HStack(spacing: 12) {
            MapleMark(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(orgName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 5) {
                    Image(systemName: server?.scheme == "http" ? "lock.open" : "lock.fill").font(.system(size: 9))
                    Text(server?.host().map { host in server?.port.map { "\(host):\($0)" } ?? host } ?? (url.isEmpty ? "maple.atlas.dev" : url))
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(Theme.State.merged).frame(width: 6, height: 6)
                Text("Connected")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.State.merged)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Theme.State.merged.opacity(0.12)))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        )
    }

    private func permission(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text.opacity(0.85))
        }
    }

    private func waiting(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.85))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("No factory yet?")
            Text("Set one up at maplefactory.dev")
                .foregroundStyle(Theme.textMuted)
                .underline()
            Text("·")
            Text("Maple 0.9")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textFaint)
    }

    private var backdrop: some View {
        ZStack {
            VisualEffect(material: .sidebar)
            Theme.editorBG.opacity(0.75)
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 520)
        }
    }

    // MARK: Flow

    private func goBack() {
        cancelled = true
        signInTask?.cancel()
        state.cancelOnboarding()
    }

    private func connect() {
        let host = url.trimmingCharacters(in: .whitespaces)
        guard step == .url, !host.isEmpty else { return }
        guard host.contains(".") || host.contains(":") || host == "localhost" else {
            withAnimation(.snappy) { error = "That doesn't look like an address. Try something like maple.yourcompany.dev" }
            return
        }
        error = nil
        withAnimation(.snappy) { step = .connecting }
        demo ? playDemoConnect(host) : realConnect(host)
    }

    private func realConnect(_ host: String) {
        guard let target = FactoryClient.serverURL(from: host) else {
            withAnimation(.snappy) { error = "That doesn't look like an address."; step = .url }
            return
        }
        Task { @MainActor in
            let reach = Check(text: "Reaching \(target.host() ?? host)")
            withAnimation(.snappy(duration: 0.25)) { checks = [reach] }
            do {
                let (found, took) = try await FactoryClient.probe(target)
                guard !cancelled else { return }
                let ms = Int(took.components.attoseconds / 1_000_000_000_000_000) + Int(took.components.seconds) * 1000
                mark(reach.id, detail: "\(ms) ms")
                let secure = Check(text: target.scheme == "https" ? "Secure connection" : "Local connection",
                                   detail: target.scheme == "https" ? "HTTPS" : "not encrypted")
                withAnimation(.snappy(duration: 0.25)) { checks.append(secure) }
                try? await Task.sleep(for: .milliseconds(350))
                mark(secure.id, detail: secure.detail)
                let factory = Check(text: "Found \(found.org.map { "the \($0) factory" } ?? "a Maple factory")", detail: "protocol \(found.protocolVersion)")
                withAnimation(.snappy(duration: 0.25)) { checks.append(factory) }
                try? await Task.sleep(for: .milliseconds(350))
                mark(factory.id, detail: factory.detail)
                guard found.protocolVersion == Int(Wire.protocolVersion) else {
                    fail("This factory speaks protocol \(found.protocolVersion); this app speaks \(Wire.protocolVersion). Update whichever is older.")
                    return
                }
                server = target
                health = found
                try? await Task.sleep(for: .milliseconds(700))
                guard !cancelled else { return }
                withAnimation(.snappy(duration: 0.35)) { step = .signIn }
            } catch {
                guard !cancelled else { return }
                fail(FactoryClient.describe(error))
            }
        }
    }

    private func mark(_ id: String, detail: String?) {
        withAnimation(.snappy(duration: 0.2)) {
            if let index = checks.firstIndex(where: { $0.id == id }) {
                checks[index].done = true
                checks[index].detail = detail
            }
        }
    }

    private func fail(_ message: String) {
        withAnimation(.snappy) {
            error = message
            checks = []
            step = .url
        }
    }

    private func playDemoConnect(_ host: String) {
        let steps: [Check] = [
            Check(text: "Reaching \(host)", detail: "38 ms"),
            Check(text: "Checking the certificate", detail: "TLS 1.3"),
            Check(text: "Found Atlas Factory", detail: "Maple 0.9.2"),
        ]
        Task { @MainActor in
            for check in steps {
                withAnimation(.snappy(duration: 0.25)) { checks.append(check) }
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation(.snappy(duration: 0.2)) {
                    if let index = checks.firstIndex(where: { $0.id == check.id }) { checks[index].done = true }
                }
            }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.snappy(duration: 0.35)) { step = .signIn }
        }
    }

    private func signIn() {
        guard step == .signIn else { return }
        error = nil
        if demo {
            withAnimation(.snappy) { step = .authorizing }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.snappy(duration: 0.4)) { step = .ready }
            }
            return
        }
        guard let server, let health else { return }
        signInTask = Task { @MainActor in
            do {
                switch health.signIn {
                case "dev":
                    finish(try await FactoryClient.devSignIn(server))
                case "github":
                    let code = try await FactoryClient.startDeviceFlow(server)
                    device = code
                    withAnimation(.snappy) { step = .authorizing }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    NSWorkspace.shared.open(code.verificationUri)
                    let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                    while Date() < deadline, !Task.isCancelled {
                        try await Task.sleep(for: .seconds(code.interval))
                        if let result = try await FactoryClient.pollDeviceFlow(server, code: code.deviceCode) {
                            finish(result)
                            return
                        }
                    }
                    if !Task.isCancelled { throw FactoryClient.ClientError.message("The code expired. Try again.") }
                default:
                    throw FactoryClient.ClientError.message("An owner of the GitHub org needs to finish setting up this factory: open its /setup page in a browser.")
                }
            } catch is CancellationError {
            } catch {
                withAnimation(.snappy) {
                    self.error = FactoryClient.describe(error)
                    step = .signIn
                }
            }
        }
    }

    private func finish(_ result: FactoryClient.SignInResult) {
        // A sign-in that answers after going back mustn't swap out the factory still connected.
        guard !cancelled else { return }
        var recent = AppDefaults.stringArray(forKey: "recentFactories") ?? []
        recent.removeAll { $0 == url }
        recent.insert(url, at: 0)
        AppDefaults.set(Array(recent.prefix(5)), forKey: "recentFactories")
        client.signIn(result)
        signedIn = result
        // A headless run has nobody to click Open workspace: on to the `-destination` it asked for.
        if Headless.isOn { return state.finishOnboarding(workspace: client.workspaceName) }
        withAnimation(.snappy(duration: 0.4)) { step = .ready }
    }
}

// MARK: Shared bits

struct StepDots: View {
    let current: OnboardingView.Step

    var body: some View {
        let index = switch current {
        case .url, .connecting: 0
        case .signIn, .authorizing: 1
        case .ready: 2
        }

        HStack(spacing: 14) {
            ForEach(Array(["Factory", "Sign in", "Ready"].enumerated()), id: \.offset) { offset, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(offset <= index ? Theme.accent : Theme.fill)
                            .frame(width: 18, height: 18)
                        if offset < index {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.onAccent)
                        } else {
                            Text("\(offset + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(offset == index ? Theme.onAccent : Theme.textMuted)
                        }
                    }
                    Text(title)
                        .font(.system(size: 12, weight: offset == index ? .semibold : .regular))
                        .foregroundStyle(offset <= index ? Theme.text : Theme.textMuted)
                }
                if offset < 2 {
                    Capsule().fill(offset < index ? Theme.accent.opacity(0.5) : Theme.stroke).frame(width: 28, height: 2)
                }
            }
        }
    }
}

struct MapleMark: View {
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: MapleIcon.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: Color(hex: 0xF0643C).opacity(0.25), radius: size * 0.2, y: size * 0.08)
    }
}

enum MapleIcon {
    @MainActor static let image: NSImage = Bundle.module.image(forResource: "AppIcon") ?? NSImage()

    /// The square artwork inset and masked to the macOS icon shape, for the Dock when running unbundled.
    @MainActor static let dockImage: NSImage = dockImage(image)

    /// Any square-ish artwork (a factory's icon, say) drawn the same way, filling the shape.
    static func dockImage(_ artwork: NSImage) -> NSImage {
        let side: CGFloat = 1024
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let rect = NSRect(x: 100, y: 100, width: side - 200, height: side - 200)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            shape.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            shape.addClip()
            artwork.draw(in: FactoryIcon.aspectFill(artwork.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

private struct PrimaryWideButton: View {
    let title: String
    let icon: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.onAccent)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(enabled ? 1 : 0.45)))
        .contentShape(Rectangle())
        .onTapGesture { if enabled { action() } }
    }
}

private struct GitHubButton: View {
    let waiting: Bool
    /// Replaces "Continue with GitHub", e.g. on a local dev server.
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if title == nil { GitHubMark().frame(width: 18, height: 18) }
            Text(waiting ? "Waiting for GitHub…" : title ?? "Continue with GitHub")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color(light: .white, dark: Color(hex: 0x1F2328)))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(light: Color(hex: 0x1F2328), dark: .white)).opacity(waiting ? 0.6 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The Octocat silhouette, drawn so it doesn't need an image asset.
private struct GitHubMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 16
            var path = Path()
            // Simplified from GitHub's 16×16 mark.
            path.addPath(Path(ellipseIn: CGRect(x: 0, y: 0, width: 16 * s, height: 16 * s)))
            var cut = Path()
            cut.move(to: CGPoint(x: 6 * s, y: 15.6 * s))
            cut.addLine(to: CGPoint(x: 6 * s, y: 13 * s))
            cut.addCurve(to: CGPoint(x: 3.2 * s, y: 11.6 * s), control1: CGPoint(x: 4.4 * s, y: 13.3 * s), control2: CGPoint(x: 3.6 * s, y: 12.4 * s))
            cut.addCurve(to: CGPoint(x: 3.6 * s, y: 6 * s), control1: CGPoint(x: 2.4 * s, y: 10 * s), control2: CGPoint(x: 2.6 * s, y: 7.2 * s))
            cut.addLine(to: CGPoint(x: 3.5 * s, y: 3.8 * s))
            cut.addLine(to: CGPoint(x: 5.6 * s, y: 4.8 * s))
            cut.addCurve(to: CGPoint(x: 10.4 * s, y: 4.8 * s), control1: CGPoint(x: 7.2 * s, y: 4.4 * s), control2: CGPoint(x: 8.8 * s, y: 4.4 * s))
            cut.addLine(to: CGPoint(x: 12.5 * s, y: 3.8 * s))
            cut.addLine(to: CGPoint(x: 12.4 * s, y: 6 * s))
            cut.addCurve(to: CGPoint(x: 12.8 * s, y: 11.6 * s), control1: CGPoint(x: 13.4 * s, y: 7.2 * s), control2: CGPoint(x: 13.6 * s, y: 10 * s))
            cut.addCurve(to: CGPoint(x: 10 * s, y: 13 * s), control1: CGPoint(x: 12.4 * s, y: 12.4 * s), control2: CGPoint(x: 11.6 * s, y: 13.3 * s))
            cut.addLine(to: CGPoint(x: 10 * s, y: 15.6 * s))
            cut.closeSubpath()
            context.fill(path, with: .foreground)
            context.blendMode = .destinationOut
            context.fill(cut, with: .color(.black))
        }
        .compositingGroup()
    }
}
