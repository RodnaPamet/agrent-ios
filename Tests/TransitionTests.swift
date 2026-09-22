import XCTest
@testable import Agrent

/// The server enforces `WORK_ITEM_TRANSITIONS` and refuses the rest —
/// measured against production: `IN_PROGRESS → OPEN` returns 400
/// "Illegal work-item transition: IN_PROGRESS → OPEN."
///
/// Offering a button that cannot work tells an operator the app is broken
/// when they asked for something that was never possible — and the refusal
/// arrives in English besides, because its code is the generic
/// `BAD_REQUEST` and the meaning is in the prose.
final class TransitionTests: XCTestCase {

    /// OPEN IS ENTRY-ONLY. Nothing returns to it, from anywhere.
    ///
    /// This is the one that changed a plan: the intention was to move a real
    /// task to IN_PROGRESS for testing and put it back afterwards, and the
    /// table says that is impossible. Worth a test of its own, because the
    /// consequence is that every status change in this app is one-way and
    /// the UI must not imply otherwise.
    func testNothingReturnsToOpen() {
        for status in WorkItemStatus.allCases {
            XCTAssertFalse(
                status.allowedNext.contains(.open),
                "\(status.rawValue) claims it can return to OPEN"
            )
        }
    }

    /// CLOSED and CANCELED are sinks. The menu is absent on them entirely,
    /// rather than present and disabled: a disabled control invites tapping,
    /// an absent one says the task is finished.
    func testTerminalStatusesAreSinks() {
        XCTAssertTrue(WorkItemStatus.closed.allowedNext.isEmpty)
        XCTAssertTrue(WorkItemStatus.canceled.allowedNext.isEmpty)
    }

    /// `PENDING_REVIEW` is reachable in the server's transition table but is
    /// NOT accepted by this route's schema — it is the field-operation
    /// review gate, reached by that flow, and sending it here is a zod 400.
    /// So it must never be offered, from any state.
    func testPendingReviewIsNeverOffered() {
        for status in WorkItemStatus.allCases {
            XCTAssertFalse(
                status.allowedNext.contains(.pendingReview),
                "\(status.rawValue) offers PENDING_REVIEW, which this route rejects"
            )
        }
    }

    /// An unrecognised status is one we cannot reason about. Offering moves
    /// from it would be guessing, and guessing here writes to a register.
    func testAnUnknownStatusOffersNothing() {
        XCTAssertTrue(WorkItemStatus.unknown.allowedNext.isEmpty)
    }

    /// No status offers itself: from == to is a no-op and the server
    /// returns 400 for it unless it is a true replay.
    func testNoStatusOffersItself() {
        for status in WorkItemStatus.allCases {
            XCTAssertFalse(status.allowedNext.contains(status), status.rawValue)
        }
    }

    /// The table, transcribed from the server, minus PENDING_REVIEW.
    /// Written out in full rather than derived, so a change on either side
    /// has to be made deliberately on this one too.
    func testTheTableMatchesTheServer() {
        let expected: [WorkItemStatus: Set<WorkItemStatus>] = [
            .open: [.triaged, .inProgress, .blocked, .closed, .canceled],
            .triaged: [.inProgress, .blocked, .closed, .canceled],
            .inProgress: [.triaged, .blocked, .closed, .canceled],
            .blocked: [.inProgress, .triaged, .closed, .canceled],
            .pendingReview: [.inProgress, .closed, .canceled],
            .resolved: [.inProgress, .closed],
            .closed: [],
            .canceled: [],
            .unknown: [],
        ]
        for status in WorkItemStatus.allCases {
            XCTAssertEqual(
                Set(status.allowedNext), expected[status],
                "transitions from \(status.rawValue) disagree with the server's table"
            )
        }
    }

    /// RESOLVED is not offered as a DESTINATION — the web retired it, and
    /// two clients disagreeing about a workflow is worse than either
    /// workflow. An operator marking a task Готова on the phone would have
    /// a state their colleague does not use on the laptop.
    func testResolvedIsNotOfferedAsADestination() {
        for status in WorkItemStatus.allCases {
            XCTAssertFalse(
                status.allowedNext.contains(.resolved),
                "\(status.rawValue) still offers RESOLVED"
            )
        }
    }

    /// But transitions OUT of it are kept. Rows already sit in that state,
    /// and a task that cannot be closed because the app declines to name
    /// where it is would be stranded by our own tidiness.
    func testATaskAlreadyResolvedCanStillBeMovedOn() {
        XCTAssertEqual(Set(WorkItemStatus.resolved.allowedNext), [.inProgress, .closed])
    }

    /// Exactly the three terminal statuses require a resolution, and the
    /// server checks it AFTER sanitising — so a resolution of pure markup is
    /// refused rather than stored as something that renders as nothing.
    func testOnlyTerminalStatusesRequireAResolution() {
        XCTAssertEqual(
            Set(WorkItemStatus.allCases.filter(\.requiresResolution)),
            [.resolved, .closed, .canceled]
        )
    }

    /// Every status an operator can be offered must have a Bulgarian label.
    /// A blank menu row is worse than a missing one.
    func testEveryOfferedStatusHasALabel() {
        for status in WorkItemStatus.allCases {
            for next in status.allowedNext {
                XCTAssertNotEqual(next.label, "—", "\(next.rawValue) has no label")
                XCTAssertFalse(next.label.isEmpty)
            }
        }
    }
}
