import Testing
@testable import MapleFactory

/// Settings › Worktree scripts' form: preflight and its watched files, and the checks, load, save and count toward the limits.
struct RepoScriptsDraftTests {
    @Test func preflightAndWatchRoundTrip() {
        let stored = Wire.WorktreeScripts(preflight: "mise install", preflightWatch: ".ruby-version\nBrewfile", setup: "bin/setup")
        var draft = RepoScriptsDetail.Draft(stored)
        #expect(draft.preflight == "mise install")
        #expect(draft.watch == ".ruby-version\nBrewfile")
        #expect(draft.wire == stored)
        draft.watch = "  .nvmrc \n\n mise.toml\n"
        draft.preflight = "  brew bundle\n"
        #expect(draft.wire.preflight == "brew bundle")
        #expect(draft.wire.preflightWatch == ".nvmrc\nmise.toml")
        draft.watch = " \n "
        #expect(draft.wire.preflightWatch == nil)
        draft.preflight = String(repeating: "x", count: 4097)
        #expect(draft.tooLong == "The preflight script is over 4 KB.")
    }

    @Test func checksRoundTrip() {
        let stored = Wire.WorktreeScripts(setup: "bin/setup", checks: "npm run lint\nlefthook run pre-commit --all-files")
        var draft = RepoScriptsDetail.Draft(stored)
        #expect(draft.checks == "npm run lint\nlefthook run pre-commit --all-files")
        #expect(draft.wire == stored)
        #expect(draft == RepoScriptsDetail.Draft(stored), "unchanged: nothing to save")
        draft.checks = "  bundle exec rubocop \n\n npm run lint\n"
        #expect(draft != RepoScriptsDetail.Draft(stored), "edited: Save lights up")
        #expect(draft.wire.checks == "bundle exec rubocop\nnpm run lint")
        #expect(draft.wire.setup == "bin/setup")
        draft.checks = " \n "
        #expect(draft.wire.checks == nil)
        draft.checks = (1...21).map { "check \($0)" }.joined(separator: "\n")
        #expect(draft.tooLong == "At most 20 checks.")
    }
}
