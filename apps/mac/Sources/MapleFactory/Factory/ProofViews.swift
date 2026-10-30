import AVKit
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
    private var key: String { "\(task.id)#\(index)" }
    private var attesting: Binding<Bool> {
        Binding(get: { state.attestingItem == key }, set: { open in
            if open { state.attestReason = ""; state.attestingItem = key } else if state.attestingItem == key { state.attestingItem = nil }
        })
    }

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
                        Button("Attest") { attesting.wrappedValue = true }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .help("Sign this off yourself instead of waiting for the agent's proof")
                            .popover(isPresented: attesting, arrowEdge: .leading) { attestForm }
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
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 10) {
            Text("Attest to this yourself")
                .font(.system(size: 12.5, weight: .semibold))
            Text("It counts as proven, signed off by you instead of the agent.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Reason (optional)", text: $state.attestReason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel") { attesting.wrappedValue = false }
                    .keyboardShortcut(.cancelAction)
                Button("Attest", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func confirm() {
        state.attest(task.id, item: index, reason: state.attestReason)
        state.attestingItem = nil
        state.attestReason = ""
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
        case let .screenshot(caption, file?): ScreenshotProof(caption: caption, path: file)
        case let .video(caption, _, file?): VideoProof(caption: caption, path: file)
        case let .screenshot(caption, nil): MediaProof(caption: caption, duration: nil)
        case let .video(caption, duration, nil): MediaProof(caption: caption, duration: duration)
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
/// The screenshot a runner uploaded (`/attachments/…`), fetched with the app's token; a click shows it in the lightbox.
private struct ScreenshotProof: View {
    let caption: String
    let path: String
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @State private var image: NSImage?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Button {
                    state.showLightbox(.image(image, caption: caption, attachment: path))
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                        .frame(maxWidth: min(image.size.width, 380), alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("View larger")
            } else {
                ProofLoading(failed: failed)
            }
            ProofCaption(icon: "photo", caption: caption)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProofLightboxView.demoOpen)) { note in
            // Only the first proof on screen answers, so one lightbox opens.
            guard let image, state.lightbox == nil, note.object as? String != "video" else { return }
            state.showLightbox(.image(image, caption: caption, attachment: path))
        }
        .task(id: path) {
            do {
                guard let client else { throw FactoryClient.ClientError.message("Not signed in.") }
                guard let loaded = NSImage(data: try await client.attachment(path)) else { throw FactoryClient.ClientError.message("Not an image.") }
                image = loaded
            } catch {
                failed = FactoryClient.describe(error)
            }
        }
    }
}

/// The screen recording a runner uploaded: its first frame and length, and it plays in place on a click.
struct VideoProof: View {
    /// A demo script's `play:video`: the video proofs on screen start playing.
    static let demoPlay = Notification.Name("VideoProof.demoPlay")

    let caption: String
    let path: String
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @State private var file: URL?
    @State private var poster: NSImage?
    @State private var duration: String?
    @State private var player: AVPlayer?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                    .overlay(alignment: .topTrailing) { expandButton }
            } else if let file {
                Button { play(file) } label: {
                    ZStack {
                        if let poster {
                            Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Color(hex: 0x1A1E27).aspectRatio(16 / 10, contentMode: .fit)
                        }
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 6)
                        if let duration {
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
                    .frame(maxWidth: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play")
                .overlay(alignment: .topTrailing) { expandButton }
            } else {
                ProofLoading(failed: failed)
            }
            ProofCaption(icon: "video", caption: caption)
        }
        .task(id: path) { await load() }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPlay)) { _ in
            if let file, player == nil { play(file) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProofLightboxView.demoOpen)) { note in
            if file != nil, state.lightbox == nil, note.object as? String != "image" { expand() }
        }
    }

    /// Opens the recording in the lightbox, from where the inline player was; the inline one stays paused.
    @ViewBuilder private var expandButton: some View {
        if file != nil {
            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("View larger")
        }
    }

    private func expand() {
        guard let file else { return }
        player?.pause()
        let at = player.map { $0.currentTime().seconds } ?? 0
        state.showLightbox(.video(file, poster: poster, caption: caption, at: at.isFinite ? at : 0))
    }

    private func play(_ file: URL) {
        let player = AVPlayer(url: file)
        self.player = player
        player.play()
    }

    private var aspect: CGFloat {
        guard let poster, poster.size.height > 0 else { return 16 / 10 }
        return poster.size.width / poster.size.height
    }

    /// AVFoundation plays files, not bytes: the upload goes to a temporary file first.
    private func load() async {
        do {
            guard let client else { throw FactoryClient.ClientError.message("Not signed in.") }
            guard let link = FactoryClient.attachmentLink(path) else { throw FactoryClient.ClientError.message("Not an attachment.") }
            let data = try await client.attachment(path)
            let folder = FileManager.default.temporaryDirectory.appending(path: "maple-proofs/\(link.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: link.name)
            try data.write(to: url)
            let asset = AVURLAsset(url: url)
            let length = try? await asset.load(.duration)
            if let length, length.isNumeric { duration = Self.clock(length.seconds) }
            let frames = AVAssetImageGenerator(asset: asset)
            frames.appliesPreferredTrackTransform = true
            frames.maximumSize = CGSize(width: 760, height: 760)
            if let frame = try? await frames.image(at: .zero).image {
                poster = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
            file = url
        } catch {
            failed = FactoryClient.describe(error)
        }
    }

    /// `0:42`, `12:05`.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// While a proof file loads, or why it couldn't.
private struct ProofLoading: View {
    let failed: String?

    var body: some View {
        HStack(spacing: 6) {
            if failed != nil { Image(systemName: "exclamationmark.triangle") } else { ProgressView().controlSize(.small) }
            Text(failed.map { "Couldn't load the proof: \($0)" } ?? "Loading the proof…")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: 380, minHeight: 60, alignment: .leading)
    }
}

private struct ProofCaption: View {
    let icon: String
    let caption: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(caption).lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
    }
}

/// Demo data's stand-in for a screenshot or video: a drawn window, since there's no file.
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

/// A proof shown as large as the window allows, over a dimmed window. Esc, the close button or a click
/// on the backdrop puts it away; Open in Preview (or QuickTime) still hands the file to the Mac.
struct ProofLightboxView: View {
    /// A demo script's `lightbox:open` (or `:image`, `:video`): the first such proof on screen opens itself here.
    static let demoOpen = Notification.Name("ProofLightboxView.demoOpen")
    static let padding: CGFloat = 48
    /// Room under the media for its caption and buttons.
    static let barHeight: CGFloat = 40

    let lightbox: ProofLightbox
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geo in
            let room = CGSize(width: geo.size.width - Self.padding * 2,
                              height: geo.size.height - Self.padding * 2 - Self.barHeight)
            ZStack {
                Color.black.opacity(0.75)
                    .contentShape(Rectangle())
                    .onTapGesture { state.closeLightbox() }

                VStack(spacing: 12) {
                    media(in: room)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                    bar
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear(perform: startVideo)
        .onDisappear { player?.pause() }
    }

    @ViewBuilder private func media(in room: CGSize) -> some View {
        switch lightbox {
        case let .image(image, _, _):
            let size = Self.fit(image.size, in: room)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture {}
        case let .video(_, poster, _, _):
            // Recordings are often small: they grow to fill the room, unlike screenshots.
            let size = Self.fit(poster?.size ?? CGSize(width: 16, height: 10), in: room, upscale: true)
            Group {
                if let player { VideoPlayer(player: player) } else { Color.black }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: isVideo ? "video" : "photo")
            Text(lightbox.caption).lineLimit(1)
            Spacer(minLength: 16)
            if canOpen {
                Button(isVideo ? "Open in QuickTime" : "Open in Preview", action: openExternally)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white)
            }
            Button { state.closeLightbox() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.85))
        .frame(height: Self.barHeight - 12)
        .padding(.horizontal, Self.padding)
    }

    private var isVideo: Bool { if case .video = lightbox { true } else { false } }
    private var canOpen: Bool { if case .image(_, _, nil) = lightbox { false } else { true } }

    private func startVideo() {
        guard case let .video(file, _, _, at) = lightbox else { return }
        let player = AVPlayer(url: file)
        if at > 0 { player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        self.player = player
        player.play()
    }

    private func openExternally() {
        switch lightbox {
        case let .image(_, _, attachment?):
            Task { await client?.open(attachment: attachment) }
        case .image:
            break
        case let .video(file, _, _, _):
            player?.pause()
            FactoryClient.quarantine(file)
            NSWorkspace.shared.open(file)
        }
    }

    /// Media fitted into the room it has, keeping its shape; screenshots never grow past their own size.
    nonisolated static func fit(_ media: CGSize, in room: CGSize, upscale: Bool = false) -> CGSize {
        guard media.width > 0, media.height > 0, room.width > 0, room.height > 0 else { return .zero }
        var scale = min(room.width / media.width, room.height / media.height)
        if !upscale { scale = min(scale, 1) }
        return CGSize(width: (media.width * scale).rounded(), height: (media.height * scale).rounded())
    }
}
