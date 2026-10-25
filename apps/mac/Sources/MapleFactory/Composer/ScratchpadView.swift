import SwiftUI

/// Loose Markdown notes that aren't tasks yet. Any note can be promoted into the composer.
struct ScratchpadView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            noteList
                .frame(width: 270)
            Hairline(vertical: true)
            if let index = state.notes.firstIndex(where: { $0.id == state.selectedNote }) {
                NoteEditor(index: index)
                    .id(state.notes[index].id)
            } else {
                PlaceholderView(title: "No note selected", icon: "note.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scratchpad")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("New note")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
                .contentShape(Rectangle())
                .onTapGesture { state.newNote() }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.notes) { note in noteRow(note) }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        let selected = note.id == state.selectedNote
        let preview = note.body
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(note.title.isEmpty ? Theme.textMuted : Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(note.updated)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
            Text(preview)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
            if let taskID = note.taskID {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5))
                    Text(taskID).font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Theme.State.planning)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.fillSelected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedNote = note.id }
    }
}

private struct NoteEditor: View {
    @Environment(AppState.self) private var state
    let index: Int

    var body: some View {
        @Bindable var state = state
        let note = state.notes[index]

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Untitled note", text: $state.notes[index].title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if let taskID = note.taskID {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                            Text("Open \(taskID)")
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.destination = .goal(state.task(taskID).goal)
                            state.openFocus(taskID)
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.square").font(.system(size: 11))
                        Text("Turn into task")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.startCompose(title: note.title, body: note.body, fromNote: note.id)
                    }
                }

                Text("Notes stay private to the scratchpad until you turn them into a task.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)

                MarkdownEditor(text: $state.notes[index].body, placeholder: "Jot it down…", minHeight: 480)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
