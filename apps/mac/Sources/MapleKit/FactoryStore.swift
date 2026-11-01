import Foundation
import Security

/// A factory signed into on this device. Its token is in the Keychain under `server`.
public struct SavedFactory: Codable, Equatable, Identifiable, Sendable {
    public var server: URL
    public var org: String
    /// The org's name, or the host when it has none.
    public var name: String
    public var lastUsed: Date
    /// The factory's icon as this device last cached it (a file path); nil shows the letter tile.
    public var icon: String? = nil

    public var id: String { Self.key(server) }
    public var host: String { id }

    public init(server: URL, org: String, name: String, lastUsed: Date, icon: String? = nil) {
        self.server = server
        self.org = org
        self.name = name
        self.lastUsed = lastUsed
        self.icon = icon
    }

    /// One entry per host and port: http and https to the same place are the same factory.
    public static func key(_ url: URL) -> String { "\(url.host() ?? "")\(url.port.map { ":\($0)" } ?? "")" }
}

/// The saved-factory list's rules, kept pure so they can be tested; stored in defaults under `factories`.
public enum SavedFactories {
    public static let defaultsKey = "factories"

    public static func load(_ defaults: UserDefaults) -> [SavedFactory]? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([SavedFactory].self, from: $0) }
    }

    public static func store(_ list: [SavedFactory], _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
    }

    /// The list as saved, or, before there was one, the single factory this device was signed into.
    public static func migrate(_ saved: [SavedFactory]?, currentURL: String?, currentOrg: String?, now: Date = Date()) -> [SavedFactory] {
        if let saved { return saved }
        guard let currentURL, let url = URL(string: currentURL), url.host() != nil else { return [] }
        let org = currentOrg ?? ""
        let name = org.isEmpty || org == "local" ? url.host() ?? "Factory" : org
        return [SavedFactory(server: url, org: org, name: name, lastUsed: now)]
    }

    /// Adds the factory, or replaces the entry for the same host and port where it stands.
    public static func upsert(_ factory: SavedFactory, into list: [SavedFactory]) -> [SavedFactory] {
        var list = list
        if let index = list.firstIndex(where: { $0.id == factory.id }) {
            list[index] = factory
        } else {
            list.append(factory)
        }
        return list
    }

    public static func remove(_ server: URL, from list: [SavedFactory]) -> [SavedFactory] {
        list.filter { $0.id != SavedFactory.key(server) }
    }

    /// The factory to open after signing out of one: the most recently used of those left.
    public static func fallback(_ list: [SavedFactory]) -> SavedFactory? {
        list.max { $0.lastUsed < $1.lastUsed }
    }

    /// Whether the factory rail shows: an unset preference shows it once there are two or more
    /// factories to switch between; a set one (View › Show/Hide Factory Rail) overrides the count.
    public static func railShown(count: Int, preference: Bool?) -> Bool {
        preference ?? (count >= 2)
    }

    /// The factory ⌘N switches to: the Nth in saved order (from 1), nil past the end.
    public static func factory(forShortcut number: Int, in list: [SavedFactory]) -> SavedFactory? {
        list.indices.contains(number - 1) ? list[number - 1] : nil
    }
}

/// The factory token, in the login keychain under the factory's URL. A plain-http (local dev)
/// factory's token goes in `defaults` instead: every rebuild of an unsigned dev app would otherwise
/// ask for keychain access, and a localhost dev token guards nothing. `allInDefaults` (a headless
/// run, with its own wiped defaults) keeps every token there, so it never replaces the real app's item.
public struct Keychain: @unchecked Sendable {
    public let service: String
    /// UserDefaults is thread-safe; it just isn't marked Sendable.
    public let defaults: UserDefaults
    public let allInDefaults: Bool
    private let devKey = "devFactoryTokens"

    public init(service: String, defaults: UserDefaults, allInDefaults: Bool = false) {
        self.service = service
        self.defaults = defaults
        self.allInDefaults = allInDefaults
    }

    public static func isDev(_ account: String, headless: Bool) -> Bool { headless || account.hasPrefix("http://") }

    private func isDev(_ account: String) -> Bool { Self.isDev(account, headless: allInDefaults) }

    public func read(account: String) -> String? {
        if isDev(account) { return (defaults.dictionary(forKey: devKey) as? [String: String])?[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, account: String) {
        delete(account: account)
        if isDev(account) {
            var tokens = defaults.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = value
            defaults.set(tokens, forKey: devKey)
            return
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    public func delete(account: String) {
        if isDev(account) {
            var tokens = defaults.dictionary(forKey: devKey) as? [String: String] ?? [:]
            tokens[account] = nil
            defaults.set(tokens, forKey: devKey)
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
