import Foundation

/// What a beta tester is writing in Help › Send Feedback…, before it goes. Pure, so it's testable without SwiftUI.
struct FeedbackDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, idea, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bug: "Bug"
            case .idea: "Idea"
            case .other: "Other"
            }
        }
        /// The message box's prompt, which changes with the kind.
        var placeholder: String {
            switch self {
            case .bug: "What happened, and what did you expect? Steps to repeat it help most."
            case .idea: "What would make Maple Factory better for you?"
            case .other: "Tell us anything."
            }
        }
    }

    /// Where the fallback email goes when Sentry can't send.
    static let address = "feedback@maplefactory.dev"

    var kind: Kind = .bug
    var message = ""
    var email = ""
    var attachScreenshot = false

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The email given, if any; nil when the field's blank.
    var replyEmail: String? { trimmedEmail.isEmpty ? nil : trimmedEmail }

    /// No email is fine; one given has to look like an address.
    var emailLooksValid: Bool {
        guard let email = replyEmail else { return true }
        return email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    var canSend: Bool { !trimmedMessage.isEmpty && emailLooksValid }

    /// The message as Sentry gets it, with its kind in front: "[Bug] The board froze".
    var sentryMessage: String { "[\(kind.title)] \(trimmedMessage)" }

    /// The fallback: an email to the feedback address with the kind, message and the app's version, build and screen.
    func mailtoURL(version: String, build: String, screen: String?) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.address
        let body = """
        \(trimmedMessage)

        —
        Kind: \(kind.title)
        Version: \(version) (\(build))
        Screen: \(screen ?? "unknown")
        """
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Maple Factory feedback: \(kind.title)"),
            URLQueryItem(name: "body", value: body),
        ]
        // URLComponents leaves "+" alone, which mail clients read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
