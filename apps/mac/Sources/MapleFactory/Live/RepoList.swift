import SwiftUI

/// The org's repos as rows: the owner's avatar, owner/name, GitHub's description, private or public and the
/// default branch, with a search over name, owner and description. The goal editor's repo picker and
/// Settings → Repositories both use it, each with its own controls at the end of a row.
enum RepoList {
    /// Whether `repo` matches what was typed in the search: its name, owner or description, ignoring case.
    /// An empty query matches everything.
    static func matches(_ repo: Wire.OrgRepo, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return repo.name.localizedCaseInsensitiveContains(query)
            || (repo.description?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// The owner half of owner/name.
    static func owner(of repo: Wire.OrgRepo) -> String {
        repo.name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repo.name
    }

    /// The owner's avatar: the one GitHub sent, or else github.com/<owner>.png (repos added by hand, older servers).
    static func avatarURL(for repo: Wire.OrgRepo) -> URL? {
        if let sent = repo.ownerAvatarUrl, !sent.isEmpty, let url = URL(string: sent) { return url }
        let owner = owner(of: repo)
        guard !owner.isEmpty, let escaped = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(escaped).png?size=40")
    }

    /// What the list shows, in order.
    enum Entry: Hashable {
        /// An owner's header, when the repos shown come from more than one.
        case owner(String)
        case repo(Wire.OrgRepo)
        /// Nothing matches the search (pinned repos aside).
        case noMatches(String)
    }

    /// `repos` as the list shows them: the pinned ones first whatever the search, then the rest that match it,
    /// under their owners' headers when there's more than one owner.
    static func entries(_ repos: [Wire.OrgRepo], query: String, pinned: (Wire.OrgRepo) -> Bool = { _ in false }) -> [Entry] {
        let top = repos.filter(pinned)
        let rest = repos.filter { !pinned($0) && matches($0, query) }
        var entries = top.map(Entry.repo)
        let owners = Dictionary(grouping: rest, by: { owner(of: $0).lowercased() })
        if owners.count > 1 {
            // In the order each owner first comes up.
            var seen = Set<String>()
            for repo in rest where seen.insert(owner(of: repo).lowercased()).inserted {
                entries.append(.owner(owner(of: repo)))
                entries += owners[owner(of: repo).lowercased(), default: []].map(Entry.repo)
            }
        } else {
            entries += rest.map(Entry.repo)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty && !trimmed.isEmpty { entries.append(.noMatches(trimmed)) }
        return entries
    }

    /// The owner's avatar, or their initial in a rounded square when there's none (or it doesn't load).
    struct Avatar: View {
        let repo: Wire.OrgRepo
        var size: CGFloat = 22

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size * 0.24)
            ZStack {
                shape.fill(Theme.fill)
                Text(RepoList.owner(of: repo).prefix(1).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                if let url = RepoList.avatarURL(for: repo) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.stroke))
        }
    }

    /// One repo: its avatar, owner/name, private or public and default branch, and its description under them.
    struct Row<Leading: View, Trailing: View>: View {
        let repo: Wire.OrgRepo
        @ViewBuilder var leading: Leading
        @ViewBuilder var trailing: Trailing

        var body: some View {
            HStack(spacing: 10) {
                leading
                Avatar(repo: repo)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.name)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Image(systemName: repo.isPrivate ? "lock" : "globe")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                            .help(repo.isPrivate ? "Private" : "Public")
                        if let branch = repo.defaultBranch {
                            Text(branch).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                    }
                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(description)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }

    /// An owner's header over their repos.
    struct OwnerHeader: View {
        let owner: String

        var body: some View {
            Text(owner)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "No repos match ‘foo’".
    struct NoMatches: View {
        let query: String

        var body: some View {
            Text("No repos match ‘\(query)’")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The search, with how many repos there are to search.
    struct SearchField: View {
        @Binding var query: String
        let count: Int

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                TextField(count == 1 ? "Search 1 repository" : "Search \(count) repositories", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textFaint)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke)))
        }
    }
}
