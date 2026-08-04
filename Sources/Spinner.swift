import Cocoa

/// The turning arc on a row whose state is being worked out right now.
///
/// Drawn rather than dropped in as an NSProgressIndicator, for the reason every other moving part
/// of this menu is hand-driven: a menu tracks in NSEventTrackingRunLoopMode, and the only timers
/// certain to keep firing there are the ones we add to .common ourselves. A spinner that freezes
/// the moment the menu opens is worse than no spinner.
final class SpinnerView: NSView {
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    private var phase: CGFloat = 0
    private var timer: Timer?

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setActive(_ on: Bool) {
        isHidden = !on
        if on, window != nil { start() } else if !on { stop() }
    }

    // The menu closing is the one event that always arrives — mouseExited does not — so it is what
    // stops the timer. Otherwise it would keep ticking against a view nobody can see.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if !isHidden { start() }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase -= .pi / 8   // clockwise
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 1.7
        let radius = min(bounds.width, bounds.height) / 2 - width
        guard radius > 0 else { return }
        let start = phase * 180 / .pi
        let path = NSBezierPath()
        path.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                       startAngle: start, endAngle: start + 280)
        path.lineWidth = width
        path.lineCapStyle = .round
        tint.setStroke()
        path.stroke()
    }
}
