import AppKit
import SwiftUI

/// The colors a goal can pick, and matching a saved hex back to one. The first six are the original
/// palette, so goals made before it grew still find their swatch.
enum GoalColors {
    static let palette: [(name: String, hex: String)] = [
        ("Green", "#2EA043"), ("Blue", "#3B82F6"), ("Violet", "#8B5CF6"), ("Amber", "#F59E0B"), ("Pink", "#EC4899"), ("Teal", "#14B8A6"),
        ("Red", "#EF4444"), ("Orange", "#F97316"), ("Yellow", "#EAB308"), ("Lime", "#84CC16"), ("Emerald", "#10B981"),
        ("Cyan", "#06B6D4"), ("Sky", "#0EA5E9"), ("Indigo", "#6366F1"), ("Purple", "#A855F7"), ("Slate", "#64748B"),
    ]

    /// A goal's color: one of the palette's, or any other hex (the Custom swatch).
    enum Choice: Equatable {
        case swatch(Int)
        case custom(String)

        var hex: String {
            switch self {
            case .swatch(let index): GoalColors.palette[index].hex
            case .custom(let hex): hex
            }
        }
    }

    /// The swatch a saved hex is, ignoring case; anything else stays as it was, as Custom.
    static func choice(for hex: String) -> Choice {
        if let index = palette.firstIndex(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) { return .swatch(index) }
        return .custom(hex)
    }

    /// "#RRGGBB" for a color picked in the system picker.
    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return palette[0].hex }
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
