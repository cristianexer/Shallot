import CoreGraphics
import Foundation

/// Decides when the browser chrome should get out of the way.
///
/// Reading a long page should give the page the whole screen; reaching for the
/// address bar should bring it straight back. The awkward part is everything in
/// between — rubber-banding at the top, a page shorter than the viewport, the
/// small wobble at the end of an inertial scroll — each of which would make a
/// naive "hide on any downward movement" rule flicker.
///
/// Kept as pure arithmetic so those cases are unit-tested rather than
/// discovered by scrolling around and hoping.
public enum ChromeVisibilityPolicy {
    /// How far the page must travel before the chrome moves at all.
    ///
    /// Large enough to absorb an inertial wobble, small enough that a
    /// deliberate flick is obeyed immediately.
    public static let threshold: CGFloat = 28

    /// Above this point the chrome is always shown: near the top there is
    /// nothing to gain by hiding it.
    public static let alwaysVisibleOffset: CGFloat = 60

    /// A page must exceed the viewport by this much before it can hide anything.
    public static let scrollableSlack: CGFloat = 80

    /// What to do about the chrome, given where the page is now.
    public struct Decision: Equatable, Sendable {
        /// The new visibility, or `nil` to leave it as it is.
        public var isVisible: Bool?
        /// The offset to measure the next decision from, or `nil` to keep the
        /// current anchor.
        public var anchor: CGFloat?

        public static let unchanged = Decision(isVisible: nil, anchor: nil)
    }

    /// - Parameters:
    ///   - offset: Current scroll offset, already adjusted for the content inset,
    ///     so 0 is the top of the page.
    ///   - anchor: The offset the last decision was taken at.
    ///   - contentHeight: Height of the page.
    ///   - viewportHeight: Height of the visible area.
    public static func decide(
        offset: CGFloat,
        anchor: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> Decision {
        // A page that barely fills the screen must never be able to take the
        // address bar away — there would be no way to scroll back up for it.
        let isScrollable = contentHeight > viewportHeight + scrollableSlack
        guard isScrollable, offset > alwaysVisibleOffset else {
            return Decision(isVisible: true, anchor: offset)
        }

        let travelled = offset - anchor
        guard abs(travelled) > threshold else { return .unchanged }
        // Moving down the page hides; moving back up shows.
        return Decision(isVisible: travelled < 0, anchor: offset)
    }
}
