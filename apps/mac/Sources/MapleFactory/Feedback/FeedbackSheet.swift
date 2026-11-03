import AppKit
import SwiftUI

/// Help › Send Feedback…: a beta tester's bug, idea or note, to Maple Factory's Sentry project as User Feedback.
/// When this build can't send (debug, MAPLE_TELEMETRY=off, reports off), it says so and offers an email instead.
struct FeedbackSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var draft = FeedbackDraft()
    @State private var phase = Phase.writing
    @FocusState private var messageFocused: Bool

    enum Phase { case writing, sending, sent }

    /// Settable for the headless demo, so a debug build can show the "can send" layout too.
    var canSend = ErrorReports.canSendFeedback

    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { info["CFBundleVersion"] as? String ?? "0" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if phase == .sent { sent } else { form }
        }
        .frame(width: 480)
        .background(Theme.cardBG)
        .onAppear { messageFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Send Feedback").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Goes straight to the people building Maple Factory.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Picker("Kind", selection: $draft.kind) {
                ForEach(FeedbackDraft.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .padding(6)
                if draft.message.isEmpty {
                    Text(draft.kind.placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.editorBG))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))

            VStack(alignment: .leading, spacing: 4) {
                TextField("Email (optional, if you'd like a reply)", text: $draft.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                if !draft.emailLooksValid {
                    Text("That doesn't look like an email address.").font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            if canSend {
                Toggle("Attach a screenshot of this window", isOn: $draft.attachScreenshot)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
            }

            Text(footer).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !canSend {
                Label(cantSendReason, systemImage: ErrorReports.forcedOff || !ErrorReports.enabled ? "lock" : "hammer")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(canSend ? "Send" : "Email Instead") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSend || phase == .sending)
            }
        }
        .padding(20)
    }

    private var sent: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
            Text("Thanks, sent").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// What goes with the message, named so nothing's a surprise.
    private var footer: String {
        var parts = ["version \(Self.version) (\(Self.build))"]
        if let screen = ErrorReports.currentScreen { parts.append("the screen you're on (\(screen))") }
        if let org = state.client?.org, !org.isEmpty { parts.append("your factory's org (\(org))") }
        let with = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return canSend ? "Sent with \(with)." : "The email includes \(with)."
    }

    private var cantSendReason: String {
        if ErrorReports.forcedOff { return "Can't send from here: MAPLE_TELEMETRY=off is set. Email it instead." }
        #if DEBUG
        return "Can't send from this build: debug builds never send to Sentry. Email it instead."
        #else
        if !ErrorReports.enabled { return "Can't send while crash and error reports are off (Settings › General). Email it instead." }
        return "Can't send from this build. Email it instead."
        #endif
    }

    private func submit() {
        guard draft.canSend else { return }
        guard canSend else {
            openURL(draft.mailtoURL(version: Self.version, build: Self.build, screen: ErrorReports.currentScreen))
            dismiss()
            return
        }
        // Only now, on Send: the window under this sheet.
        let shot = draft.attachScreenshot ? Self.screenshotOfMainWindow() : nil
        let draft = draft
        phase = .sending
        Task.detached {
            ErrorReports.sendFeedback(draft, screenshot: shot)
            await MainActor.run {
                withAnimation(.snappy) { phase = .sent }
            }
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { dismiss() }
        }
    }

    /// The main window (the one this sheet hangs off), drawn into a PNG. Its own views only: no other app's.
    @MainActor static func screenshotOfMainWindow() -> Data? {
        let window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }
        guard let view = window?.contentView?.superview ?? window?.contentView else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
