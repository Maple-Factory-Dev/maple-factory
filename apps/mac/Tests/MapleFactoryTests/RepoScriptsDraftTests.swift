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

    @Test func checkPrefixesAndPathRulesMatchTheServer() {
        var draft = RepoScriptsDetail.Draft(Wire.WorktreeScripts(checks: "npm test\n[macos] xcodebuild test", requirePaths: "apps/mac/** macos"))
        #expect(draft.tooLong == nil)
        #expect(draft.wire.requirePaths == "apps/mac/** macos")
        draft.requirePaths = " apps/mac/** macos \n\n apps/ios/** macos,xcode\n"
        #expect(draft.wire.requirePaths == "apps/mac/** macos\napps/ios/** macos,xcode")
        draft.checks = "[macos xcodebuild test"
        #expect(draft.tooLong?.contains("never closes it") == true)
        draft.checks = "[] npm test"
        #expect(draft.tooLong?.contains("empty [ ]") == true)
        draft.checks = "[MacOS] xcodebuild"
        #expect(draft.tooLong?.contains("the tag \"MacOS\"") == true)
        draft.checks = "[macos]"
        #expect(draft.tooLong?.contains("no command") == true)
        draft.checks = "[xcode, macos] xcodebuild test"
        #expect(draft.tooLong == nil)
        draft.requirePaths = "apps/mac/**"
        #expect(draft.tooLong?.contains("a path and its tags") == true)
        draft.requirePaths = "../x/** macos"
        #expect(draft.tooLong?.contains("isn't inside the repo") == true)
        draft.requirePaths = "apps/mac/** Mac"
        #expect(draft.tooLong?.contains("the tag \"Mac\"") == true)
        draft.requirePaths = (1...21).map { "a\($0)/** macos" }.joined(separator: "\n")
        #expect(draft.tooLong == "At most 20 path rules.")
    }
}
