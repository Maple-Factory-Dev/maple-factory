import Foundation

/// This Mac as a factory machine: the runner and tmux the app carries in Contents/Helpers, set up
/// the same way `install.sh` sets up any machine (enroll with a one-time code, then
/// `maple-runner install`, which copies the runner to ~/.local/share/maple/bin and starts it at
/// login). tmux goes next to it, where the runner looks first, so Homebrew isn't needed.
enum LocalRunner {
    struct Enrolled: Decodable {
        let url: String
        let runnerId: String
    }

    /// The helpers inside the app bundle; none when running from `swift run`.
    static var helpers: URL? {
        let dir = Bundle.main.bundleURL.appending(path: "Contents/Helpers")
        return FileManager.default.isExecutableFile(atPath: dir.appending(path: "maple-runner").path) ? dir : nil
    }

    /// Where the runner's service keeps its copy, and our tmux beside it.
    static var installDir: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/maple/bin") }

    /// What `maple-runner enroll` left in ~/.config/maple/runner.json, if this Mac is enrolled.
    static var enrolled: Enrolled? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/maple/runner.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Enrolled.self, from: data)
    }

    static func isEnrolled(with server: URL) -> Bool {
        guard let enrolled, let url = URL(string: enrolled.url) else { return false }
        return url.host() == server.host() && url.port == server.port
    }

    /// Enrolls this Mac with `code` and starts its runner. `step` hears what's happening.
    static func addThisMac(server: URL, code: String, step: @MainActor (String) -> Void) async throws {
        guard let helpers else { throw FactoryClient.ClientError.message("This copy of the app doesn't carry the runner; build it with apps/mac/scripts/bundle.sh.") }
        let runner = helpers.appending(path: "maple-runner").path
        await step("Joining the factory")
        try await run(runner, ["enroll", "--url", server.absoluteString, "--code", code])
        await step("Installing tmux")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let tmux = installDir.appending(path: "tmux")
        try? FileManager.default.removeItem(at: tmux)
        try FileManager.default.copyItem(at: helpers.appending(path: "tmux"), to: tmux)
        await step("Starting the runner")
        try await run(runner, ["install"])
    }

    /// Runs a helper to completion; its output becomes the error when it fails.
    private static func run(_ path: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { process in
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 { done.resume() }
                else { done.resume(throwing: FactoryClient.ClientError.message(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }
}
