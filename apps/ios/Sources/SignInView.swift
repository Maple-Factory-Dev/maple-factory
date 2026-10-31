import MapleKit
import SwiftUI

/// Signing into a factory: type its address, probe /healthz, then GitHub's device flow (or a local
/// server's dev sign-in). Launch args mirror the Mac app's, for screenshots of the real flow:
/// `-onboardingURL localhost:8788` fills in an address and connects, `-onboardingContinue YES` signs in too.
struct SignInView: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.openURL) private var openURL

    enum Step: Equatable {
        case address, probing, signIn(FactoryAPI.Health), waiting(code: String, uri: URL), signingIn
        static func == (a: Step, b: Step) -> Bool { String(describing: a) == String(describing: b) }
    }

    @State private var address = ""
    @State private var step: Step = .address
    @State private var server: URL?
    @State private var error: String?
    @State private var flow: Task<Void, Never>?
    private static var autoConnected = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    switch step {
                    case .address, .probing: addressCard
                    case .signIn(let health): signInCard(health)
                    case .waiting(let code, let uri): waitingCard(code: code, uri: uri)
                    case .signingIn: ProgressView("Signing in…").frame(maxWidth: .infinity)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.danger)
                    }
                    if !store.saved.isEmpty, step == .address { savedList }
                    demoButton
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear(perform: autoConnect)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("Mark")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Connect to a factory").font(.largeTitle.bold())
            Text("Enter the address your team runs Maple at. You'll sign in with GitHub next.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("maple.yourteam.dev", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(connect)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            Button(action: connect) {
                HStack {
                    if step == .probing { ProgressView().tint(.white) }
                    Text(step == .probing ? "Connecting…" : "Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(FactoryAPI.serverURL(from: address) == nil || step == .probing)
        }
    }

    private func signInCard(_ health: FactoryAPI.Health) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(server?.host() ?? "", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.approve)
            if let org = health.org { Text("The \(org) factory").font(.headline) }
            Button(action: signIn) {
                Label(health.signIn == "dev" ? "Sign in as \(health.devLogin ?? "dev")" : "Sign in with GitHub",
                      systemImage: health.signIn == "dev" ? "hammer" : "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(health.signIn == "unconfigured")
            if health.signIn == "unconfigured" {
                Text("This factory hasn't set up GitHub sign-in yet.").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Use another factory") { reset() }.font(.callout)
        }
    }

    private func waitingCard(code: String, uri: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter this code on GitHub").font(.headline)
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            Button {
                UIPasteboard.general.string = code
                openURL(uri)
            } label: {
                Label("Copy code and open GitHub", systemImage: "safari").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for GitHub…").foregroundStyle(.secondary)
            }
            Button("Cancel") { reset() }.font(.callout)
        }
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signed in before").font(.headline)
            ForEach(store.saved) { factory in
                Button { store.switchTo(factory) } label: {
                    HStack {
                        Image(systemName: "building.2")
                        VStack(alignment: .leading) {
                            Text(factory.name)
                            Text(factory.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var demoButton: some View {
        Button { store.startDemo() } label: {
            Label("Try the demo", systemImage: "play.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: Flow

    private func autoConnect() {
        guard let typed = UserDefaults.standard.string(forKey: "onboardingURL"), !Self.autoConnected else { return }
        Self.autoConnected = true
        address = typed
        connect()
    }

    private func connect() {
        guard let url = FactoryAPI.serverURL(from: address) else { return }
        error = nil
        step = .probing
        Task {
            do {
                let (health, _) = try await FactoryAPI.probe(url)
                guard health.protocolVersion <= Wire.protocolVersion else {
                    error = FactoryAPI.tooNewMessage
                    step = .address
                    return
                }
                server = url
                step = .signIn(health)
                if UserDefaults.standard.bool(forKey: "onboardingContinue") {
                    try? await Task.sleep(for: .seconds(1))
                    signIn()
                }
            } catch {
                self.error = FactoryAPI.describe(error)
                step = .address
            }
        }
    }

    private func signIn() {
        guard let server, case .signIn(let health) = step else { return }
        error = nil
        flow = Task {
            do {
                if health.signIn == "dev" {
                    step = .signingIn
                    store.signedIn(try await FactoryStore.devSignIn(server))
                    return
                }
                let code = try await FactoryAPI.startDeviceFlow(server)
                step = .waiting(code: code.userCode, uri: code.verificationUri)
                let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(code.interval))
                    if let result = try await FactoryAPI.pollDeviceFlow(server, code: code.deviceCode, deviceLabel: FactoryStore.deviceLabel) {
                        store.signedIn(result)
                        return
                    }
                }
                if !Task.isCancelled { error = "The code expired. Try again."; step = .signIn(health) }
            } catch is CancellationError {
            } catch {
                self.error = FactoryAPI.describe(error)
                step = .signIn(health)
            }
        }
    }

    private func reset() {
        flow?.cancel()
        flow = nil
        server = nil
        error = nil
        step = .address
    }
}
