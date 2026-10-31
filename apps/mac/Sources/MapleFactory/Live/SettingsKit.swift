import SwiftUI

/// Settings in the System Settings style: a pane is a large title over titled groups of inset rows,
/// each row a label on the left and its control on the right, with hairlines between rows.
enum SettingsKit {
    /// Behind the panes, so the groups (`Theme.cardBG`) stand out from it.
    static let paneBG = Color(light: 0xF2F0F1, dark: 0x161419)
    static let sidebarBG = Color(light: 0xE8E5E7, dark: 0x211E25)
    static let groupStroke = Color(light: .black.opacity(0.06), dark: .white.opacity(0.06))
    static let caption = Font.system(size: 11.5)
}

/// One pane: a scrolling page with a large title, an optional subtitle, then its sections.
struct SettingsPane<Content: View>: View {
    let title: String
    var subtitle: String?
    /// What sits at the right of the title, like Repositories' Refresh.
    var accessory: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsTitle(title: title, subtitle: subtitle, accessory: accessory)
                content
            }
            .font(.system(size: 13))
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A pane's large title and what it's for.
struct SettingsTitle: View {
    let title: String
    var subtitle: String?
    var accessory: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let accessory { accessory }
        }
    }
}

/// A titled group of rows on a rounded background, with a hairline between each row and an optional
/// caption under it.
struct SettingsSection<Content: View>: View {
    var title: String?
    var caption: String?
    /// What sits at the right of the title, like Secrets' Add.
    var accessory: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, caption: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text) }
                    Spacer(minLength: 8)
                    if let accessory { accessory.controlSize(.small) }
                }
                .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline().padding(.horizontal, 16) }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsKit.groupStroke))
            if let caption {
                Text(caption).font(SettingsKit.caption).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// One row: the label (and what it means, under it) on the left, its control on the right.
struct SettingsRow<Trailing: View>: View {
    let label: String
    var detail: String?
    var detailColor = Theme.textMuted
    @ViewBuilder let trailing: Trailing

    init(_ label: String, detail: String? = nil, detailColor: Color = Theme.textMuted, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.detail = detail
        self.detailColor = detailColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(SettingsKit.caption).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .settingsRowPadding()
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ label: String, detail: String? = nil, detailColor: Color = Theme.textMuted) {
        self.init(label, detail: detail, detailColor: detailColor) { EmptyView() }
    }
}

/// A row whose value is plain text on the right, like Version.
struct SettingsValueRow: View {
    let label: String
    let value: String
    var detail: String?

    init(_ label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var body: some View {
        SettingsRow(label, detail: detail) {
            Text(value).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// A row with a switch on the right.
struct SettingsToggle: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ label: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(label, detail: detail) {
            Toggle(label, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// A row with a pop-up menu on the right.
struct SettingsPicker<Value: Hashable, Options: View>: View {
    let label: String
    var detail: String?
    @Binding var selection: Value
    @ViewBuilder let options: Options

    init(_ label: String, detail: String? = nil, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.label = label
        self.detail = detail
        _selection = selection
        self.options = options()
    }

    var body: some View {
        SettingsRow(label, detail: detail) {
            Picker(label, selection: $selection) { options }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// A row with a value (or a status) and a button on the right: Check Now, Choose…, Open System Settings.
struct SettingsButtonRow: View {
    let label: String
    var detail: String?
    var value: String?
    let button: String
    var role: ButtonRole?
    var disabled = false
    let action: () -> Void

    init(_ label: String, detail: String? = nil, value: String? = nil, button: String, role: ButtonRole? = nil, disabled: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.detail = detail
        self.value = value
        self.button = button
        self.role = role
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        SettingsRow(label, detail: detail) {
            HStack(spacing: 10) {
                if let value { Text(value).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1) }
                Button(button, role: role, action: action).disabled(disabled)
            }
        }
    }
}

/// A row of its own content (an editor, a preview, a list), padded like the others.
struct SettingsBlock<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowPadding()
    }
}

/// A quiet note as the group's last row: who can change it, or what went wrong.
struct SettingsNote: View {
    let text: String
    var systemImage = "lock"
    var color = Theme.textMuted

    init(_ text: String, systemImage: String = "lock", color: Color = Theme.textMuted) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowPadding()
    }
}

/// The sidebar's colored rounded square behind a pane's symbol.
struct SettingsTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26).fill(color.gradient))
    }
}

extension View {
    /// A settings row's inset: 16 on the sides, enough above and below for a 44pt row.
    func settingsRowPadding() -> some View {
        padding(.horizontal, 16).padding(.vertical, 11).frame(minHeight: 44)
    }
}
