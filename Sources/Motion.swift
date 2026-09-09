import Cocoa

/// Every moving part of the menu asks this type three questions: whether to move at all, for how
/// long, and on what curve.
///
/// One gate, for one reason. Motion has to be switchable off in a single place — the system's
/// Reduce Motion setting, or the user's own pick under Options — and durations spread across six
/// files cannot be switched off at all. It is static state rather than a value threaded through
/// every view because the answer is the same for the whole app at any instant, and the views that
/// ask are built inside NSMenu callbacks with nowhere to carry it.
///
/// The budget every rule here defends: a CAAnimation is committed once and then interpolated by
/// the render server, so the process does no work per frame — that is why the toggle's spring
/// already plays during menu tracking (see ToggleView in MenuRows.swift). Nothing in this file may
/// introduce a Timer or a per-frame redraw. That, and not the number of animations, is what would
/// cost a menu bar app its battery.
enum Motion {

    // MARK: level

    enum Level: String, CaseIterable {
        case off, subtle, expressive

        var title: String {
            switch self {
            case .off:        return "Off"
            case .subtle:     return "Subtle"
            case .expressive: return "Expressive"
            }
        }

        /// What the row says under the name, so the choice can be made without trying all three.
        var detail: String {
            switch self {
            case .off:        return "No animation anywhere."
            case .subtle:     return "Cards, gauges and switches move. Rows appear at once."
            case .expressive: return "Adds a staggered entrance for the rows that have a view."
            }
        }
    }

    /// Set at launch from UserDefaults, and again whenever the user picks a level.
    static var level: Level = .subtle

    /// Read live rather than cached: it is a system setting the user can flip while the app runs,
    /// and an accessibility switch that needs a relaunch is not one that works.
    static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Anything at all, a plain crossfade included.
    static var enabled: Bool { level != .off }

    /// Movement specifically — scale, slide, spring. Reduce Motion drops these and keeps the
    /// crossfade, which is the rule Apple states for it: replace motion, do not remove the
    /// feedback that something changed.
    static var moves: Bool { enabled && !systemReducesMotion }

    /// Row-by-row entrances. Expressive only, and never under Reduce Motion. Ordinary menu items
    /// have no view to animate and arrive instantly, so a staggered list is always a mixture of
    /// moving and still rows — a deliberate taste, not a default.
    static var staggers: Bool { level == .expressive && !systemReducesMotion }

    /// How much longer or shorter than the spec every duration runs at the current level. Reduce
    /// Motion shortens what is left rather than removing it; Expressive is a touch slower, because
    /// a longer curve is what makes a flourish readable instead of a flicker.
    static var rate: Double {
        guard enabled else { return 0 }
        if systemReducesMotion { return 0.6 }
        return level == .expressive ? 1.25 : 1
    }

    static func time(_ base: Double) -> Double { base * rate }

    // MARK: builders

    static func fade(from: Float, to: Float, seconds: Double,
                     curve: CAMediaTimingFunctionName = .easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = time(seconds)
        a.timingFunction = CAMediaTimingFunction(name: curve)
        return a
    }

    static func move(_ keyPath: String, from: Any?, to: Any?, seconds: Double,
                     curve: CAMediaTimingFunctionName = .easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = time(seconds)
        a.timingFunction = CAMediaTimingFunction(name: curve)
        return a
    }

    /// The app's own switch spring — mass 1, stiffness 260, damping 16 — the values ToggleView
    /// shipped with. Every spring in the app is this one or its damped sibling below, so the
    /// moving parts read as facets of one object rather than six separate effects.
    static func spring(_ keyPath: String, damping: CGFloat = 16) -> CASpringAnimation {
        let s = CASpringAnimation(keyPath: keyPath)
        s.mass = 1
        s.stiffness = 260
        s.damping = damping
        s.initialVelocity = 0
        s.duration = s.settlingDuration * max(rate, 0.01)
        return s
    }

    /// The spring for anything that carries a number to its value: damping 26 against stiffness
    /// 260 is ζ ≈ 0.81, which lands without visible overshoot.
    ///
    /// That is a correctness requirement, not a taste. A 93% limit bar that flashes past 98% on
    /// its way up has told the reader something false about the one figure this app exists to
    /// report, and it does it in the frames they are most likely to be looking at.
    static func settle(_ keyPath: String) -> CASpringAnimation { spring(keyPath, damping: 26) }

    // MARK: highlight

    /// The menu's own highlight behaviour: on the instant the cursor lands, off on a short fade.
    ///
    /// The asymmetry is the whole point. A highlight that eases IN lags the cursor and makes the
    /// menu read as unresponsive — system menus do not do it, and neither should this one. The
    /// fade OUT is what stops a fast pass down a twenty-row MCP list from strobing.
    static func setHighlight(_ view: NSView, on: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            view.isHidden = !on
            return
        }
        layer.removeAnimation(forKey: "highlight")
        if on {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 1
            CATransaction.commit()
            view.isHidden = false
            return
        }
        guard enabled, !view.isHidden else {
            view.isHidden = true
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        let out = fade(from: from, to: 0, seconds: 0.09)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The model value carries the decision, so the completion block can tell "the fade
        // finished" from "the cursor came back and setHighlight(on: true) ran meanwhile" — the
        // latter reset opacity to 1, and hiding the view then would blink the highlight off
        // under a cursor that is still on the row.
        CATransaction.setCompletionBlock { [weak view, weak layer] in
            guard let view, let layer, layer.opacity == 0 else { return }
            view.isHidden = true
        }
        layer.opacity = 0
        layer.add(out, forKey: "highlight")
        CATransaction.commit()
    }

    // MARK: reveals

    /// Fades a card's contents in, in reading order: views sharing a line arrive together, each
    /// line a beat behind the one above it.
    ///
    /// Grouped by y rather than by subview index because a line is usually two views — a caption
    /// and the figure it labels — and 26ms between a label and its own number reads as a glitch
    /// rather than as a sequence.
    static func revealContents(of container: NSView) {
        guard enabled else { return }
        // A flipped container is built top-down, so its first line has the SMALLEST y; anywhere
        // else the first line has the largest. Sorting has to follow the container, not the
        // coordinate system.
        let flipped = container.isFlipped
        let lines = Dictionary(grouping: container.subviews) { view in
            Int((view.frame.minY / 4).rounded())
        }
        let order = flipped ? lines.keys.sorted() : lines.keys.sorted(by: >)
        for (step, key) in order.enumerated() {
            let delay = time(0.05) + Double(step) * time(0.026)
            for view in lines[key] ?? [] { reveal(view, delay: delay, flipped: flipped) }
        }
    }

    private static func reveal(_ view: NSView, delay: Double, flipped: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let start = CACurrentMediaTime() + delay
        let show = fade(from: 0, to: 1, seconds: 0.24)
        show.beginTime = start
        // .backwards holds the view at its FROM value until its turn comes; without it every
        // line is fully visible during its own delay and the stagger does not exist.
        show.fillMode = .backwards
        layer.add(show, forKey: "reveal")
        guard moves else { return }
        // "From below" in screen terms. A flipped superview puts +y downward, so the sign of a
        // 5pt offset is not a constant — it follows the container the card was built in.
        let rise = move("transform.translation.y", from: flipped ? 5 : -5, to: 0, seconds: 0.24)
        rise.beginTime = start
        rise.fillMode = .backwards
        layer.add(rise, forKey: "rise")
    }

    /// A row's entrance when the menu opens. Expressive only.
    ///
    /// The index comes from the menu rather than from the caller, because rows are built in five
    /// different places and none of them knows how many rows precede it. Past the cap the rows
    /// arrive together: twenty MCP rows staggered at 16ms each would still be arriving a third of
    /// a second after the menu was asked for, which is a menu that feels slow, not alive.
    static func enterMenu(_ view: NSView) {
        guard staggers, let item = view.enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let start = CACurrentMediaTime() + min(Double(index) * 0.016, 0.18)
        let show = fade(from: 0, to: 1, seconds: 0.23)
        show.beginTime = start
        show.fillMode = .backwards
        layer.add(show, forKey: "enter")
        // A row's layer sits in its SUPERVIEW's coordinate space, so it is the menu's flippedness
        // that decides which way is up here — not the row's own flag, which is false either way.
        let above: CGFloat = (view.superview?.isFlipped ?? false) ? -5 : 5
        let drop = move("transform.translation.y", from: above, to: 0, seconds: 0.23)
        drop.beginTime = start
        drop.fillMode = .backwards
        layer.add(drop, forKey: "enterDrop")
    }

    /// A card or banner arriving as a whole: it grows the last few percent into place rather than
    /// switching on. `origin` is the direction it comes from, in points — the card uses the side
    /// of the row it was opened under, so it appears to come out of that row.
    static func appear(_ layer: CALayer, from origin: CGPoint, scale: CGFloat = 0.96,
                       seconds: Double = 0.19) {
        layer.removeAnimation(forKey: "hide")
        layer.add(fade(from: 0, to: 1, seconds: seconds), forKey: "appear")
        guard moves else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(origin.x, origin.y, 0)))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = time(seconds)
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "grow")
    }
}

/// A capsule fill bar that runs up from zero the first time it is shown.
///
/// One type for the session card's context gauge and for the limit rows, because those two
/// already promised to agree: the width comes from `Gauge.fillWidth`, the same function the strip
/// beside the menu bar icon uses, one-device-pixel floor included. Only the way it arrives there
/// is new.
///
/// The fill is a plain colour layer inside a clipping capsule rather than a drawn path, and that
/// is what makes the animation free: a solid layer's width is interpolated by the render server
/// with no redraw at all, where the old `draw(_:)` bar would have had to be re-rendered on the
/// main thread on every frame of the fill.
final class MotionBar: NSView {
    /// 0...1. Assigning re-lays the fill without animating it — the run-up happens once, when the
    /// bar is first shown; a live figure moving under the cursor should just be correct.
    var value: Double {
        didSet {
            value = min(max(value, 0), 1)
            needsLayout = true
        }
    }

    /// Seconds to wait before running up, so a stack of bars can arrive in order.
    var revealDelay: Double = 0

    private let track = CALayer()
    private let fill = CALayer()
    private let fillColor: NSColor
    private let trackColor: NSColor
    private var revealed = false

    init(value: Double, fill: NSColor, track: NSColor, height: CGFloat, width: CGFloat) {
        self.value = min(max(value, 0), 1)
        self.fillColor = fill
        self.trackColor = track
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // Layer-hosted, like ToggleView: nothing here draws, so nothing needs a backing store.
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = height / 2
        // Anchored at its left edge, which is what makes `bounds.size.width` grow rightward
        // instead of outward from the middle.
        self.fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(self.track)
        layer?.addSublayer(self.fill)
        applyColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func filledWidth() -> CGFloat {
        Gauge.fillWidth(value, trackWidth: bounds.width, scale: window?.backingScaleFactor ?? 2)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        // Layout is not an animation. Without this the implicit actions on frame and bounds turn
        // every menu resize and every appearance change into a quarter-second slide.
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        track.frame = bounds
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: filledWidth(), height: bounds.height)
        CATransaction.commit()
    }

    /// A dynamic NSColor latches whatever appearance is current when `.cgColor` is read, and the
    /// menu is not obliged to agree with the app — the same trap ToggleView documents, and the
    /// reason both colours are re-resolved here rather than kept as CGColors.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = trackColor.cgColor
            fill.backgroundColor = fillColor.cgColor
        }
    }

    /// Moves an already-visible bar to a new value. The update banner needs it: its figure
    /// changes while the menu is open, and a bar that jumped between readings would read as a
    /// glitch rather than as progress. Linear, not sprung — a download is not a physical object,
    /// and a spring here would overshoot past a percentage that has not happened yet.
    func setValue(_ new: Double, animated: Bool) {
        let clamped = min(max(new, 0), 1)
        guard clamped != value else { return }
        let from = fill.presentation()?.bounds.width ?? fill.bounds.width
        value = clamped
        layoutSubtreeIfNeeded()
        guard animated, Motion.enabled, revealed else { return }
        let grow = Motion.move("bounds.size.width", from: from, to: fill.bounds.width,
                               seconds: 0.9, curve: .linear)
        fill.add(grow, forKey: "fill")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !revealed else { return }
        revealed = true
        // The fill needs its final width before it has something to grow into, and that width is
        // set by the SUPERVIEW's layout — a limit row shortens its bar when there is a reset time
        // to the right of it. Laying out only this view would animate toward the width the bar was
        // constructed with, and the row would then resize it out from under the animation.
        (superview ?? self).layoutSubtreeIfNeeded()
        let target = fill.bounds.width
        guard Motion.moves, target > 0 else { return }
        let grow = Motion.settle("bounds.size.width")
        grow.fromValue = 0
        grow.toValue = target
        grow.beginTime = CACurrentMediaTime() + Motion.time(revealDelay)
        grow.fillMode = .backwards
        fill.add(grow, forKey: "fill")
    }
}
