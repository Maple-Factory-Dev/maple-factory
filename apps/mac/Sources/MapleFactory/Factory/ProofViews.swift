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
/// How big screenshot and video proofs are shown: as wide as the Done-when column, up to `maxWidth`, and
/// never wider than the media itself.
enum ProofViews {
    nonisolated static let maxWidth: CGFloat = 720

    /// min(column, maxWidth, the media's own width).
    nonisolated static func inlineWidth(column: CGFloat, media: CGSize?) -> CGFloat {
        min(column, maxWidth, media.map { $0.width > 0 ? $0.width : maxWidth } ?? maxWidth)
    }

    /// Width over height, 16:10 until there's a size.
    nonisolated static func aspect(_ size: CGSize?) -> CGFloat {
        guard let size, size.width > 0, size.height > 0 else { return 16 / 10 }
        return size.width / size.height
    }

    /// A track's natural size with its preferred transform applied: a phone's portrait recording is stored
    /// landscape and turned on playback.
    nonisolated static func upright(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let turned = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(turned.width).rounded(), height: abs(turned.height).rounded())
    }

    /// The poster's largest size: 2× the widest it's shown, kept to the recording's shape and own size.
    nonisolated static func posterSize(_ natural: CGSize?) -> CGSize {
        let most = maxWidth * 2
        guard let natural, natural.width > 0, natural.height > 0 else { return CGSize(width: most, height: most) }
        let scale = min(1, most / natural.width)
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }
}

/// The screenshot a runner uploaded (`/attachments/…`), fetched with the app's token; a click shows it in the lightbox.
private struct ScreenshotProof: View {
    let caption: String
    let path: String
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client: FactoryClient?
    /// Decoded at the size it's shown (CGImageSource's thumbnail), not the screenshot's own: a 3200px
    /// capture decoded whole is 25 MB, and those stayed alive. The lightbox decodes the whole one when it opens.
    @State private var image: NSImage?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Button(action: showLarge) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                        .frame(maxWidth: min(image.size.width, ProofViews.maxWidth), alignment: .leading)
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
            guard image != nil, state.lightbox == nil, note.object as? String != "video" else { return }
            showLarge()
        }
        .task(id: path) {
            do {
                guard let client else { throw FactoryClient.ClientError.message("Not signed in.") }
                guard let loaded = Self.thumbnail(try await client.attachment(path), width: ProofViews.maxWidth * 2) else {
                    throw FactoryClient.ClientError.message("Not an image.")
                }
                image = loaded
            } catch {
                failed = FactoryClient.describe(error)
            }
        }
    }

    /// The screenshot whole, in the lightbox.
    private func showLarge() {
        Task {
            guard let client, let data = try? await client.attachment(path), let full = NSImage(data: data) else { return }
            state.showLightbox(.image(full, caption: caption, attachment: path))
        }
    }

    /// The image in `data` decoded at most `width` pixels wide (never wider than its own), keeping the size
    /// in points the whole one has, so it lays out the same.
    nonisolated static func thumbnail(_ data: Data, width: CGFloat) -> NSImage? {
        guard let size = NSImage(data: data)?.size, size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        // The longest side, so a tall screenshot is as sharp as a wide one at that width.
        let longest = min(max(pixelWidth, pixelHeight), width * max(1, pixelHeight / pixelWidth))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded(.up)),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: size)
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
    /// The recording's own size, upright: what it lays out by (the poster's only a picture of it).
    @State private var natural: CGSize?
    @State private var duration: String?
    @State private var player: AVPlayer?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: inlineMax)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                    .overlay(alignment: .topTrailing) { expandButton }
            } else if let file {
                Button { play(file) } label: {
                    ZStack {
                        if let poster {
                            Image(nsImage: poster).resizable().aspectRatio(aspect, contentMode: .fit)
                        } else {
                            Color(hex: 0x1A1E27).aspectRatio(aspect, contentMode: .fit)
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
                    .frame(maxWidth: inlineMax)
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
        // Off screen, the player and what it buffered go; the poster's back with Play next time.
        .onDisappear {
            player?.pause()
            player = nil
        }
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
        state.showLightbox(.video(file, poster: poster, size: natural, caption: caption, at: at.isFinite ? at : 0))
    }

    private func play(_ file: URL) {
        let player = AVPlayer(url: file)
        self.player = player
        player.play()
    }

    private var aspect: CGFloat { ProofViews.aspect(natural ?? poster?.size) }

    /// As wide as the column lets it, up to ProofViews.maxWidth, and never past the recording's own width.
    private var inlineMax: CGFloat { ProofViews.inlineWidth(column: .infinity, media: natural) }

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
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                natural = ProofViews.upright(size, transform: transform)
            }
            let frames = AVAssetImageGenerator(asset: asset)
            frames.appliesPreferredTrackTransform = true
            // Sharp at the most it's shown (2× for Retina), never more than the recording has.
            frames.maximumSize = ProofViews.posterSize(natural)
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
        .frame(maxWidth: ProofViews.maxWidth, minHeight: 60, alignment: .leading)
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
            .frame(maxWidth: ProofViews.maxWidth)
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

/// The screenshot in the lightbox at `zoom` past fitted, panned by `pan`, in a frame that grows with it up to the
/// room and clips it. Pinch zooms about the pinch, double-click toggles fitted and 2× at the click, dragging pans
/// while zoomed; with the scroll monitor, ⌘-scroll zooms about the cursor and a plain scroll pans.
private struct ZoomableProofImage: View {
    let image: NSImage
    let fitted: CGSize
    let room: CGSize
    let zoom: CGFloat
    let pan: CGSize
    let zoomTo: (CGFloat, CGPoint) -> Void
    let panTo: (CGSize) -> Void
    /// Where a pinch started (from the frame's centre) and the zoom it started at.
    @State private var pinch: (anchor: CGPoint, zoom: CGFloat)?
    /// The pan a drag started from.
    @State private var dragFrom: CGSize?
    /// The frame in window coordinates, for the scroll monitor to find the cursor.
    @State private var frameInWindow: CGRect = .zero
    @State private var monitor: Any?
    /// What the monitor calls: this view's latest `scrolled`, so it reads the zoom and pan on screen, not the ones
    /// it was installed with.
    @State private var relay = ScrollRelay()

    var body: some View {
        let content = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let frame = CGSize(width: min(room.width, content.width), height: min(room.height, content.height))
        let _ = relay.handle = scrolled
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: content.width, height: content.height)
            .offset(pan)
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameInWindow = $0 }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let from = dragFrom ?? pan
                    dragFrom = from
                    panTo(CGSize(width: from.width + value.translation.width, height: from.height + value.translation.height))
                }
                .onEnded { _ in dragFrom = nil }, isEnabled: zoom > 1)
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = pinch ?? (CGPoint(x: value.startLocation.x - frame.width / 2, y: value.startLocation.y - frame.height / 2), zoom)
                    pinch = start
                    zoomTo(start.zoom * value.magnification, start.anchor)
                }
                .onEnded { _ in pinch = nil })
            .onTapGesture(count: 2) { location in
                withAnimation(.snappy(duration: 0.25)) {
                    zoomTo(zoom > 1 ? 1 : 2, CGPoint(x: location.x - frame.width / 2, y: location.y - frame.height / 2))
                }
            }
            .pointerStyle(zoom > 1 ? (dragFrom == nil ? .grabIdle : .grabActive) : nil)
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [relay] in relay.handle?($0) ?? $0 }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                // The handler holds this view, image and all, and the view holds the relay: a cycle that
                // kept every screenshot shown large alive.
                relay.handle = nil
            }
    }

    /// ⌘-scroll zooms about the cursor (or the centre, off the image); a plain scroll pans a zoomed image.
    private func scrolled(_ event: NSEvent) -> NSEvent? {
        // A headless `scroll:` comes from off screen, with no window: it's for the main window, at the point it says.
        let headless = Headless.isOn && event.window == nil ? Headless.scrollPoint : nil
        guard let window = headless != nil ? Snapshotter.shared?.mainWindow : event.window, let view = window.contentView,
              window == NSApp.mainWindow || Headless.isOn else { return event }
        var point = view.convert(headless ?? event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) {
            let anchor = frameInWindow.contains(point) ? CGPoint(x: point.x - frameInWindow.midX, y: point.y - frameInWindow.midY) : .zero
            if Headless.isOn { print("headless: ⌘-scroll zooms from \(zoom) about \(anchor)") }
            zoomTo(zoom * exp(event.scrollingDeltaY * (precise ? 0.01 : 0.1)), anchor)
            return nil
        }
        guard zoom > 1 else { return event }
        if Headless.isOn { print("headless: scroll pans from \(pan) at zoom \(zoom)") }
        let step: CGFloat = precise ? 1 : 10
        panTo(CGSize(width: pan.width + event.scrollingDeltaX * step, height: pan.height + event.scrollingDeltaY * step))
        return nil
    }
}

/// Holds the scroll monitor's handler, so a monitor installed once calls the view as it is now.
private final class ScrollRelay {
    var handle: ((NSEvent) -> NSEvent?)?
}

/// A proof shown as large as the window allows, over a dimmed window. Esc, the close button or a click
/// on the backdrop puts it away; Open in Preview (or QuickTime) still hands the file to the Mac.
/// A screenshot opens fitted and zooms (pinch, ⌘-scroll, double-click, − / + and ⌘= / ⌘− / ⌘0) and pans once zoomed.
struct ProofLightboxView: View {
    /// A demo script's `lightbox:open` (or `:image`, `:video`): the first such proof on screen opens itself here.
    static let demoOpen = Notification.Name("ProofLightboxView.demoOpen")
    /// A demo script's `lightbox:zoom:<factor>` or `lightbox:pan:<dx>:<dy>`, for the screenshot shown large.
    static let demoZoom = Notification.Name("ProofLightboxView.demoZoom")
    static let padding: CGFloat = 48
    /// Room under the media for its caption and buttons.
    static let barHeight: CGFloat = 40

    let lightbox: ProofLightbox
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @State private var player: AVPlayer?
    /// How far past fitted the screenshot is zoomed (1 is fitted), and how far it's panned from centred.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

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
                    bar(room: room)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // A window resized keeps the zoom in its new cap and the pan in its new room.
            .onChange(of: room) { setZoom(zoom, at: .zero, room: room) }
            .onReceive(NotificationCenter.default.publisher(for: Self.demoZoom)) { note in
                guard let parts = note.object as? [String], let command = parts.first else { return }
                let numbers = parts.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
                withAnimation(.snappy(duration: 0.35)) {
                    if command == "zoom", let factor = numbers.first { setZoom(factor, at: .zero, room: room) }
                    if command == "pan", numbers.count == 2 { setPan(CGSize(width: pan.width + numbers[0], height: pan.height + numbers[1]), room: room) }
                }
            }
        }
        .onAppear(perform: startVideo)
        .onDisappear {
            player?.pause()
            player = nil
        }
        // Another proof shown in the same lightbox opens fitted, like the first.
        .onChange(of: lightbox) {
            zoom = 1
            pan = .zero
            player?.pause()
            player = nil
            startVideo()
        }
    }

    @ViewBuilder private func media(in room: CGSize) -> some View {
        switch lightbox {
        case let .image(image, _, _):
            ZoomableProofImage(image: image, fitted: Self.fit(image.size, in: room), room: room, zoom: zoom, pan: pan,
                               zoomTo: { setZoom($0, at: $1, room: room) }, panTo: { setPan($0, room: room) })
        case let .video(_, poster, natural, _, _):
            // Recordings are often small: they grow to fill the room, unlike screenshots, but only to 2× their
            // own size, so a small capture isn't blown up to a blur.
            let size = Self.fit(natural ?? poster?.size ?? CGSize(width: 16, height: 10), in: room, upscale: Self.maxVideoUpscale)
            Group {
                if let player { VideoPlayer(player: player) } else { Color.black }
            }
            .frame(width: size.width, height: size.height)
        case .page:
            // Shown by PageViewerView instead.
            EmptyView()
        }
    }

    private func bar(room: CGSize) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isVideo ? "video" : "photo")
            Text(lightbox.caption).lineLimit(1)
            Spacer(minLength: 16)
            if !isVideo { zoomControls(room: room) }
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
        // Clicks in the bar's gaps stay in the bar instead of reaching the backdrop.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func zoomControls(room: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { withAnimation(.snappy(duration: 0.2)) { setZoom(Self.zoomStep(from: zoom, up: false, cap: zoomCap(room)), at: .zero, room: room) } } label: {
                Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1)
            .help("Zoom Out (⌘−)")
            Button { withAnimation(.snappy(duration: 0.2)) { setZoom(1, at: .zero, room: room) } } label: {
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 42)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit (⌘0)")
            Button { withAnimation(.snappy(duration: 0.2)) { setZoom(Self.zoomStep(from: zoom, up: true, cap: zoomCap(room)), at: .zero, room: room) } } label: {
                Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= zoomCap(room))
            .help("Zoom In (⌘=)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .background(Capsule().fill(.white.opacity(0.1)))
    }

    /// The screenshot's size fitted into the room, and its own pixels.
    private func imageSizes(_ room: CGSize) -> (fitted: CGSize, pixels: CGSize)? {
        guard case let .image(image, _, _) = lightbox else { return nil }
        let pixels = image.representations.reduce(image.size) { size, rep in
            CGSize(width: max(size.width, CGFloat(rep.pixelsWide)), height: max(size.height, CGFloat(rep.pixelsHigh)))
        }
        return (Self.fit(image.size, in: room), pixels)
    }

    private func zoomCap(_ room: CGSize) -> CGFloat {
        guard let sizes = imageSizes(room) else { return 1 }
        return Self.clampZoom(.infinity, fitted: sizes.fitted, pixels: sizes.pixels)
    }

    /// Zooms to `target` (clamped) about `anchor`, a point from the image frame's centre, keeping the pan in bounds.
    private func setZoom(_ target: CGFloat, at anchor: CGPoint, room: CGSize) {
        guard let sizes = imageSizes(room) else { return }
        let next = Self.clampZoom(target, fitted: sizes.fitted, pixels: sizes.pixels)
        let content = CGSize(width: sizes.fitted.width * next, height: sizes.fitted.height * next)
        pan = Self.clampPan(Self.zoomAnchored(pan, from: zoom, to: next, at: anchor), content: content, room: room)
        zoom = next
    }

    private func setPan(_ target: CGSize, room: CGSize) {
        guard let sizes = imageSizes(room) else { return }
        pan = Self.clampPan(target, content: CGSize(width: sizes.fitted.width * zoom, height: sizes.fitted.height * zoom), room: room)
    }

    private var isVideo: Bool { if case .video = lightbox { true } else { false } }
    private var canOpen: Bool { if case .image(_, _, nil) = lightbox { false } else { true } }

    private func startVideo() {
        guard case let .video(file, _, _, _, at) = lightbox else { return }
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
        case let .video(file, _, _, _, _):
            player?.pause()
            FactoryClient.quarantine(file)
            NSWorkspace.shared.open(file)
        case .page:
            break
        }
    }

    /// Media fitted into the room it has, keeping its shape, grown at most `upscale` times its own size:
    /// screenshots never grow past it (1), recordings up to `maxVideoUpscale`.
    nonisolated static func fit(_ media: CGSize, in room: CGSize, upscale: CGFloat = 1) -> CGSize {
        guard media.width > 0, media.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(room.width / media.width, room.height / media.height, max(upscale, 1))
        return CGSize(width: (media.width * scale).rounded(), height: (media.height * scale).rounded())
    }

    /// The most a recording grows past its own size in the lightbox.
    nonisolated static let maxVideoUpscale: CGFloat = 2

    /// The most a screenshot zooms past fitted, unless its own pixels are bigger still.
    nonisolated static let maxZoom: CGFloat = 8
    /// The stops − and + (and ⌘− / ⌘=) step through.
    nonisolated static let zoomStops: [CGFloat] = [1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8]

    /// A zoom kept between fitted (1×) and the cap: 8×, or the screenshot's own pixels if that's more.
    nonisolated static func clampZoom(_ zoom: CGFloat, fitted: CGSize, pixels: CGSize) -> CGFloat {
        let own = fitted.width > 0 ? pixels.width / fitted.width : 1
        return min(max(zoom, 1), max(maxZoom, own))
    }

    /// A pan kept so a zoomed image's edges never come inside the room it's shown in; on an axis where
    /// it's no bigger than the room, it stays centred.
    nonisolated static func clampPan(_ offset: CGSize, content: CGSize, room: CGSize) -> CGSize {
        let slack = CGSize(width: max(0, (content.width - room.width) / 2), height: max(0, (content.height - room.height) / 2))
        return CGSize(width: min(max(offset.width, -slack.width), slack.width),
                      height: min(max(offset.height, -slack.height), slack.height))
    }

    /// The pan after zooming from `old` to `new` about `anchor` (from the frame's centre), so the point
    /// of the image under the cursor or the pinch stays under it.
    nonisolated static func zoomAnchored(_ offset: CGSize, from old: CGFloat, to new: CGFloat, at anchor: CGPoint) -> CGSize {
        guard old > 0 else { return offset }
        let ratio = new / old
        return CGSize(width: anchor.x - (anchor.x - offset.width) * ratio, height: anchor.y - (anchor.y - offset.height) * ratio)
    }

    /// The next stop up or down from `zoom`, within the cap.
    nonisolated static func zoomStep(from zoom: CGFloat, up: Bool, cap: CGFloat) -> CGFloat {
        let stops = zoomStops.filter { $0 < cap } + [cap]
        let next = up ? stops.first { $0 > zoom + 0.001 } : stops.last { $0 < zoom - 0.001 }
        return next ?? (up ? cap : 1)
    }
}
