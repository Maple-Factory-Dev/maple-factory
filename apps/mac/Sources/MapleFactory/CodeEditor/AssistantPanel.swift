import SwiftUI

struct AssistantPanel: View {
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Refactor the assistant message handling to support loading and error states.")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.text)
                        .lineSpacing(3)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))

                    VStack(alignment: .leading, spacing: 14) {
                        Label {
                            Text("Maple AI").font(.system(size: 13, weight: .medium))
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        }
                        .foregroundStyle(Theme.text)

                        Text("I’ll update the message flow and introduce explicit request states so the interface can distinguish between idle, loading, success, and failure.")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.text.opacity(0.9))
                            .lineSpacing(4)

                        VStack(alignment: .leading, spacing: 10) {
                            step(1, "Add a request status type.")
                            step(2, "Handle asynchronous responses.")
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(16)
            }

            composer
                .padding(16)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("Code Assistant").font(.system(size: 13, weight: .medium))
            Spacer()
            Image(systemName: "plus").foregroundStyle(Theme.textMuted)
            Image(systemName: "ellipsis").foregroundStyle(Theme.textMuted).padding(.leading, 8)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n).").foregroundStyle(Theme.textMuted)
            Text(text).foregroundStyle(Theme.text.opacity(0.85))
        }
        .font(Theme.uiFont)
        .padding(.leading, 4)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Ask about your code...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.text)

            HStack(spacing: 10) {
                Image(systemName: "paperclip").foregroundStyle(Theme.textMuted)
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 11))
                    Text("AssistantPanel.tsx")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))

                Spacer()

                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.raised.opacity(0.7))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        )
    }
}

struct StatusBar: View {
    var body: some View {
        HStack(spacing: 16) {
            Label("feature/auth-flow", systemImage: "arrow.triangle.branch")
            Label("0 errors", systemImage: "xmark.circle")
            Label {
                Text("2 warnings")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
            Spacer()
            Text("Ln \(MockData.currentLine), Col \(MockData.cursorColumn)")
            Text("Spaces: 2")
            Text("UTF-8")
            Text("TypeScript React")
        }
        .labelStyle(TightLabel())
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10.5))
            configuration.title
        }
    }
}
