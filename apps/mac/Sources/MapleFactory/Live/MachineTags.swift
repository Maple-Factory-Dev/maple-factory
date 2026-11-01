import SwiftUI

/// A machine's tags as small chips: what its runner detected, and (tinted) what its owner added by hand.
struct MachineTagChips: View {
    let machine: Wire.Machine

    var body: some View {
        if let tags = machine.tags, !tags.isEmpty {
            let detected = Set(machine.capabilities ?? [])
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    MachineTagChip(tag: tag, added: !detected.contains(tag))
                }
            }
        }
    }
}

struct MachineTagChip: View {
    let tag: String
    var added = false
    var hidden = false

    var body: some View {
        Text(tag)
            .font(.system(size: 11, design: .monospaced))
            .strikethrough(hidden)
            .foregroundStyle(hidden ? Theme.textFaint : added ? Theme.accent : Theme.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(added ? Theme.accent.opacity(0.12) : Theme.fill))
            .help(added ? "Added by its owner" : hidden ? "Detected, hidden by its owner" : "Detected by its runner")
    }
}
