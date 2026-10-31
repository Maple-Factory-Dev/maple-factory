import Foundation

/// A `maplefactory://` link: `maplefactory://task/<id>` (the server's /t/<id> page and copied links)
/// or `maplefactory://session/<machine>/<id>` (a shared session). Path components come back
/// percent-decoded, as `URL.pathComponents` gives them.
public enum FactoryLink: Equatable, Sendable {
    case task(String)
    case session(machine: String, id: String)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "maplefactory" else { return nil }
        let path = url.pathComponents.dropFirst().filter { !$0.isEmpty }
        switch url.host() {
        case "task" where path.count == 1:
            self = .task(path[path.startIndex])
        case "session" where path.count == 2:
            self = .session(machine: path[path.startIndex], id: path[path.startIndex + 1])
        default:
            return nil
        }
    }
}
