import SwiftUI

struct TopBar: View {
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        HStack(spacing: 8) {
            Pill {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                Text("feature/auth-flow")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Image(systemName: appearance.icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .onTapGesture { appearance = appearance.next }
                .help("Appearance: \(appearance.rawValue.capitalized)")
            Pill {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("Development")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10))
                Text("Run")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.opacity(0.35)))
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 7) { content }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
    }
}

struct EditorPane: View {
    @State private var activeTab = MockData.tabs[0]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            breadcrumb
            CodeView()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MockData.tabs, id: \.self) { tab in
                let active = tab == activeTab
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                    Text(tab)
                        .foregroundStyle(active ? Theme.text : Theme.textMuted)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .opacity(active ? 1 : 0)
                }
                .font(Theme.uiFont)
                .padding(.horizontal, 16)
                .frame(minWidth: 170, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(active ? Theme.fillSubtle : .clear)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                .contentShape(Rectangle())
                .onTapGesture { activeTab = tab }
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.trailing, 16)
        }
        .frame(height: 46)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 7) {
            Text("src")
            crumbSeparator
            Text("components")
            crumbSeparator
            Image(systemName: "doc.text").font(.system(size: 11))
            Text(activeTab).foregroundStyle(Theme.text.opacity(0.85))
            crumbSeparator
            Text("ƒ").italic()
            Text("AssistantPanel").foregroundStyle(Theme.text.opacity(0.85))
            Spacer()
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            Text("1 warning")
            Image(systemName: "square.3.layers.3d").padding(.leading, 10)
            Image(systemName: "eye").padding(.leading, 6)
            Image(systemName: "ellipsis").padding(.leading, 6)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var crumbSeparator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Theme.textFaint)
    }
}

struct CodeView: View {
    private let charWidth = ("M" as NSString).size(withAttributes: [.font: Theme.codeNSFont]).width

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MockData.code.enumerated()), id: \.offset) { index, line in
                    lineView(number: index + 1, text: line)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
    }

    private func lineView(number: Int, text: String) -> some View {
        let isCurrent = number == MockData.currentLine
        let diagnostic = MockData.diagnostics[number]

        return HStack(spacing: 0) {
            Text("\(number)")
                .font(Theme.codeFont)
                .foregroundStyle(isCurrent ? Theme.text : Theme.textFaint)
                .frame(width: 42, alignment: .trailing)

            ZStack {
                if diagnostic != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
            }
            .frame(width: 24)

            Rectangle()
                .fill(MockData.changedLines.contains(number) ? Theme.changeBar : .clear)
                .frame(width: 2)
                .padding(.trailing, 16)

            Text(SyntaxHighlighter.highlight(text, squiggle: diagnostic?.word))
                .font(Theme.codeFont)
                .fixedSize()
                .overlay(alignment: .leading) {
                    if isCurrent {
                        BlinkingCursor()
                            .offset(x: CGFloat(MockData.cursorColumn - 1) * charWidth - 1)
                    }
                }

            if let diagnostic {
                Text(diagnostic.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning.opacity(0.85))
                    .padding(.leading, 28)
            }

            Spacer(minLength: 40)
        }
        .frame(height: Theme.lineHeight)
        .frame(minWidth: 760, alignment: .leading)
        .background(isCurrent ? Theme.currentLine : .clear)
    }
}

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Theme.text)
            .frame(width: 1.5, height: 17)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false }
            }
    }
}
