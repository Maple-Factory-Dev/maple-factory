import Foundation

/// The order of a task page's main column, which changes with the task's stage: while a plan is
/// being written and approved the brief leads, since that's what's being judged; once there are
/// changes the review and its proofs lead, and the brief and plan fold to a line each.
enum TaskPageLayout {
    enum Section: String, CaseIterable {
        /// Since-last-viewed, stranded, live strip, question and raised hand: always on top.
        case banners
        /// The "Ready to review" strip: verdict, proofs, lines changed, PR, jump links.
        case reviewSummary
        case doneWhen
        case autoReview
        case artifacts
        case mockups
        /// The brief, or the spec once there is one.
        case brief
        case plan
        case timeline

        /// The ScrollViewReader id the summary strip jumps to (and `-scroll` opens at).
        var anchor: String {
            switch self {
            case .autoReview: "review"
            default: rawValue
            }
        }
    }

    struct Layout: Equatable {
        let sections: [Section]
        let folded: Set<Section>
    }

    static func sections(for state: TaskState) -> Layout {
        switch state {
        case .reviewing, .merged, .closed:
            Layout(sections: [.banners, .reviewSummary, .doneWhen, .autoReview, .artifacts, .mockups, .brief, .plan, .timeline],
                   folded: [.brief, .plan])
        case .building:
            Layout(sections: [.banners, .plan, .doneWhen, .autoReview, .artifacts, .mockups, .brief, .timeline],
                   folded: [.brief])
        case .drafting, .planning, .awaitingApproval, .backlog, .cancelled:
            Layout(sections: [.banners, .autoReview, .brief, .mockups, .artifacts, .plan, .doneWhen, .timeline],
                   folded: [])
        }
    }
}
