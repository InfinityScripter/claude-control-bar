import Cocoa

/// One limit window as a menu row, in two tiers: the name and the figure on the first line,
/// a full-width capsule bar with the reset countdown under them. Stacked rather than inline
/// because the menu is 300pt wide: a bar that shares its line with a name, a figure and a time
/// gets 64pt, and 6% of 64pt is a dot. The whole width makes the three windows comparable at
/// a glance, which is the point of drawing bars instead of printing numbers.
///
/// The fill is the same honest one the menu bar gauge draws (Gauge.fillWidth): straight-edged,
/// clipped by the capsule, one device pixel floor above zero — so the row in the menu and the
/// strip beside the icon never disagree about what a small value looks like.
final class LimitRowView: NSView {
    static let rowH: CGFloat = 38
    private static let pad: CGFloat = 14, barH: CGFloat = 6
    private static let lineY: CGFloat = 20, barY: CGFloat = 8, resetW: CGFloat = 78

    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let reset = NSTextField(labelWithString: "")
    private let value: Double
    private let accent: NSColor?

    /// `accent` is the neutral fill. nil draws label ink like the menu bar gauge; the Fable row
    /// hands in a tint so the model's window is told apart from the account's two at a glance.
    /// A warning level (75%, 90%) overrides it for every row: the colour of "nearly out" has to
    /// mean one thing across the section.
    init(title text: String, badge tag: String?, used: Int, resets: String?, accent: NSColor?, width: CGFloat) {
        value = Double(used) / 100
        self.accent = accent
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowH))
        autoresizingMask = [.width]

        let level = Gauge.level(value)
        title.stringValue = text
        title.font = .menuFont(ofSize: 0)
        title.textColor = .labelColor
        title.sizeToFit()
        title.setFrameOrigin(NSPoint(x: Self.pad, y: Self.lineY - 1))
        addSubview(title)

        // A tiny capsule after the name: the Fable window is a weekly one, and the row would
        // otherwise read as a third, unrelated kind of limit next to "7 days".
        if let tag {
            badge.stringValue = tag
            badge.font = .systemFont(ofSize: 9, weight: .semibold)
            badge.textColor = accent ?? .secondaryLabelColor
            badge.sizeToFit()
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = (accent ?? NSColor.labelColor).withAlphaComponent(0.14).cgColor
            badge.alignment = .center
            let bw = badge.frame.width + 8, bh = badge.frame.height + 1
            badge.frame = NSRect(x: title.frame.maxX + 5,
                                 y: title.frame.midY - bh / 2, width: bw, height: bh)
            addSubview(badge)
        }

        percent.stringValue = "\(used)%"
        percent.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percent.textColor = level ?? .labelColor
        percent.alignment = .right
        percent.frame = NSRect(x: width - Self.pad - 48, y: Self.lineY - 1, width: 48, height: 16)
        percent.autoresizingMask = [.minXMargin]
        addSubview(percent)

        // A glyph instead of "resets in": the arrow beside a duration reads the way the battery
        // menu's "until full" does, and leaves the line to the bar.
        reset.stringValue = resets.map { "\u{21BB} \($0)" } ?? ""
        reset.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right
        reset.frame = NSRect(x: width - Self.pad - Self.resetW, y: Self.barY - 4,
                             width: Self.resetW, height: 13)
        reset.autoresizingMask = [.minXMargin]
        addSubview(reset)

        // Screen readers get the sentence the bar draws.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([text, tag, "\(used)% used", resets.map { "resets in \($0)" }]
            .compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // The bar stops short of the reset time when there is one; a window with no known
        // reset takes the whole width rather than leaving a gap that reads as a missing label.
        let trailing = reset.stringValue.isEmpty ? 0 : Self.resetW + 8
        let x = Self.pad, w = bounds.width - Self.pad * 2 - trailing
        let y = Self.barY - Self.barH / 2 + 2
        let radius = Self.barH / 2
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: Self.barH),
                                 xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        track.fill()
        let scale = window?.backingScaleFactor ?? 2
        let filled = Gauge.fillWidth(value, trackWidth: w, scale: scale)
        guard filled > 0 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        track.setClip()
        (Gauge.level(value) ?? accent ?? NSColor.labelColor.withAlphaComponent(0.85)).setFill()
        NSRect(x: x, y: y, width: filled, height: Self.barH).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
