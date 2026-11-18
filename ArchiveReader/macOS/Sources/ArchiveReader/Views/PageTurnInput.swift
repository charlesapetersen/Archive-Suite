import AppKit

/// W40.reader-page-nav (owner's Reader notes, 2026-11-17): next and previous page from the trackpad and the plain
/// arrow keys, not only ⌘⇧↑ / ⌘⇧↓. ← / → turn the page when the page fits or the pan has reached that edge; a
/// horizontal swipe turns it; and a scroll that keeps pushing past an edge the page already sat at turns it.
/// A zoomed page still pans: a scroll or arrow that has somewhere to go moves the view, never the page.
enum PageEdge: CaseIterable {
    case top, bottom, left, right

    /// Pushing past the bottom or right edge reads on; the top or left reads back.
    var isNext: Bool { self == .bottom || self == .right }

    /// The edge a scroll delta pushes toward along its dominant axis. AppKit's scrolling deltas are what the
    /// scroll view applies: positive y shows more of the top, positive x more of the left. Nil for no movement.
    static func pushed(dx: CGFloat, dy: CGFloat) -> PageEdge? {
        if abs(dy) >= abs(dx) {
            return dy > 0 ? .top : (dy < 0 ? .bottom : nil)
        }
        return dx > 0 ? .left : .right
    }

    /// The edges `clip` has scrolled to: a point further that way is clamped back. A page that fits is at all
    /// four. A trackpad's elastic overshoot carries the bounds past the edge, and still counts as at it.
    @MainActor static func reached(by clip: NSClipView) -> Set<PageEdge> {
        let visible = clip.bounds
        var edges: Set<PageEdge> = []
        for edge in allCases {
            let step: CGVector
            switch edge {
            case .left: step = CGVector(dx: -1, dy: 0)
            case .right: step = CGVector(dx: 1, dy: 0)
            case .top: step = CGVector(dx: 0, dy: clip.isFlipped ? -1 : 1)
            case .bottom: step = CGVector(dx: 0, dy: clip.isFlipped ? 1 : -1)
            }
            let probe = visible.offsetBy(dx: step.dx, dy: step.dy)
            let clamped = clip.constrainBoundsRect(probe).origin
            let moved = (clamped.x - visible.minX) * step.dx + (clamped.y - visible.minY) * step.dy
            if moved < 0.5 { edges.insert(edge) }
        }
        return edges
    }
}

/// Reads one pane's scroll-wheel events and says when they turn the page. Pure state, so it is tested without a
/// trackpad; the view passes each event's phase, deltas and the edges its clip view sits at.
///
/// A trackpad gesture turns the page only when the page was ALREADY at that edge as the fingers went down, and
/// once it has pushed `overscroll` points past it: a scroll that pans a zoomed page to its edge stops there, and
/// the next gesture turns. After the turn the rest of the gesture and its momentum are swallowed, so one swipe is
/// one page. A pane rebuilt mid-gesture never saw it begin, so it only scrolls. A mouse wheel has no phases: a
/// run of clicks (no gap over `wheelRunGap`) that starts at an edge turns once and swallows the rest of the run.
struct PageTurnScroll {
    enum Outcome: Equatable { case scroll, swallow, turn(next: Bool) }

    static let overscroll: CGFloat = 60
    static let wheelRunGap: TimeInterval = 0.3

    private var startEdges: Set<PageEdge>?   // nil = no gesture seen beginning here
    private var pushed: CGFloat = 0
    private var turned = false
    private var lastWheel: TimeInterval = -.infinity
    private var wheelEdges: Set<PageEdge> = []

    mutating func handle(phase: NSEvent.Phase, momentum: NSEvent.Phase, dx: CGFloat, dy: CGFloat,
                         time: TimeInterval, edges: Set<PageEdge>) -> Outcome {
        if !momentum.isEmpty { return turned ? .swallow : .scroll }
        if phase.isEmpty { return wheel(dx: dx, dy: dy, time: time, edges: edges) }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            startEdges = edges
            pushed = 0
            turned = false
            return .scroll
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            startEdges = nil
            return turned ? .swallow : .scroll
        }
        guard !turned else { return .swallow }
        guard let start = startEdges, let edge = PageEdge.pushed(dx: dx, dy: dy),
              start.contains(edge), edges.contains(edge) else { pushed = 0; return .scroll }
        pushed += max(abs(dx), abs(dy))
        guard pushed >= Self.overscroll else { return .scroll }
        turned = true
        return .turn(next: edge.isNext)
    }

    private mutating func wheel(dx: CGFloat, dy: CGFloat, time: TimeInterval, edges: Set<PageEdge>) -> Outcome {
        if time - lastWheel > Self.wheelRunGap {
            wheelEdges = edges
            turned = false
        }
        lastWheel = time
        guard !turned else { return .swallow }
        guard let edge = PageEdge.pushed(dx: dx, dy: dy), wheelEdges.contains(edge), edges.contains(edge) else {
            return .scroll
        }
        turned = true
        return .turn(next: edge.isNext)
    }
}

extension NSEvent {
    /// ← or → with no modifier (the arrow keys carry the numeric-pad and function flags, Caps Lock is ignored):
    /// `true` for →, `false` for ←, nil for anything else.
    var plainHorizontalArrow: Bool? {
        guard type == .keyDown, let key = charactersIgnoringModifiers?.unicodeScalars.first,
              modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock]).isEmpty else { return nil }
        switch Int(key.value) {
        case NSRightArrowFunctionKey: return true
        case NSLeftArrowFunctionKey: return false
        default: return nil
        }
    }

    /// A horizontal swipe (the trackpad's swipe-between-pages gesture when it is set to three fingers, which
    /// AppKit delivers as `swipe(with:)`): fingers moving left read on. Nil for a vertical swipe.
    var swipeTurnsToNext: Bool? {
        guard type == .swipe, deltaX != 0 else { return nil }
        return deltaX < 0
    }
}
