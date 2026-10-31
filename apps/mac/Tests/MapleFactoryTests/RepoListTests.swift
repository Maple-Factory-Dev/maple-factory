import Foundation
import Testing
@testable import MapleFactory

/// The shared repo list's search, avatars and grouping (MF-136).
struct RepoListTests {
    private let api = Wire.OrgRepo(name: "acme/api", defaultBranch: "main", isPrivate: true, source: .github,
                                   description: "The billing API", ownerAvatarUrl: "https://avatars.githubusercontent.com/u/1?v=4")
    private let web = Wire.OrgRepo(name: "acme/web", isPrivate: false, source: .github, description: "Marketing site")
    private let tool = Wire.OrgRepo(name: "afomera/tool", isPrivate: false, source: .manual)

    @Test func matchesNameOwnerAndDescription() {
        #expect(RepoList.matches(api, "api"))
        #expect(RepoList.matches(tool, "afomera"))
        #expect(RepoList.matches(api, "billing"))
        #expect(!RepoList.matches(web, "billing"))
        #expect(!RepoList.matches(tool, "billing"))
    }

    @Test func matchingIgnoresCase() {
        #expect(RepoList.matches(api, "BILLING"))
        #expect(RepoList.matches(api, "Acme/API"))
    }

    @Test func emptyQueryMatchesEverything() {
        for repo in [api, web, tool] {
            #expect(RepoList.matches(repo, ""))
            #expect(RepoList.matches(repo, "   "))
        }
    }

    @Test func avatarUsesGitHubsThenFallsBackToTheOwnersPng() {
        #expect(RepoList.avatarURL(for: api)?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(RepoList.avatarURL(for: tool)?.absoluteString == "https://github.com/afomera.png?size=40")
        let blank = Wire.OrgRepo(name: "acme/x", isPrivate: true, source: .github, ownerAvatarUrl: "")
        #expect(RepoList.avatarURL(for: blank)?.absoluteString == "https://github.com/acme.png?size=40")
    }

    @Test func pinnedStayOnTopAndOwnersGetHeaders() {
        let entries = RepoList.entries([api, web, tool], query: "billing", pinned: { $0.name == "afomera/tool" })
        #expect(entries == [.repo(tool), .repo(api)])
        let all = RepoList.entries([api, web, tool], query: "")
        #expect(all == [.owner("acme"), .repo(api), .repo(web), .owner("afomera"), .repo(tool)])
        #expect(RepoList.entries([api, web], query: "") == [.repo(api), .repo(web)])
    }

    @Test func noMatchesSaysSo() {
        #expect(RepoList.entries([api, web], query: " foo ") == [.noMatches("foo")])
        #expect(RepoList.entries([api, web], query: "foo", pinned: { $0 == api }) == [.repo(api), .noMatches("foo")])
    }

    /// A repo list stored, or sent by a server, before the two fields existed still decodes.
    @Test func anOldOrgRepoStillDecodes() throws {
        let old = Data(#"{"name":"acme/api","defaultBranch":"main","isPrivate":true,"source":"github"}"#.utf8)
        let repo = try JSONDecoder().decode(Wire.OrgRepo.self, from: old)
        #expect(repo.name == "acme/api")
        #expect(repo.description == nil)
        #expect(repo.ownerAvatarUrl == nil)
        #expect(RepoList.avatarURL(for: repo)?.absoluteString == "https://github.com/acme.png?size=40")
    }
}
