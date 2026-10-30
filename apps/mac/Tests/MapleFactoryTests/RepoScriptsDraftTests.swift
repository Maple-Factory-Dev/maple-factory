import Testing
@testable import MapleFactory

/// Settings › Worktree scripts' form: preflight and its watched files load, save and count toward the 4 KB check.
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
}
