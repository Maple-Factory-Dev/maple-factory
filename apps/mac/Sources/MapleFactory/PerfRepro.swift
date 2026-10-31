#if PERF_REPRO
import AppKit
import Foundation

/// MF-168's hang repro, built only with `swift build -c release -Xswiftc -DPERF_REPRO`; never in a shipped app.
/// `-perfRepro <tasks>` (with a demo flag, e.g. `-layout board`) fills the mockup's goal with that many
/// tasks, streams updates to them like a live factory does, and drives the window through the board,
/// list and overview, with and without the task panel, scrolling each. A run-loop observer times every
/// pass of the main thread; each phase's slowest pass and its count over 100/250ms print at the end.
@MainActor
enum PerfRepro {
    static func start(_ state: AppState) {
        guard let raw = Headless.value("perfRepro", in: ProcessInfo.processInfo.arguments), let count = Int(raw) else { return }
        Watchdog.install()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            fill(state, count: count)
            Task { await drive(state) }
        }
    }

    private static func fill(_ state: AppState, count: Int) {
        let goal = state.tasks.first?.goal ?? "Auth overhaul"
        let seeds = state.tasks.filter { $0.goal == goal }
        var tasks = state.tasks
        var queueRank = (tasks.map(\.queueRank).max() ?? 0) + 1
        var draftRank = (tasks.map(\.draftRank).max() ?? 0) + 1
        for n in 0..<max(0, count - seeds.count) {
            let seed = seeds[n % seeds.count]
            var task = FactoryTask(id: "PRF-\(n)", goal: goal, title: "\(seed.title) #\(n)", state: seed.state, detail: seed.detail)
            task.agent = seed.agent; task.owner = seed.owner; task.progress = seed.progress; task.diff = seed.diff
            task.checksFailing = seed.checksFailing; task.needsYou = seed.needsYou; task.span = seed.span; task.updated = seed.updated
            task.brief = seed.brief; task.plan = seed.plan; task.activity = seed.activity; task.comments = seed.comments
            task.doneWhen = seed.doneWhen; task.liveLog = seed.liveLog; task.autoReview = seed.autoReview; task.hand = seed.hand
            task.pr = seed.pr; task.reviews = seed.reviews; task.worker = seed.worker; task.machine = seed.machine
            task.effort = seed.effort; task.priority = seed.priority
            // A third of them wait in the queue, and a fifth are drafts: the columns with drag and drop.
            if n % 3 == 0 { task.queued = true; task.queueRank = queueRank; queueRank += 1 }
            else if n % 5 == 0 { task.state = .drafting; task.draftRank = draftRank; draftRank += 1 }
            tasks.append(task)
        }
        state.tasks = tasks
        print("perfRepro: \(state.tasks.filter { $0.goal == goal }.count) tasks in \(goal): " +
              "\(state.tasks.filter { $0.goal == goal && $0.queued }.count) queued, \(state.tasks.filter { $0.goal == goal && $0.state == .drafting }.count) drafts")
    }

    /// Like a live factory's stream: a building task's progress every 300ms, and every 2s one task moving on.
    private static func stream(_ state: AppState) -> Timer {
        var tick = 0
        return Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                var tasks = state.tasks
                if let i = tasks.indices.filter({ tasks[$0].state == .building }).randomElement() {
                    tasks[i].progress = Double(tick % 100) / 100
                    tasks[i].updated = "now"
                }
                if tick % 7 == 0, let i = tasks.indices.filter({ tasks[$0].queued }).randomElement() {
                    tasks[i].queued = false
                    tasks[i].state = .building
                }
                if tick % 7 == 3, let i = tasks.indices.filter({ tasks[$0].state == .building && !tasks[$0].queued }).randomElement() {
                    tasks[i].queued = true
                    tasks[i].queueRank = (tasks.map(\.queueRank).max() ?? 0) + 1
                }
                state.tasks = tasks
            }
        }
    }

    private static func drive(_ state: AppState) async {
        let timer = stream(state)
        let sample = state.tasks.first { $0.id.hasPrefix("PRF-") }?.id ?? state.selectedTask
        let phases: [(String, () -> Void)] = [
            ("board", { state.showInspector = false; state.layout = .board }),
            ("board scroll", { scrollAll() }),
            ("list", { state.layout = .list }),
            ("list scroll", { scrollAll() }),
            ("overview", { state.layout = .overview }),
            ("overview scroll", { scrollAll() }),
            ("board+panel", { state.layout = .board; state.selectedTask = sample; state.showInspector = true }),
            ("board+panel scroll", { scrollAll() }),
            ("list+panel", { state.layout = .list }),
            ("list+panel scroll", { scrollAll() }),
            ("switch board/list", { switcher(state) }),
        ]
        for (name, action) in phases {
            Watchdog.phase = name
            action()
            try? await Task.sleep(for: .seconds(6))
            scrolling?.invalidate(); scrolling = nil
            switching?.invalidate(); switching = nil
        }
        timer.invalidate()
        Watchdog.report()
        exit(0)
    }

    private static var scrolling: Timer?
    private static var switching: Timer?

    /// Every scroll view in the window, down and back up a screenful at a time, as a trackpad would.
    private static func scrollAll() {
        var step = 0
        scrolling = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                let down = (step / 40) % 2 == 0
                for scroll in scrollViews(NSApp.windows.first { $0.isVisible }?.contentView) {
                    guard let doc = scroll.documentView else { continue }
                    let clip = scroll.contentView
                    let maxY = max(0, doc.frame.height - clip.bounds.height), maxX = max(0, doc.frame.width - clip.bounds.width)
                    var origin = clip.bounds.origin
                    origin.y = min(maxY, max(0, origin.y + (down ? 60 : -60)))
                    if maxX > 0 { origin.x = min(maxX, max(0, origin.x + (down ? 40 : -40))) }
                    clip.scroll(to: origin)
                    scroll.reflectScrolledClipView(clip)
                }
            }
        }
    }

    private static func switcher(_ state: AppState) {
        switching = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in
            MainActor.assumeIsolated { state.layout = state.layout == .board ? .list : .board }
        }
    }

    private static func scrollViews(_ view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }
}

/// Times each pass of the main run loop: from waking to going back to sleep.
@MainActor
enum Watchdog {
    static var phase = "launch"
    private static var started: CFAbsoluteTime = 0
    private static var stats: [(phase: String, max: Double, over100: Int, over250: Int, passes: Int)] = []

    static func install() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting { started = now; return }
                guard started > 0 else { return }
                record((now - started) * 1000)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func record(_ ms: Double) {
        if stats.last?.phase != phase { stats.append((phase, 0, 0, 0, 0)) }
        stats[stats.count - 1].max = max(stats[stats.count - 1].max, ms)
        stats[stats.count - 1].passes += 1
        if ms > 100 { stats[stats.count - 1].over100 += 1 }
        if ms > 250 { stats[stats.count - 1].over250 += 1; print(String(format: "perfRepro: %@ stall %.0fms", phase, ms)) }
    }

    static func report() {
        print("perfRepro: phase                  slowest  >100ms  >250ms  passes")
        for s in stats {
            print("perfRepro: " + s.phase.padding(toLength: 22, withPad: " ", startingAt: 0)
                  + String(format: " %6.0fms  %6d  %6d  %6d", s.max, s.over100, s.over250, s.passes))
        }
        fflush(stdout)
    }
}
#endif
