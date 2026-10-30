import AppKit
import Testing
@testable import MapleFactory

/// The agents' marks: Claude and Codex come from the bundle as template images, so they follow
/// light and dark mode; anything else falls back to an SF Symbol.
@MainActor struct AgentIconTests {
    @Test(arguments: ["claude", "codex"]) func bundledAgentsHaveTheirMark(agent: String) throws {
        let image = try #require(AgentMark.bundled(agent))
        #expect(image.isTemplate)
        #expect(image.size.width > 0 && image.size.height > 0)
        // Loaded once.
        #expect(AgentMark.bundled(agent) === image)
    }

    @Test func otherAgentsFallBackToASymbol() {
        #expect(AgentMark.bundled("shell") == nil)
        #expect(AgentMark.bundled("gemini") == nil)
        #expect(AgentMark.symbol("shell") == "terminal")
        #expect(AgentMark.symbol("gemini") == "cpu")
        #expect(NSImage(systemSymbolName: AgentMark.symbol("shell"), accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: AgentMark.symbol("gemini"), accessibilityDescription: nil) != nil)
    }
}
