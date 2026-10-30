import Foundation

/// A factory's HTTP API, before and after signing in: the health probe, GitHub's device-flow sign-in,
/// and JSON loads with the member's token. Holds no state, so the Mac and iOS apps can each keep theirs.
public struct FactoryAPI: Sendable {
    public let server: URL
    public let token: String

    public init(server: URL, token: String) {
        self.server = server
        self.token = token
    }

    /// A request to `path` on the factory, with this member's token.
    public func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// `path`'s JSON, with this member's token.
    public func load<T: Decodable>(_ path: String, method: String = "GET") async throws -> T {
        try await Self.load(request(path, method: method))
    }

    // MARK: Before signing in

    public struct Health: Decodable, Sendable {
        public let ok: Bool
        public let protocolVersion: Int
        public let org: String?
        /// "github", "dev" (a local server signs you in as its DEV_LOGIN) or "unconfigured".
        public let signIn: String
        public let devLogin: String?

        enum CodingKeys: String, CodingKey { case ok, org, signIn, devLogin, protocolVersion = "protocol" }
    }

    public struct SignInResult: Decodable, Sendable {
        public var server: URL = URL(string: "about:blank")!
        public let token: String
        public let member: Wire.Member
        public let org: String

        enum CodingKeys: String, CodingKey { case token, member, org }
    }

    public struct DeviceCode: Decodable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationUri: URL
        public let interval: Int
        public let expiresIn: Int
    }

    public struct Enrollment: Decodable, Sendable {
        public let code: String
        public let expiresAt: Double
        public let commands: [String]
    }

    public enum ClientError: LocalizedError {
        case message(String)
        public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }

    /// "localhost:8787" → http://localhost:8787; anything else is https unless it says otherwise.
    public static func serverURL(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasSuffix(".local") || text.contains(".local:")
            text = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    public static func websocketURL(_ server: URL, path: String) -> URL {
        var components = URLComponents(url: server.appending(path: path), resolvingAgainstBaseURL: false)!
        components.scheme = server.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    public static func probe(_ server: URL) async throws -> (Health, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        var request = URLRequest(url: server.appending(path: "/healthz"))
        request.timeoutInterval = 8
        let health: Health = try await load(request)
        return (health, clock.now - start)
    }

    public static func startDeviceFlow(_ server: URL) async throws -> DeviceCode {
        var request = URLRequest(url: server.appending(path: "/auth/device/start"))
        request.httpMethod = "POST"
        return try await load(request)
    }

    /// Nil while GitHub is still waiting on the person. `deviceLabel` names this device in the
    /// member's list of sign-ins (the Mac's name, say).
    public static func pollDeviceFlow(_ server: URL, code: String, deviceLabel: String) async throws -> SignInResult? {
        var request = URLRequest(url: server.appending(path: "/auth/device/poll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceCode": code, "label": deviceLabel])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 202 { return nil }
        guard status == 200 else { throw ClientError.message(String(data: data, encoding: .utf8) ?? "Sign-in failed (\(status)).") }
        var result = try JSONDecoder().decode(SignInResult.self, from: data)
        result.server = server
        return result
    }

    /// The JSON `request` answers with; an error status throws the server's text.
    public static func load<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ClientError.message(text.isEmpty || text.hasPrefix("<") ? "The server answered \(status)." : text)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.message("That doesn't look like a Maple factory.")
        }
    }

    public static let tooNewMessage = "This factory is newer than this app — update Maple Factory."

    public static func describe(_ error: Error, response: URLResponse? = nil) -> String {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { return "Your sign-in expired." }
        if error is DecodingError { return tooNewMessage }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "Can't reach the factory."
        case NSURLErrorNotConnectedToInternet: return "You're offline."
        case NSURLErrorTimedOut: return "The factory took too long to answer."
        case NSURLErrorNetworkConnectionLost: return "The connection dropped."
        default: return (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        }
    }
}
