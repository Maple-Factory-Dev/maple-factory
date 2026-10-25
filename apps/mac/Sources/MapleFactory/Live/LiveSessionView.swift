import SwiftUI

/// One live session full-size: its terminal, what it's doing, and the ways to leave it.
struct LiveSessionView: View {
    @Environment(FactoryClient.self) private var client
    let machineID: String
    let sessionID: String
    let onBack: () -> Void

    @State private var link: TerminalLink.State = .connecting
    @State private var confirmKill = false
    @State private var copied = false

    /// The session as last seen live, so the header keeps its agent and folder after it ends.
    @State private var lastSeen: Wire.LiveSession?

    private var machine: Wire.Machine? { client.machines.first { $0.id == machineID } }
    private var current: Wire.LiveSession? { machine?.sessions.first { $0.session.id == sessionID } }
    private var live: Wire.LiveSession? { current ?? lastSeen }
    private var ended: FactoryClient.EndRecord? { client.ends.first { $0.end.id == sessionID } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .bottom) {
                Term.bg
                LiveTerminal(request: { cols, rows in
                    client.terminalRequest(machine: machineID, session: sessionID, cols: cols, rows: rows)
                }, state: $link)
                .padding(.leading, 12)
                .padding(.top, 8)
                .opacity(ended == nil ? 1 : 0.55)

                if let ended {
                    endedBanner(ended)
                } else if case .closed(let reason) = link {
                    notice(reason, icon: "wifi.slash", color: Theme.State.awaitingApproval)
                }
            }
            statusBar
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(12)
        .onAppear { lastSeen = current }
        .onChange(of: current) { _, now in if let now { lastSeen = now } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
                .contentShape(Rectangle())
                .onTapGesture(perform: onBack)
                .help("Back to machines")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agentTitle(live?.session.agent ?? "session"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let state = live?.activity?.state, ended == nil {
                        HStack(spacing: 4) {
                            Circle().fill(state.color).frame(width: 6, height: 6)
                            Text(state.title)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.color)
                    }
                }
                HStack(spacing: 5) {
                    Text(machine?.name ?? machineID)
                    Text("·")
                    Text(shortPath(live?.session.cwd ?? ""))
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let message = live?.activity?.message, live?.activity?.state == .waiting {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.State.awaitingApproval)
                    .lineLimit(1)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            toolbarButton(copied ? "checkmark" : "doc.on.doc", help: "Copy a command to attach from a terminal on \(machine?.name ?? "the machine")") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("tmux -S ~/.config/maple/tmux/maple.sock attach -t maple-\(sessionID)", forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }

            if ended == nil && machine?.owner == client.me?.login {
                Text(confirmKill ? "Kill it?" : "Kill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(confirmKill ? .white : Theme.State.cancelled)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(confirmKill ? Theme.State.cancelled : Theme.State.cancelled.opacity(0.1)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if confirmKill {
                            client.killSession(machine: machineID, id: sessionID)
                            confirmKill = false
                        } else {
                            confirmKill = true
                            Task { try? await Task.sleep(for: .seconds(3)); confirmKill = false }
                        }
                    }
                    .help("End this session")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(Theme.cardBG)
    }

    private func toolbarButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }

    private var statusBar: some View {
        let (text, color): (String, Color) = switch link {
        case .connecting: ("Attaching…", Theme.textMuted)
        case .live: ("Attached · relayed through \(client.server?.host() ?? "the factory")", Theme.State.merged)
        case .closed: ("Detached", Theme.State.awaitingApproval)
        }
        return HStack(spacing: 8) {
            Text(" maple ")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Term.bg)
                .background(Theme.accent)
            Text("maple-\(sessionID.prefix(8))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: 0x9096A0))
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x9096A0))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Term.chrome)
    }

    private func endedBanner(_ record: FactoryClient.EndRecord) -> some View {
        let cause = record.end.cause
        return HStack(spacing: 12) {
            Image(systemName: cause.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(cause.color)
                .frame(width: 30, height: 30)
                .background(Circle().fill(cause.color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Session ended · \(record.end.endTitle(me: client.me?.login))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(record.end.detail ?? (record.end.by != nil ? "Its tmux pane is gone; the last screen is kept with the session's history." : cause.explanation))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Text("Back to machines")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
                .contentShape(Rectangle())
                .onTapGesture(perform: onBack)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBG).shadow(color: .black.opacity(0.3), radius: 16, y: 6))
        .padding(16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(Theme.text)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Theme.cardBG).shadow(color: .black.opacity(0.25), radius: 10, y: 4))
        .padding(16)
    }
}

/// The commands for enrolling a machine, with a fresh one-time code.
struct AddMachineSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var enrollment: FactoryClient.Enrollment?
    @State private var error: String?
    @State private var copied: Int?
    /// "Add this Mac": what it's doing now, or that it's done.
    @State private var thisMac: String?
    @State private var addingThisMac = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a machine")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)

            thisMacRow
            if let error, enrollment != nil {
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.State.cancelled)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Or run this on the Mac or Linux machine you're adding: it installs the runner and joins the machine as yours. The code works once, for 15 minutes.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let enrollment {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(enrollment.commands.enumerated()), id: \.offset) { index, command in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Theme.fill))
                            Text(command)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color(hex: 0xD8DCE3))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: copied == index ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: 0x9096A0))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                    copied = index
                                }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Term.bg))
                    }
                }
                HStack(spacing: 6) {
                    Text("Code").foregroundStyle(Theme.textMuted)
                    Text(enrollment.code).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("It shows up under Machines as soon as it connects.").foregroundStyle(Theme.textFaint)
                }
                .font(.system(size: 12))
            } else if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.State.cancelled)
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Text("Done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            do { enrollment = try await client.enrollment() } catch { self.error = FactoryClient.describe(error) }
        }
    }

    /// This Mac: already in the factory, or one click to add it with the runner and tmux the app carries.
    @ViewBuilder private var thisMacRow: some View {
        let enrolled = client.server.map(LocalRunner.isEnrolled) ?? false
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(enrolled ? "This Mac is in the factory" : "This Mac")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(thisMac ?? (enrolled ? "As \(LocalRunner.enrolled?.runnerId ?? "this Mac"). Its runner starts at login." : LocalRunner.helpers == nil ? "Run the app built by bundle.sh to add it from here." : "Runs agents here, starting at login. No Homebrew needed."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !enrolled && LocalRunner.helpers != nil {
                Button {
                    addThisMac()
                } label: {
                    HStack(spacing: 6) {
                        if addingThisMac { ProgressView().controlSize(.mini) }
                        Text("Add this Mac")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(addingThisMac || enrollment == nil)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke)))
    }

    private func addThisMac() {
        guard let server = client.server, let code = enrollment?.code else { return }
        addingThisMac = true
        error = nil
        Task {
            do {
                try await LocalRunner.addThisMac(server: server, code: code) { thisMac = "\($0)…" }
                thisMac = "Added. It shows up under Machines in a moment."
            } catch {
                thisMac = nil
                self.error = FactoryClient.describe(error)
            }
            addingThisMac = false
            // The code is used now; another machine needs a fresh one.
            enrollment = try? await client.enrollment()
        }
    }
}
