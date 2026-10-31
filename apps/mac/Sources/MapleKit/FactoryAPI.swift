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

    /// A socket request for one session's terminal (`/client/terminal`). With `cols` × `rows`, a viewer who can type
    /// resizes the session's pane to fit; without them (the phone) the pane keeps its size.
    public static func terminalRequest(_ server: URL, token: String, machine: String, session: String, cols: Int? = nil, rows: Int? = nil) -> URLRequest {
        var components = URLComponents(url: websocketURL(server, path: "/client/terminal"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [.init(name: "machine", value: machine), .init(name: "session", value: session)]
        if let cols, let rows { items += [.init(name: "cols", value: String(cols)), .init(name: "rows", value: String(rows))] }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Why a terminal socket was refused or closed, in the server's words, when it's about access rather than a
    /// network blip: a 403 (only the machine's owner or an admin; the same URL over plain HTTP says so) or close
    /// code 4003 (this person's access was revoked). Nil: try again as usual.
    public static func terminalRefusal(_ socket: URLSessionWebSocketTask) async -> String? {
        if socket.closeCode.rawValue == 4003 { return "Your access to this factory was revoked." }
        guard (socket.response as? HTTPURLResponse)?.statusCode == 403, var request = socket.originalRequest,
              let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        request.url = components.url
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 403,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return "You can't open terminals on this machine." }
        return text
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
