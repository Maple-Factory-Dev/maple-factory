import SwiftUI
import WebKit

// MARK: Model

/// A picture of the change, made by the planner so you can approve the design along with the plan.
struct Mockup: Identifiable {
    enum Kind {
        case screen(ScreenMock, url: String)
        case terminal([TermMockLine])
        /// A planner's mockup: a small self-contained page.
        case html(String, url: String)
    }

    enum Status {
        case proposed, approved, changesRequested

        var title: String {
            switch self {
            case .proposed: "Proposed"
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            }
        }

        var color: Color {
            switch self {
            case .proposed: Theme.State.planning
            case .approved: Theme.State.merged
            case .changesRequested: Theme.State.awaitingApproval
            }
        }
    }

    let id: String
    let title: String
    let kind: Kind
    /// Numbered callouts, matching the markers drawn on the mockup.
    let notes: [String]
    var status: Status = .proposed
    var version = 1
    /// Once built: how closely the real screenshot matches, and what differs.
    var match: Double? = nil
    var differences: [String] = []

    var icon: String {
        if case .terminal = kind { return "terminal" }
        return "macwindow"
    }
}

/// The screens the mock factory knows how to draw.
enum ScreenMock {
    case loginDefault, loginLockedOut
    case sessions, sessionsConfirm
    case passkeys
}

struct TermMockLine: Hashable {
    enum Style { case command, output, highlight, dim, error }
    let text: String
    var style: Style = .output
    /// Callout number pinned to this line.
    var callout: Int? = nil
}

extension FactoryData {
    static let seedMockups: [String: [Mockup]] = [
        "ATL-141": [
            Mockup(id: "default", title: "Sign in (unchanged)", kind: .screen(.loginDefault, url: "atlas.dev/login"),
                   notes: ["The swap is invisible: the login page looks and behaves as it does today."]),
        ],
        "ATL-152": [
            Mockup(id: "locked", title: "Locked out", kind: .screen(.loginLockedOut, url: "atlas.dev/login"),
                   notes: [
                       "Banner replaces the inline \"wrong password\" error and says when to try again.",
                       "Button is disabled and counts down instead of failing silently.",
                       "Reset link stays available, so locked-out users have a way forward.",
                   ], version: 2),
            Mockup(id: "default", title: "Sign in (unchanged)", kind: .screen(.loginDefault, url: "atlas.dev/login"),
                   notes: ["No visual change until the 5th failed attempt."]),
            Mockup(id: "api", title: "API response", kind: .terminal([
                TermMockLine(text: "$ for i in {1..6}; do curl -s -o /dev/null -w \"%{http_code} \" -X POST $API/login -d @bad.json; done", style: .command),
                TermMockLine(text: "401 401 401 401 401 429", style: .highlight, callout: 1),
                TermMockLine(text: "$ curl -i -X POST $API/login -d @bad.json", style: .command),
                TermMockLine(text: "HTTP/2 429", style: .error),
                TermMockLine(text: "retry-after: 892", style: .highlight, callout: 2),
                TermMockLine(text: "x-ratelimit-scope: account", style: .output),
                TermMockLine(text: "{\"error\":\"too_many_attempts\",\"retry_in\":892}", style: .dim),
            ]), notes: [
                "The 6th attempt in 15 minutes gets a 429, per account and per IP.",
                "retry-after drives the countdown on the login page.",
            ]),
        ],
        "ATL-150": [
            Mockup(id: "sessions", title: "Active sessions", kind: .screen(.sessions, url: "atlas.dev/settings/security"),
                   notes: [
                       "This device is labelled and can't be signed out from here.",
                       "One destructive button, below the list it affects.",
                   ],
                   status: .approved, version: 1, match: 0.97,
                   differences: ["Button reads \"Sign out of all devices\" instead of \"Sign out everywhere\"", "Last-active times use relative dates"]),
            Mockup(id: "confirm", title: "Confirm", kind: .screen(.sessionsConfirm, url: "atlas.dev/settings/security"),
                   notes: ["Says how many devices, and that this one stays signed in."],
                   status: .approved, match: 1.0),
        ],
        "ATL-147": [
            Mockup(id: "alias", title: "Deprecated alias", kind: .terminal([
                TermMockLine(text: "$ curl -i -X POST $API/api/auth/token -H \"Cookie: rt=…\"", style: .command),
                TermMockLine(text: "HTTP/2 200", style: .output),
                TermMockLine(text: "deprecation: true", style: .highlight, callout: 1),
                TermMockLine(text: "sunset: Thu, 14 Jan 2027 00:00:00 GMT", style: .highlight),
                TermMockLine(text: "link: </api/auth/refresh>; rel=\"successor-version\"", style: .highlight, callout: 2),
                TermMockLine(text: "set-cookie: rt=…; HttpOnly; Secure; SameSite=Strict", style: .dim),
            ]), notes: [
                "Old endpoint keeps working for mobile 2.13 but announces it's going away.",
                "Points clients at the new route.",
            ], version: 2),
            Mockup(id: "reuse", title: "Reuse detected", kind: .terminal([
                TermMockLine(text: "$ curl -s -X POST $API/api/auth/refresh -H \"Cookie: rt=$OLD_TOKEN\" | jq", style: .command),
                TermMockLine(text: "{", style: .output),
                TermMockLine(text: "  \"error\": \"refresh_token_reused\",", style: .error, callout: 1),
                TermMockLine(text: "  \"revoked\": \"family\"", style: .highlight),
                TermMockLine(text: "}", style: .output),
            ]), notes: ["Replaying a rotated token fails and revokes every token in its family."]),
        ],
        "ATL-161": [
            Mockup(id: "passkeys", title: "Passkeys", kind: .screen(.passkeys, url: "atlas.dev/settings/security"),
                   notes: [
                       "Each passkey shows where it lives and when it was last used.",
                       "Adding one starts the browser's passkey prompt directly.",
                   ]),
            Mockup(id: "passkeys-html", title: "Passkeys (HTML)", kind: .html(passkeysHTML, url: "atlas.dev/settings/security"),
                   notes: [
                       "Two columns on a desktop, one under the other on a tablet.",
                       "On a phone the nav becomes tabs and each passkey a card.",
                   ]),
        ],
    ]

    /// A planner's responsive HTML mockup: open it large and try Desktop, Tablet and Mobile (MF-296).
    static let passkeysHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
    *{box-sizing:border-box}body{margin:0;font:14px -apple-system,sans-serif;color:#1d2025;background:#f4f5f7}
    header{display:flex;align-items:center;gap:12px;padding:14px 24px;background:#fff;border-bottom:1px solid #e2e4e8}
    header b{font-size:16px}header span{margin-left:auto;color:#6a707a;font-size:12px}
    .wrap{display:grid;grid-template-columns:220px 1fr;gap:24px;max-width:1100px;margin:24px auto;padding:0 24px}
    nav{display:flex;flex-direction:column;gap:2px}nav a{padding:8px 12px;border-radius:7px;color:#6a707a;text-decoration:none}
    nav a.on{background:#fff;color:#1d2025;font-weight:600;box-shadow:0 0 0 1px #e2e4e8}
    main{background:#fff;border:1px solid #e2e4e8;border-radius:12px;padding:24px}h1{margin:0 0 4px;font-size:20px}
    p.sub{margin:0 0 20px;color:#6a707a}.list{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}
    .key{display:flex;gap:12px;align-items:center;padding:14px;border:1px solid #e2e4e8;border-radius:10px}
    .icon{width:36px;height:36px;border-radius:9px;background:#eef3ff;display:grid;place-items:center;font-size:18px}
    .key small{display:block;color:#6a707a;margin-top:2px}.key button{margin-left:auto}
    button{font:inherit;border:1px solid #e2e4e8;background:#fff;border-radius:7px;padding:6px 12px}
    .add{margin-top:20px;background:#2f6feb;color:#fff;border-color:#2f6feb;padding:9px 16px}
    .badge{font-size:11px;color:#6a707a;border:1px solid #e2e4e8;border-radius:99px;padding:2px 8px}
    @media (max-width:1000px){.list{grid-template-columns:1fr}}
    @media (max-width:700px){.wrap{grid-template-columns:1fr;margin:0;padding:0;gap:0}
    nav{flex-direction:row;overflow:auto;background:#fff;border-bottom:1px solid #e2e4e8;padding:6px 12px}
    nav a.on{box-shadow:none;background:#f1f2f4}main{border:0;border-radius:0;padding:18px 16px}
    header span{display:none}.key{flex-wrap:wrap}.key button{margin-left:48px}.add{width:100%}}
    </style></head><body>
    <header><b>Atlas</b><span class="badge">Settings</span><span>ana@atlas.dev</span></header>
    <div class="wrap"><nav><a>Profile</a><a class="on">Security</a><a>Notifications</a><a>Billing</a></nav>
    <main><h1>Passkeys</h1><p class="sub">Sign in with your fingerprint, face or a security key instead of a password.</p>
    <div class="list">
    <div class="key"><div class="icon">💻</div><div><b>MacBook Pro</b><small>iCloud Keychain · used today</small></div><button>Remove</button></div>
    <div class="key"><div class="icon">📱</div><div><b>iPhone 16</b><small>iCloud Keychain · used 3 days ago</small></div><button>Remove</button></div>
    <div class="key"><div class="icon">🔑</div><div><b>YubiKey 5C</b><small>Security key · used last month</small></div><button>Remove</button></div>
    </div><button class="add">Add a passkey</button></main></div></body></html>
    """
}

extension AppState {
    func requestMockupChange(_ taskID: String, mockup: Mockup, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let client, isLive {
            client.send(.taskMockupChange(.init(id: taskID, mockup: mockup.id, text: trimmed)))
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            steering[taskID, default: []].append(
                ChangeRequest(author: FactoryData.me, text: trimmed, anchor: "Mockup: \(mockup.title)", timing: "Next mockup version")
            )
            update(taskID) { task in
                guard let index = task.mockups.firstIndex(where: { $0.id == mockup.id }) else { return }
                task.mockups[index].status = .changesRequested
            }
        }
        showToast("\(task(taskID).agent?.name ?? "Agent") will post mockup v\(mockup.version + 1)", icon: "paintbrush.pointed.fill", color: Theme.State.planning)
    }
}

// MARK: Section

/// The task's mockups: pick one, see it drawn with numbered callouts, compare it with what got built.
struct MockupsSection: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    @State private var selected: String
    @State private var view: Compare = .mockup
    @State private var commenting = false
    @State private var draft = ""

    enum Compare: String, CaseIterable { case mockup = "Mockup", built = "Built", side = "Side by side" }

    init(task: FactoryTask) {
        self.task = task
        _selected = State(initialValue: task.mockups.first?.id ?? "")
        // `-mockview side` opens built tasks on the side-by-side comparison.
        if AppDefaults.string(forKey: "mockview") == "side" { _view = State(initialValue: .side) }
        // `-mockup <id>` opens on that one, for screenshots.
        if let wanted = AppDefaults.string(forKey: "mockup"), task.mockups.contains(where: { $0.id == wanted }) {
            _selected = State(initialValue: wanted)
        }
    }

    private var mockup: Mockup? { task.mockups.first { $0.id == selected } ?? task.mockups.first }
    private var isBuilt: Bool { task.state == .reviewing || task.state == .merged }

    var body: some View {
        if let mockup {
            TaskSection(title: "Mockups") {
                VStack(alignment: .leading, spacing: 12) {
                    picker
                    canvas(mockup)
                    notes(mockup)
                }
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(task.mockups) { item in
                let active = item.id == mockup?.id
                HStack(spacing: 5) {
                    Image(systemName: item.icon).font(.system(size: 10.5))
                    Text(item.title)
                    if item.version > 1 {
                        Text("v\(item.version)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                    Circle().fill(item.status.color).frame(width: 6, height: 6)
                }
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(active ? Theme.cardBG : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? Theme.stroke : .clear))
                )
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selected = item.id } }
            }
            Spacer()
            if isBuilt, case .screen = mockup?.kind {
                Picker("", selection: $view) {
                    ForEach(Compare.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if task.state == .planning || task.state == .awaitingApproval {
                Text("Approved together with the plan")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    @ViewBuilder private func canvas(_ mockup: Mockup) -> some View {
        VStack(spacing: 0) {
            Group {
                switch mockup.kind {
                case .terminal(let lines):
                    TerminalMock(lines: lines)
                case .html(let html, let url):
                    BrowserFrame(url: url) { HTMLMock(html: html).frame(height: 380) }
                        .frame(maxWidth: 640)
                        // MF-296: opened large, at Desktop, Tablet or Mobile width; a double-click does the same.
                        .overlay(alignment: .topTrailing) { ExpandPageButton { openLarge(html, mockup) } }
                        .onTapGesture(count: 2) { openLarge(html, mockup) }
                        .onReceive(NotificationCenter.default.publisher(for: PageViewerView.demoOpen)) { _ in
                            if state.lightbox == nil { openLarge(html, mockup) }
                        }
                case .screen(let screen, let url):
                    if isBuilt, view == .side {
                        HStack(alignment: .top, spacing: 14) {
                            labelled("Mockup") { BrowserFrame(url: url) { MockScreen(screen: screen, built: false, callouts: false, compact: true) } }
                            labelled("Built · preview-491") { BrowserFrame(url: url) { MockScreen(screen: screen, built: true, callouts: false, compact: true) } }
                        }
                    } else {
                        BrowserFrame(url: url) {
                            MockScreen(screen: screen, built: isBuilt && view == .built, callouts: !(isBuilt && view == .built))
                        }
                        .frame(maxWidth: 560)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(DotGrid())
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    private func openLarge(_ html: String, _ mockup: Mockup) {
        state.showLightbox(.page(html: html, caption: mockup.title, scripts: false))
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func notes(_ mockup: Mockup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let match = mockup.match, isBuilt {
                HStack(spacing: 8) {
                    Image(systemName: match >= 0.99 ? "checkmark.seal.fill" : "checkmark.seal")
                        .foregroundStyle(Theme.State.merged)
                    Text("Built version matches the mockup · \(Int(match * 100))% visual match")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                ForEach(mockup.differences, id: \.self) { difference in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "plusminus").font(.system(size: 10)).foregroundStyle(Theme.State.awaitingApproval)
                        Text(difference).font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.leading, 2)
                }
            }

            ForEach(Array(mockup.notes.enumerated()), id: \.offset) { index, note in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    CalloutDot(number: index + 1)
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(mockup.status.color).frame(width: 6, height: 6)
                    Text("\(mockup.status.title) · v\(mockup.version) by \(task.authorName ?? "the planner")")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                Spacer()
                if task.canRequestMockupChange {
                    Text(commenting ? "Cancel" : "Request a change to this mockup")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.State.planning)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { commenting.toggle() } }
                }
            }
            .padding(.top, 2)

            if commenting, task.canRequestMockupChange {
                HStack(spacing: 8) {
                    TextField("e.g. Put the countdown in the banner, not the button", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.cardBG)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.State.planning.opacity(0.5)))
                        )
                        .onSubmit(send)
                    Text("Send")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.State.planning))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: send)
                }
            }
        }
    }

    private func send() {
        guard let mockup else { return }
        state.requestMockupChange(task.id, mockup: mockup, text: draft)
        draft = ""
        commenting = false
    }
}

// MARK: Drawing

struct CalloutDot: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Theme.State.planning))
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 14
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(Theme.textFaint.opacity(0.35)))
                }
            }
        }
        .background(Theme.fillSubtle)
    }
}

/// A minimal browser window around a mocked screen.
private struct BrowserFrame<Content: View>: View {
    let url: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Mock.chromeDot).frame(width: 8, height: 8) }
                Text(url)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Mock.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Mock.field))
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Mock.chrome)
            content
                .frame(maxWidth: .infinity)
                .background(Mock.page)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Mock.border))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
}

/// Mocked product screens. Always light, like the product they depict.
struct MockScreen: View {
    let screen: ScreenMock
    var built = false
    var callouts = true
    /// Half-width rendering for side-by-side: drops the settings nav.
    var compact = false

    var body: some View {
        switch screen {
        case .loginDefault: login(locked: false)
        case .loginLockedOut: login(locked: true)
        case .sessions: sessions(confirm: false)
        case .sessionsConfirm: sessions(confirm: true)
        case .passkeys: passkeys
        }
    }

    private func pin(_ number: Int) -> some View {
        Group { if callouts { CalloutDot(number: number).offset(x: 9, y: -9) } }
    }

    private func login(locked: Bool) -> some View {
        VStack(spacing: 12) {
            Circle().fill(Mock.ink).frame(width: 26, height: 26)
                .overlay(Text("A").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
            Text("Sign in to Atlas").font(.system(size: 15, weight: .semibold)).foregroundStyle(Mock.ink)
            if locked {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).padding(.top, 2)
                    Text("Too many sign-in attempts. Try again in 14:52.")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Mock.danger)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Mock.danger.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Mock.danger.opacity(0.3)))
                .overlay(alignment: .topTrailing) { pin(1) }
            }
            field("Email", "dana@acme.com")
            field("Password", "••••••••••")
            Text(locked ? "Try again in 14:52" : "Sign in")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(locked ? Mock.muted : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(locked ? Mock.field : Mock.ink))
                .overlay(alignment: .topTrailing) { if locked { pin(2) } }
            Text("Forgot your password?")
                .font(.system(size: 11.5))
                .foregroundStyle(Mock.link)
                .overlay(alignment: .topTrailing) { if locked { pin(3) } }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white).shadow(color: .black.opacity(0.06), radius: 6, y: 2))
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(Mock.backdrop)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Mock.muted)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Mock.ink)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Mock.border))
        }
    }

    private func sessions(confirm: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(["Profile", "Security", "Billing", "Notifications"], id: \.self) { item in
                    Text(item)
                        .font(.system(size: 11.5, weight: item == "Security" ? .semibold : .regular))
                        .foregroundStyle(item == "Security" ? Mock.ink : Mock.muted)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(item == "Security" ? Mock.field : .clear))
                }
            }
            .padding(10)
            .frame(width: 120)
            .frame(width: compact ? 0 : nil)
            .opacity(compact ? 0 : 1)
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text("Active sessions").font(.system(size: 14, weight: .semibold)).foregroundStyle(Mock.ink)
                VStack(spacing: 0) {
                    device("laptopcomputer", "MacBook Pro · Chrome", built ? "Active now" : "Now", current: true)
                    Rectangle().fill(Mock.border).frame(height: 1)
                    device("iphone", "iPhone 15 · Atlas app", built ? "2 hours ago" : "2h ago", current: false)
                    Rectangle().fill(Mock.border).frame(height: 1)
                    device("pc", "Windows · Edge", built ? "3 days ago" : "3d ago", current: false)
                }
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Mock.border))
                .overlay(alignment: .topTrailing) { pin(1) }

                Text(built ? "Sign out of all devices" : "Sign out everywhere")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Mock.danger)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Mock.danger.opacity(0.5)))
                    .overlay(alignment: .topTrailing) { pin(2) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 230, alignment: .top)
        .overlay {
            if confirm {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign out of 2 other devices?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Mock.ink)
                        Text("Your iPhone and Windows sessions end now. You stay signed in here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Mock.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer()
                            Text("Cancel").font(.system(size: 11.5)).foregroundStyle(Mock.ink)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Mock.border))
                            Text("Sign out").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Mock.danger))
                        }
                    }
                    .padding(16)
                    .frame(width: 260)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white))
                    .overlay(alignment: .topTrailing) { pin(1) }
                }
            }
        }
    }

    private func device(_ icon: String, _ name: String, _ when: String, current: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Mock.muted).frame(width: 16)
            Text(name).font(.system(size: 11.5)).foregroundStyle(Mock.ink).lineLimit(1)
            if current {
                Text("This device")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Mock.link)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Capsule().fill(Mock.link.opacity(0.1)))
            }
            Spacer()
            Text(when).font(.system(size: 10.5)).foregroundStyle(Mock.muted).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var passkeys: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Passkeys").font(.system(size: 14, weight: .semibold)).foregroundStyle(Mock.ink)
                Spacer()
                Text("Add a passkey")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Mock.ink))
                    .overlay(alignment: .topTrailing) { pin(2) }
            }
            Text("Sign in with Touch ID, Face ID or a security key instead of a password.")
                .font(.system(size: 11.5))
                .foregroundStyle(Mock.muted)
            VStack(spacing: 0) {
                device("key.fill", "iCloud Keychain", "Used today", current: false)
                Rectangle().fill(Mock.border).frame(height: 1)
                device("key.horizontal.fill", "YubiKey 5C", "Used 12 days ago", current: false)
            }
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Mock.border))
            .overlay(alignment: .topTrailing) { pin(1) }
        }
        .padding(18)
        .frame(height: 200, alignment: .top)
    }
}

/// A mocked terminal transcript with callouts pinned to lines.
private struct TerminalMock: View {
    let lines: [TermMockLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(line.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(color(line.style))
                        .fixedSize(horizontal: false, vertical: true)
                    if let callout = line.callout { CalloutDot(number: callout) }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 4)
                .background(line.style == .highlight ? Color(hex: 0xA48BFA).opacity(0.12) : .clear)
            }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x0E1014)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func color(_ style: TermMockLine.Style) -> Color {
        switch style {
        case .command: Color(hex: 0x4ED38B)
        case .output: Color(hex: 0xD8DCE3)
        case .highlight: Color(hex: 0xC9B8FF)
        case .dim: Color(hex: 0x7D8590)
        case .error: Color(hex: 0xF47C7C)
        }
    }
}

/// Product-screen palette: mockups depict the shipped app, which is light.
private enum Mock {
    static let page = Color.white
    static let backdrop = Color(hex: 0xF4F5F7)
    static let chrome = Color(hex: 0xEDEEF1)
    static let chromeDot = Color(hex: 0xD3D6DC)
    static let field = Color(hex: 0xF1F2F4)
    static let border = Color(hex: 0xE2E4E8)
    static let ink = Color(hex: 0x1D2025)
    static let muted = Color(hex: 0x6A707A)
    static let link = Color(hex: 0x2F6FEB)
    static let danger = Color(hex: 0xD14343)
}

/// A planner's HTML mockup, drawn without scripts or network: what's on the page is all there is.
struct HTMLMock: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: String?
    }
}
