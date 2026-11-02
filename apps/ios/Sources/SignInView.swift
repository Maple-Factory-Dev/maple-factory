import MapleKit
import SwiftUI

/// Signing into a factory: type its address, check it answers (/healthz), then GitHub's device flow (or a
/// local server's dev sign-in). Worded like the Mac's OnboardingView. Launch args mirror the Mac app's:
/// `-onboardingURL localhost:8788` fills in an address and connects, `-onboardingContinue YES` signs in too,
/// and `-onboardingStep address|connecting|signin|authorizing|failed` jumps to a step with sample data, no
/// server needed, for screenshots (SignInFlowTests).
struct SignInView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    enum Step: Equatable { case address, connecting, signIn, authorizing, signingIn }

    /// The GitHub device code being entered, and when it stops working.
    struct DeviceCode: Equatable {
        let userCode: String
        let deviceCode: String
        let uri: URL
        let expires: Date
    }

    @State private var address = ""
    @State private var step: Step = .address
    @State private var checks: [CheckRow.Check] = []
    @State private var hint: String?
    @State private var error: String?
    @State private var server: URL?
    @State private var health: FactoryAPI.Health?
    @State private var device: DeviceCode?
    @State private var opened = false
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    @State private var flow: Task<Void, Never>?
    @State private var sample = false
    @FocusState private var addressFocused: Bool
    private static var autoConnected = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StepDots(current: step == .address || step == .connecting ? 0 : 1)
                        .padding(.top, 8)
                    switch step {
                    case .address, .connecting: connectCard
                    case .signIn, .authorizing: signInCard
                    case .signingIn:
                        ProgressView("Signing in…").frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(24)
                .animation(.snappy, value: step)
                .animation(.snappy, value: checks)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear(perform: start)
        // Back from Safari after entering the code: ask now instead of at the next poll.
        .onChange(of: scenePhase) { if scenePhase == .active, step == .authorizing { pollNow() } }
        .onChange(of: device) { resetCopied() }
    }

    // MARK: Step 1: Connect

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image("Mark")
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text("Connect to a factory").font(.largeTitle.bold())
                Text("Enter the address your team runs Maple at. You'll sign in with GitHub next.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == .address, !recents.isEmpty { recentList }

            VStack(alignment: .leading, spacing: 8) {
                TextField("maple.yourteam.dev", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .disabled(step == .connecting)
                    .onSubmit(connect)
                    .onChange(of: address) { hint = nil }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(hint != nil ? Theme.danger : addressFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
                    )
                    .accessibilityIdentifier("signin-address")
                if let hint {
                    Label(hint, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signin-hint")
                }
            }

            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(checks) { CheckRow(check: $0).transition(.opacity.combined(with: .move(edge: .top))) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                .accessibilityIdentifier("signin-checks")
            }

            Button(action: connect) {
                HStack {
                    if step == .connecting { ProgressView().tint(.white) }
                    Text(step == .connecting ? "Connecting…" : failed ? "Try again" : "Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(step == .connecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("signin-continue")

            if step == .address { footer }
        }
    }

    /// Factories signed into before (or the sample's, with `-onboardingStep`): tap one to switch to it.
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(recents.enumerated()), id: \.element.id) { index, factory in
                    if index > 0 { Divider().padding(.leading, 50) }
                    Button { openRecent(factory) } label: {
                        HStack(spacing: 12) {
                            Text(String(factory.name.prefix(1)).uppercased())
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(factory.name).foregroundStyle(.primary)
                                Text(factory.host).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("signin-recent-\(factory.host)")
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("No factory yet?").foregroundStyle(.secondary)
                Link("Set one up at maplefactory.dev", destination: URL(string: "https://maplefactory.dev")!)
                    .accessibilityIdentifier("signin-setup")
            }
            .font(.footnote)
            Button { store.startDemo() } label: {
                Label("Or look around the demo", systemImage: "play.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("signin-demo")
        }
        .padding(.top, 4)
    }

    // MARK: Step 2: Sign in

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            FactoryHeader(org: orgName, host: server?.host() ?? address)

            VStack(alignment: .leading, spacing: 8) {
                Text(step == .authorizing ? "Finish signing in on GitHub" : "Sign in to join").font(.title.bold())
                Text(signInBlurb)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == .authorizing, let device {
                codeCard(device)
            } else if health?.signIn == "dev" {
                PermissionRow("hammer", "Local dev server: signs you in as @\(devLogin), an admin, without GitHub.")
            } else if health?.signIn == "github" {
                VStack(alignment: .leading, spacing: 12) {
                    Text("GitHub shares").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    PermissionRow("person.crop.circle", "Your name and avatar")
                    PermissionRow("building.2", "Membership in \(orgName), to match your team")
                    PermissionRow("lock.shield", "Nothing else. Agents use the factory's own GitHub App for PRs.")
                }
                .accessibilityIdentifier("signin-permissions")
            } else {
                PermissionRow("wrench.and.screwdriver",
                              "An owner of the GitHub org needs to finish setting up this factory: open its /setup page in a browser.")
                    .accessibilityIdentifier("signin-unconfigured")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signin-error")
            }

            if step == .signIn {
                Button(action: signIn) {
                    Label(health?.signIn == "dev" ? "Continue as @\(devLogin)" : "Sign in with GitHub",
                          systemImage: health?.signIn == "dev" ? "arrow.right" : "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(health?.signIn != "dev" && health?.signIn != "github")
                .accessibilityIdentifier("signin-github")
            }

            HStack(spacing: 4) {
                Text("Wrong factory?").foregroundStyle(.secondary)
                Button("Change address", action: reset).accessibilityIdentifier("signin-change")
            }
            .font(.footnote)
        }
    }

    /// The code to type on GitHub, with Copy, the button that opens GitHub, and how long it has left.
    private func codeCard(_ device: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(device.userCode)
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("signin-code")
                Spacer(minLength: 4)
                Button(action: copyCode) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .tint(copied ? Theme.approve : nil)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
                .accessibilityIdentifier("signin-copy")
                .sensoryFeedback(.success, trigger: copied) { _, now in now }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            Button {
                UIPasteboard.general.string = device.userCode
                openGitHub(device)
            } label: {
                Label("Copy code and open GitHub", systemImage: "safari").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("signin-open-github")

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for GitHub…").font(.subheadline.weight(.medium))
                        Text("Code expires in \(remaining(until: device.expires, now: context.date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    if opened {
                        Button("Open again") { openGitHub(device) }
                            .font(.subheadline.weight(.medium))
                            .accessibilityIdentifier("signin-open-again")
                    }
                }
            }
            .accessibilityIdentifier("signin-waiting")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Derived

    private var failed: Bool {
        checks.contains { if case .failed = $0.state { true } else { false } }
    }

    private var orgName: String { health?.org ?? server?.host() ?? "this factory" }
    private var devLogin: String { health?.devLogin ?? "dev" }

    private var signInBlurb: String {
        if step == .authorizing { return "Enter the code below on GitHub, then come back here. This finishes by itself." }
        switch health?.signIn {
        case "dev": return "This is a local dev server, so there's no GitHub step."
        case "github": return "Maple uses your GitHub account to know who you are on the \(orgName) team."
        default: return "This factory can't sign anyone in yet."
        }
    }

    private var recents: [SavedFactory] {
        sample ? Self.sampleRecents : store.saved
    }

    private func remaining(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Flow

    private func start() {
        if let jump = UserDefaults.standard.string(forKey: "onboardingStep") {
            sample = true
            playSample(jump)
            return
        }
        guard let typed = UserDefaults.standard.string(forKey: "onboardingURL"), !Self.autoConnected else { return }
        Self.autoConnected = true
        address = typed
        connect()
    }

    private func openRecent(_ factory: SavedFactory) {
        if sample { address = factory.host } else { store.switchTo(factory) }
    }

    private func connect() {
        guard step == .address else { return }
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        guard typed.contains(".") || typed.contains(":") || typed.hasPrefix("localhost"),
              let url = FactoryAPI.serverURL(from: typed) else {
            hint = "That doesn't look like an address. Try something like maple.yourteam.dev"
            return
        }
        hint = nil
        error = nil
        addressFocused = false
        step = .connecting
        if sample { return }
        let host = url.host() ?? typed
        Task {
            checks = [.init(key: "reach", text: "Reaching \(host)")]
            do {
                let (found, took) = try await FactoryAPI.probe(url)
                let ms = Int(took.components.seconds) * 1000 + Int(took.components.attoseconds / 1_000_000_000_000_000)
                mark("reach", detail: "\(ms) ms")
                let secure = url.scheme == "https"
                checks.append(.init(key: "secure", text: secure ? "Secure connection" : "Local connection",
                                    detail: secure ? "HTTPS" : "not encrypted"))
                try? await Task.sleep(for: .milliseconds(300))
                mark("secure")
                checks.append(.init(key: "factory", text: "Found \(found.org.map { "the \($0) factory" } ?? "a Maple factory")",
                                    detail: "protocol \(found.protocolVersion)"))
                try? await Task.sleep(for: .milliseconds(300))
                guard found.protocolVersion <= Wire.protocolVersion else {
                    fail("factory", Self.protocolMessage(found.protocolVersion))
                    return
                }
                mark("factory")
                server = url
                health = found
                try? await Task.sleep(for: .milliseconds(500))
                step = .signIn
                if UserDefaults.standard.bool(forKey: "onboardingContinue") {
                    try? await Task.sleep(for: .seconds(1))
                    signIn()
                }
            } catch {
                fail(checks.last { $0.state == .running }?.key ?? "reach", FactoryAPI.describe(error))
            }
        }
    }

    static func protocolMessage(_ theirs: Int) -> String {
        "This factory speaks protocol \(theirs); this app speaks \(Wire.protocolVersion). Update Maple Factory on this iPhone from the App Store or TestFlight."
    }

    private func mark(_ key: String, detail: String? = nil) {
        guard let index = checks.firstIndex(where: { $0.key == key }) else { return }
        checks[index].state = .done
        if let detail { checks[index].detail = detail }
    }

    /// Marks that check red with the reason under it, and goes back to the address (still typed) to retry.
    private func fail(_ key: String, _ reason: String) {
        if let index = checks.firstIndex(where: { $0.key == key }) { checks[index].state = .failed(reason) }
        step = .address
    }

    private func signIn() {
        guard step == .signIn else { return }
        error = nil
        if sample {
            device = Self.sampleDevice
            step = .authorizing
            return
        }
        guard let server, let health else { return }
        flow = Task {
            do {
                switch health.signIn {
                case "dev":
                    step = .signingIn
                    store.signedIn(try await FactoryStore.devSignIn(server))
                case "github":
                    let code = try await FactoryAPI.startDeviceFlow(server)
                    device = DeviceCode(userCode: code.userCode, deviceCode: code.deviceCode, uri: code.verificationUri,
                                        expires: Date().addingTimeInterval(TimeInterval(code.expiresIn)))
                    opened = false
                    step = .authorizing
                    while let device, Date() < device.expires, !Task.isCancelled {
                        try await Task.sleep(for: .seconds(code.interval))
                        if try await poll(server, device) { return }
                    }
                    if !Task.isCancelled { throw FactoryAPI.ClientError.message("The code expired. Try again.") }
                default:
                    return
                }
            } catch is CancellationError {
            } catch {
                self.error = FactoryAPI.describe(error)
                step = .signIn
            }
        }
    }

    /// One poll of GitHub's device flow; signs in and returns true once the code's been entered.
    private func poll(_ server: URL, _ device: DeviceCode) async throws -> Bool {
        guard let result = try await FactoryAPI.pollDeviceFlow(server, code: device.deviceCode, deviceLabel: FactoryStore.deviceLabel),
              step == .authorizing else { return false }
        flow?.cancel()
        step = .signingIn
        store.signedIn(result)
        return true
    }

    /// Back in the app: the code was likely just entered, so don't wait out the interval.
    private func pollNow() {
        guard !sample, let server, let device else { return }
        Task { _ = try? await poll(server, device) }
    }

    private func openGitHub(_ device: DeviceCode) {
        opened = true
        if !sample { openURL(device.uri) }
    }

    private func copyCode() {
        guard let device else { return }
        UIPasteboard.general.string = device.userCode
        copiedTask?.cancel()
        copied = true
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func resetCopied() {
        copiedTask?.cancel()
        copiedTask = nil
        copied = false
    }

    private func reset() {
        flow?.cancel()
        flow = nil
        server = sample ? server : nil
        health = sample ? health : nil
        device = nil
        error = nil
        checks = []
        step = .address
    }

    // MARK: Sample (`-onboardingStep`)

    private static let sampleRecents: [SavedFactory] = [
        SavedFactory(server: URL(string: "https://maple.atlas.dev")!, org: "atlas", name: "Atlas", lastUsed: Date()),
        SavedFactory(server: URL(string: "https://factory.acme.io")!, org: "acme", name: "Acme", lastUsed: Date()),
    ]

    private static var sampleDevice: DeviceCode {
        DeviceCode(userCode: "WDJB-MJHT", deviceCode: "sample", uri: URL(string: "https://github.com/login/device")!,
                   expires: Date().addingTimeInterval(14 * 60 + 32))
    }

    private static func sampleHealth(_ signIn: String) -> FactoryAPI.Health? {
        let json = #"{"ok":true,"protocol":\#(Wire.protocolVersion),"org":"atlas","signIn":"\#(signIn)","devLogin":"dev"}"#
        return try? JSONDecoder().decode(FactoryAPI.Health.self, from: Data(json.utf8))
    }

    /// Jumps to a step with made-up data: nothing is sent anywhere.
    private func playSample(_ jump: String) {
        let host = "maple.atlas.dev"
        let reach = CheckRow.Check(key: "reach", text: "Reaching \(host)", detail: "38 ms", state: .done)
        let secure = CheckRow.Check(key: "secure", text: "Secure connection", detail: "HTTPS", state: .done)
        let factory = CheckRow.Check(key: "factory", text: "Found the atlas factory", detail: "protocol \(Wire.protocolVersion)")
        switch jump {
        case "connecting":
            address = host
            checks = [reach, secure, factory]
            step = .connecting
        case "failed":
            address = host
            var mismatch = factory
            mismatch.detail = "protocol \(Wire.protocolVersion + 1)"
            mismatch.state = .failed(Self.protocolMessage(Int(Wire.protocolVersion) + 1))
            checks = [reach, secure, mismatch]
            step = .address
        case "signin", "dev", "unconfigured", "authorizing":
            address = host
            server = URL(string: "https://\(host)")
            health = Self.sampleHealth(jump == "signin" || jump == "authorizing" ? "github" : jump)
            step = .signIn
            if jump == "authorizing" {
                device = Self.sampleDevice
                opened = true
                step = .authorizing
            }
        default:
            step = .address
        }
    }
}
