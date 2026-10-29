import SwiftUI

/// A Gantt-style view: fixed task labels on the left, a horizontally scrolling day grid on the right.
struct GoalTimeline: View {
    @Environment(AppState.self) private var state
    let goal: Goal
    let tasks: [FactoryTask]

    private let dayWidth: CGFloat = 30
    private let rowHeight: CGFloat = 38
    private let headerHeight: CGFloat = 46
    private let labelWidth: CGFloat = 290

    private var rows: [FactoryTask] { GoalTimeline.visibleRows(tasks, showMerged: state.timelineShowsMerged) }
    private var mergedCount: Int { tasks.filter { $0.state == .merged }.count }
    /// Every task is merged and hidden, so the grid would be blank.
    private var allHidden: Bool { rows.isEmpty && mergedCount > 0 }
    private var chartHeight: CGFloat {
        headerHeight + CGFloat(rows.count) * rowHeight + (allHidden ? rowHeight : 0) + 24
    }

    /// The tasks the timeline draws, by span start: merged ones only when `showMerged` is on.
    static func visibleRows(_ tasks: [FactoryTask], showMerged: Bool) -> [FactoryTask] {
        tasks
            .filter { showMerged || $0.state != .merged }
            .sorted { $0.span.lowerBound < $1.span.lowerBound }
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                labels.frame(width: labelWidth)
                Hairline(vertical: true)
                ScrollView(.horizontal) {
                    chart
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.leading)
            }
            .frame(height: chartHeight)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: Labels

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionLabel(title: "Task")
                Spacer()
                if mergedCount > 0 { mergedToggle }
                SectionLabel(title: "Owner")
            }
            .padding(.horizontal, 24)
            .frame(height: headerHeight)
            .overlay(alignment: .bottom) { Hairline() }

            if allHidden {
                Text("All \(mergedCount) tasks merged. Show merged to see them.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            }

            ForEach(rows) { task in
                HStack(spacing: 8) {
                    Image(systemName: task.state.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(task.state.color)
                        .frame(width: 14)
                    Text(task.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Text(task.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(task.state == .cancelled ? Theme.textMuted : Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    AvatarPair(owner: task.owner, agent: task.agent, size: 16)
                }
                .padding(.leading, 24)
                .padding(.trailing, 12)
                .frame(height: rowHeight)
                .background(state.openedTask == task.id ? Theme.fillSelected : .clear)
                .contentShape(Rectangle())
                .onTapGesture { state.toggleTask(task.id) }
            }
        }
    }

    /// A pill like the layout picker's: lit while merged tasks show, with how many there are.
    private var mergedToggle: some View {
        let on = state.timelineShowsMerged
        return Text("Show merged · \(mergedCount)")
            .font(.system(size: 11.5, weight: on ? .medium : .regular).monospacedDigit())
            .foregroundStyle(on ? Theme.text : Theme.textMuted)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.cardBG : .clear))
            .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
            .contentShape(Rectangle())
            .onTapGesture { state.timelineShowsMerged.toggle() }
            .help(on ? "Hide merged tasks" : "Show merged tasks")
    }

    // MARK: Chart

    private var chart: some View {
        ZStack(alignment: .topLeading) {
            dayGrid

            VStack(spacing: 0) {
                Color.clear.frame(height: headerHeight)
                ForEach(rows) { task in
                    bar(for: task)
                        .frame(width: CGFloat(FactoryData.timelineDays) * dayWidth, height: rowHeight, alignment: .leading)
                        .background(state.openedTask == task.id ? Theme.fillSelected : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { state.toggleTask(task.id) }
                }
            }

            marker(at: FactoryData.todayOffset, color: Theme.accent, dashed: false)
            marker(at: goal.dueOffset, color: Theme.State.cancelled, dashed: true)
        }
        .frame(width: CGFloat(FactoryData.timelineDays) * dayWidth, height: chartHeight, alignment: .topLeading)
    }

    private var dayGrid: some View {
        HStack(spacing: 0) {
            ForEach(0..<FactoryData.timelineDays, id: \.self) { offset in
                let date = FactoryData.date(offset)
                let weekend = Calendar.current.isDateInWeekend(date)

                VStack(spacing: 0) {
                    dayHeader(offset, date: date)
                        .frame(height: headerHeight)
                        .overlay(alignment: .bottom) { Hairline() }
                    Rectangle().fill(weekend ? Theme.fillSubtle : .clear)
                }
                .frame(width: dayWidth)
                .overlay(alignment: .leading) {
                    if Calendar.current.component(.weekday, from: date) == 2 {
                        Rectangle().fill(Theme.border).frame(width: 1)
                    }
                }
            }
        }
    }

    private func dayHeader(_ offset: Int, date: Date) -> some View {
        let day = Calendar.current.component(.day, from: date)
        let isToday = offset == FactoryData.todayOffset
        let isDue = offset == goal.dueOffset
        let showMonth = offset == 0 || day == 1

        return VStack(spacing: 3) {
            Text(showMonth ? date.formatted(.dateTime.month(.abbreviated)) : date.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 9.5, weight: showMonth ? .bold : .medium))
                .foregroundStyle(showMonth ? Theme.text : Theme.textFaint)
            Text("\(day)")
                .font(.system(size: 11, weight: isToday || isDue ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isToday ? Theme.onAccent : isDue ? .white : Theme.textMuted)
                .frame(width: 22, height: 18)
                .background {
                    if isToday {
                        Capsule().fill(Theme.accent)
                    } else if isDue {
                        Capsule().fill(Theme.State.cancelled)
                    }
                }
        }
    }

    private func marker(at offset: Int, color: Color, dashed: Bool) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: chartHeight - headerHeight))
        }
        .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 4] : []))
        .frame(width: 1.5, height: chartHeight - headerHeight)
        .offset(x: (CGFloat(offset) + 0.5) * dayWidth, y: headerHeight)
        .allowsHitTesting(false)
    }

    /// Solid up to today (work done), dashed outline for the projected remainder.
    private func bar(for task: FactoryTask) -> some View {
        let x = CGFloat(task.span.lowerBound) * dayWidth + 2
        let width = CGFloat(task.span.count) * dayWidth - 4
        let finished = task.state == .merged || task.state == .cancelled
        let elapsed = CGFloat(FactoryData.todayOffset + 1 - task.span.lowerBound) * dayWidth
        let doneWidth = finished ? width : min(max(elapsed, 0), width)
        let color = task.state.color.opacity(task.state == .cancelled ? 0.5 : 1)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
            UnevenRoundedRectangle(
                topLeadingRadius: 6, bottomLeadingRadius: 6,
                bottomTrailingRadius: doneWidth >= width ? 6 : 0, topTrailingRadius: doneWidth >= width ? 6 : 0
            )
            .fill(color.opacity(0.85))
            .frame(width: doneWidth)

            Text(task.id)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.onAccent)
                .padding(.leading, 8)
                .opacity(doneWidth > 70 ? 1 : 0)
        }
        .frame(width: width, height: 20)
        .offset(x: x)
    }
}
