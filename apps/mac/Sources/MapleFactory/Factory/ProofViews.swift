import SwiftUI

extension AppState {
    /// A person signs a Done when item off themselves, with an optional reason.
    func attest(_ taskID: String, item index: Int, reason: String) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let client, isLive {
            client.send(.taskCheckedIt(.init(id: taskID, item: UInt32(index), note: trimmed.isEmpty ? nil : trimmed)))
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            update(taskID) { task in
                guard task.doneWhen.indices.contains(index) else { return }
                task.doneWhen[index].status = .proven
                task.doneWhen[index].evidence = .attested(by: FactoryData.me.github ?? FactoryData.me.name, reason: trimmed.isEmpty ? nil : trimmed, when: "now")
            }
        }
    }
}

/// The acceptance checks a plan commits to, and — once building — the evidence the agent attached for each.
struct DoneWhenSection: View {
    let task: FactoryTask

    private var collecting: Bool { task.state == .building || task.state == .reviewing || task.state == .merged }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(title: "Done when")
                if collecting {
                    Text("\(task.proven) of \(task.doneWhen.count) proven")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if collecting { ProofMeter(criteria: task.doneWhen) }
            }

            if !collecting {
                Text("\(task.authorName ?? "The builder") has to attach proof for each check before this can merge.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(task.doneWhen.enumerated()), id: \.element.id) { index, criterion in
                    CriterionRow(task: task, index: index, criterion: criterion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if index < task.doneWhen.count - 1 { Hairline().padding(.leading, 36) }
                }
                if !collecting {
                    Hairline()
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        Text("Add a check")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            )
        }
    }
}

struct ProofMeter: View {
    let criteria: [DoneCriterion]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(criteria) { criterion in
                Capsule()
                    .fill(color(for: criterion.status))
                    .frame(width: 14, height: 4)
            }
        }
    }

    private func color(for status: DoneCriterion.Status) -> Color {
        switch status {
        case .proven: Theme.State.merged
        case .failed: Theme.State.cancelled
        case .proving: Theme.State.building.opacity(0.6)
        case .pending: Theme.fillSelected
        }
    }
}

private struct CriterionRow: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let index: Int
    let criterion: DoneCriterion
    @State private var attesting = false
    @State private var reason = ""

    private var attested: Bool { if case .attested = criterion.evidence { true } else { false } }
    private var canAttest: Bool { criterion.status != .proven && (task.state == .building || task.state == .reviewing) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(criterion.text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: criterion.proof.icon).font(.system(size: 9.5))
                        Text(criterion.proof.title)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Theme.fill))

                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)

                    if canAttest {
                        Spacer(minLength: 0)
                        Button("Attest") { attesting = true }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .help("Sign this off yourself instead of waiting for the agent's proof")
                            .popover(isPresented: $attesting, arrowEdge: .bottom) { attestForm }
                    }
                }

                if let evidence = criterion.evidence {
                    EvidenceView(evidence: evidence)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusIcon: some View {
        switch criterion.status {
        case .pending:
            Circle().strokeBorder(Theme.textFaint, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
        case .proving:
            ProgressView().controlSize(.mini)
        case .proven:
            Image(systemName: attested ? "person.badge.shield.checkmark.fill" : "checkmark.seal.fill").foregroundStyle(Theme.State.merged)
        case .failed:
            Image(systemName: "xmark.seal.fill").foregroundStyle(Theme.State.cancelled)
        }
    }

    private var statusText: String {
        switch criterion.status {
        case .pending: "Needs proof"
        case .proving: "Collecting proof…"
        case .proven: attested ? "Attested" : "Proven"
        case .failed: "Proof failed"
        }
    }

    private var attestForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attest to this yourself")
                .font(.system(size: 12.5, weight: .semibold))
            Text("It counts as proven, signed off by you instead of the agent.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Reason (optional)", text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel") { attesting = false; reason = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Attest", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func confirm() {
        state.attest(task.id, item: index, reason: reason)
        attesting = false
        reason = ""
    }

    private var statusColor: Color {
        switch criterion.status {
        case .pending: Theme.textFaint
        case .proving: Theme.State.building
        case .proven: Theme.State.merged
        case .failed: Theme.State.cancelled
        }
    }
}

struct EvidenceView: View {
    let evidence: DoneCriterion.Evidence

    var body: some View {
        switch evidence {
        case let .terminal(command, output): TerminalProof(command: command, output: output)
        case let .tests(suite, passed, failed): TestsProof(suite: suite, passed: passed, failed: failed)
        case let .screenshot(caption): MediaProof(caption: caption, duration: nil)
        case let .video(caption, duration): MediaProof(caption: caption, duration: duration)
        case let .attested(by, reason, when): AttestedProof(by: by, reason: reason, when: when)
        }
    }
}

/// A person's sign-off, kept apart from anything the agent proved.
private struct AttestedProof: View {
    let by: String
    let reason: String?
    let when: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.checkmark")
                    .foregroundStyle(Theme.State.merged)
                Text("Attested by @\(by)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("·").foregroundStyle(Theme.textFaint)
                Text(when == "now" ? "just now" : "\(when) ago")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 11.5))
            if let reason {
                Text("“\(reason)”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fillSubtle))
    }
}

/// Terminal output always renders dark, like a real terminal, regardless of app appearance.
private struct TerminalProof: View {
    let command: String
    let output: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("$").foregroundStyle(Color(hex: 0x3DD68C))
                Text(command).foregroundStyle(Color(hex: 0xE4E6EA))
            }
            ForEach(Array(output.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).foregroundStyle(Color(hex: 0x9096A0))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x0F1114)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.06)))
    }
}

private struct TestsProof: View {
    let suite: String
    let passed: Int
    let failed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let total = CGFloat(max(passed + failed, 1))
                HStack(spacing: 2) {
                    Capsule().fill(Theme.State.merged)
                        .frame(width: proxy.size.width * CGFloat(passed) / total)
                    if failed > 0 {
                        Capsule().fill(Theme.State.cancelled)
                    }
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                Text("\(passed) passed").foregroundStyle(Theme.State.merged)
                Text("·").foregroundStyle(Theme.textFaint)
                Text("\(failed) failed").foregroundStyle(failed > 0 ? Theme.State.cancelled : Theme.textMuted)
                Spacer()
                Text(suite)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fillSubtle))
    }
}

/// A stand-in thumbnail for screenshot and video proofs: a tiny browser window with a login form.
private struct MediaProof: View {
    let caption: String
    let duration: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x2A3140), Color(hex: 0x1A1E27)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                fakeWindow
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .opacity(duration == nil ? 1 : 0.55)

                if let duration {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 6)
                    Text(duration)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
            }
            .frame(height: 118)
            .frame(maxWidth: 380)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))

            HStack(spacing: 5) {
                Image(systemName: duration == nil ? "photo" : "video")
                Text(caption).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
        }
    }

    private var fakeWindow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { color in
                    Circle().fill(Color(hex: UInt32(color))).frame(width: 4, height: 4)
                }
                Spacer()
            }
            .padding(.horizontal, 5)
            .frame(height: 10)
            .background(Color(hex: 0xE9EBEF))

            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0x1D2025)).frame(width: 40, height: 4)
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color(hex: 0xD5D8DD)).frame(width: 90, height: 9)
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color(hex: 0xD5D8DD)).frame(width: 90, height: 9)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x14A866)).frame(width: 90, height: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
    }
}
