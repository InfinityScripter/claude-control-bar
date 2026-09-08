import Cocoa

/// One limit window as a menu row: name on the left, a capsule bar in the middle, the figure and
/// the reset time on the right. A bar, because the three windows are read as a set — "which one
/// is filling up" is a glance at three fills, and three numbers in a column need reading.
///
/// The bar is the same honest fill the menu bar gauge draws (Gauge.fillWidth): straight-edged,
/// clipped by the capsule, one device pixel floor above zero — so the row in the menu and the
/// strip beside the icon never disagree about what 18% looks like.
final class LimitRowView: NSView {
    static let rowH: CGFloat = 26
    // The width budget is the default 300pt box: 14 + 72 + 8 + 64 + 8 + 36 + 8 leaves 76pt for
    // the reset time, enough for "↻ 76h 12m" at 11pt. A longer bar looked better on its own
    // and pushed the reset time into an ellipsis on every row.
    private static let pad: CGFloat = 14, barW: CGFloat = 64, barH: CGFloat = 5
    private static let titleW: CGFloat = 72, pctW: CGFloat = 36, gap: CGFloat = 8

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
        let h = Self.rowH
        title.stringValue = text
        title.font = .menuFont(ofSize: 0)
        title.textColor = .labelColor
        title.sizeToFit()
        title.setFrameOrigin(NSPoint(x: Self.pad, y: (h - title.frame.height) / 2))
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
            badge.frame = NSRect(x: title.frame.maxX + 5, y: ((h - bh) / 2).rounded(), width: bw, height: bh)
            addSubview(badge)
        }

        percent.stringValue = "\(used)%"
        percent.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percent.textColor = level ?? .labelColor
        percent.alignment = .right
        percent.frame = NSRect(x: Self.pad + Self.titleW + Self.gap + Self.barW + Self.gap,
                               y: (h - 16) / 2, width: Self.pctW, height: 16)
        addSubview(percent)

        // A glyph instead of "resets in": the words cost 50pt the row does not have, and the
        // arrow beside a duration reads the same way the battery menu's "until full" does.
        reset.stringValue = resets.map { "\u{21BB} \($0)" } ?? ""
        reset.font = .systemFont(ofSize: 11)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right
        reset.lineBreakMode = .byTruncatingTail
        let rx = percent.frame.maxX + Self.gap
        reset.frame = NSRect(x: rx, y: (h - 14) / 2, width: max(width - rx - Self.pad, 0), height: 14)
        reset.autoresizingMask = [.width]
        addSubview(reset)

        // Screen readers get the sentence the bar draws.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([text, tag, "\(used)% used", resets.map { "resets in \($0)" }]
            .compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let x = Self.pad + Self.titleW + Self.gap
        let y = ((Self.rowH - Self.barH) / 2).rounded()
        let radius = Self.barH / 2
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: Self.barW, height: Self.barH),
                                 xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        track.fill()
        let scale = window?.backingScaleFactor ?? 2
        let filled = Gauge.fillWidth(value, trackWidth: Self.barW, scale: scale)
        guard filled > 0 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        track.setClip()
        (Gauge.level(value) ?? accent ?? NSColor.labelColor.withAlphaComponent(0.85)).setFill()
        NSRect(x: x, y: y, width: filled, height: Self.barH).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
