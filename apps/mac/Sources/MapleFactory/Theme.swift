import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A color that resolves per appearance, so views never need to branch on light/dark themselves.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: Color(hex: light), dark: Color(hex: dark))
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var next: Appearance {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum Theme {
    static let editorBG = Color(light: 0xFDFCFB, dark: 0x18161C)
    static let raised = Color(light: 0xF4F2F3, dark: 0x221F27)
    static let border = Color(light: .black.opacity(0.07), dark: .white.opacity(0.06))

    /// Translucent fills layered on top of either the sidebar material or the editor slab.
    static let fill = Color(light: .black.opacity(0.045), dark: .white.opacity(0.06))
    static let fillSelected = Color(light: .black.opacity(0.07), dark: .white.opacity(0.085))
    static let fillSubtle = Color(light: .black.opacity(0.025), dark: .white.opacity(0.03))
    static let stroke = Color(light: .black.opacity(0.08), dark: .white.opacity(0.07))
    static let slabShadow = Color(light: .black.opacity(0.08), dark: .black.opacity(0.35))
    static let card = Color(light: .white.opacity(0.7), dark: .white.opacity(0.07))

    static let text = Color(light: 0x1D2025, dark: 0xE4E6EA)
    static let textMuted = Color(light: 0x6A707A, dark: 0x9096A0)
    static let textFaint = Color(light: 0xA9AEB6, dark: 0x5D626C)

    static let accent = Color(light: 0xD24E26, dark: 0xFF7A48)
    static let onAccent = Color(light: .white, dark: .black.opacity(0.75))
    /// Classic go-green for approve and merge, so decisions never read as the brand orange.
    static let approve = Color(light: 0x1F883D, dark: 0x2EA043)
    static let warning = Color(light: 0xB7791F, dark: 0xE2A93B)
    static let changeBar = Color(light: 0x5B8DEF, dark: 0x4C7BD9)
    static let currentLine = Color(light: 0x2F6FEB, dark: 0xFFFFFF).opacity(0.05)

    static let uiFont = Font.system(size: 13)
    static let codeFont = Font.system(size: 13, design: .monospaced)
    nonisolated(unsafe) static let codeNSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let lineHeight: CGFloat = 21

    static let mention = Color(light: 0xD9488F, dark: 0xF07AB4)
    static let cardBG = Color(light: 0xFFFFFF, dark: 0x1F1C23)
    static let columnBG = Color(light: 0xF6F4F5, dark: 0x1C1A20)
    /// Roughly what the sidebar material resolves to, for rings that need to cut into it.
    static let sidebarBG = Color(light: 0xEBE8EA, dark: 0x2B2830)
    static let tooltipBG = Color(light: 0x1D2025, dark: 0xF2F3F5)
    static let tooltipText = Color(light: 0xFFFFFF, dark: 0x1D2025)

    enum State {
        static let drafting = Color(light: 0x8A909A, dark: 0x8B919B)
        static let planning = Color(light: 0x7C5CE0, dark: 0xA48BFA)
        static let awaitingApproval = Color(light: 0xC27C0E, dark: 0xE9B04A)
        static let building = Color(light: 0x2F6FEB, dark: 0x6B9BF5)
        static let reviewing = Color(light: 0x0E8FA3, dark: 0x4CC4D6)
        static let merged = Color(light: 0x14A866, dark: 0x3DD68C)
        /// Ready, waiting for a person to merge: between Reviewing's teal and Merged's green.
        static let pendingMerge = Color(light: 0x5E9A1E, dark: 0x9BCF5A)
        static let cancelled = Color(light: 0xC8474B, dark: 0xD9696C)
    }

    enum Syntax {
        static let plain = Color(light: 0x24292F, dark: 0xD5D8DD)
        static let keyword = Color(light: 0x3A5FCD, dark: 0x7FA7F5)
        static let string = Color(light: 0x2E8549, dark: 0xA9DBA5)
        static let type = Color(light: 0x0F8577, dark: 0x6CCBA8)
        static let function = Color(light: 0x9A6200, dark: 0xE6C27F)
        static let tag = Color(light: 0x3A5FCD, dark: 0x7FA7F5)
        static let attribute = Color(light: 0x9A6200, dark: 0xE6C27F)
        static let number = Color(light: 0xC0531A, dark: 0xEFA26B)
        static let punctuation = Color(light: 0x8A909A, dark: 0x6E7480)
        static let comment = Color(light: 0x7A808A, dark: 0x6E7480)
    }
}
