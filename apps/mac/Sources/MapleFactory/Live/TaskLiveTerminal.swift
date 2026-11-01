import SwiftUI

/// A task's working session, live: the agent's terminal as it runs, typed into like any other.
struct TaskLiveTerminal: View {
    @Environment(FactoryClient.self) private var client
    let task: FactoryTask
    let worker: FactoryTask.Worker

    @State private var link: TerminalLink.State = .connecting

    private var machine: Wire.Machine? { client.machines.first { $0.id == worker.machine } }
    private var activity: Wire.Activity? { client.workerActivity(for: worker) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentAvatar(agent: LiveAdapter.role(worker.role), size: 18, online: true)
                Text(LiveAdapter.role(worker.role).name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                AgentIcon(agent: worker.agent, size: 12).foregroundStyle(Theme.textMuted)
                Text("\(agentTitle(worker.agent)) on \(machine?.name ?? worker.machine)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                if let state = activity?.state {
                    HStack(spacing: 4) {
                        Circle().fill(state.color).frame(width: 6, height: 6)
                        Text(state.title)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.color)
                }
                Spacer()
                if let log = task.liveLog {
                    Text(log)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.cardBG)

            ZStack(alignment: .bottom) {
                Term.bg
                LiveTerminal(request: { cols, rows in
                    client.terminalRequest(machine: worker.machine, session: worker.session, cols: cols, rows: rows)
                }, state: $link)
                .padding(.leading, 12)
                .padding(.top, 8)
                if case .closed(let reason) = link {
                    Label(reason, systemImage: "wifi.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(Theme.cardBG))
                        .padding(14)
                }
            }

            HStack(spacing: 8) {
                Text(" maple ")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Term.bg)
                    .background(Theme.accent)
                Text("\(task.id.lowercased()) · \(worker.role)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x9096A0))
                Spacer()
                Text(link == .live ? "Attached · type to steer it directly" : link == .connecting ? "Attaching…" : "Detached")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x9096A0))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Term.chrome)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        .id(worker.session)
    }
}
