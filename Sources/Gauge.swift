import Cocoa

/// The two numbers worth a glance without opening anything: how much of the 5-hour limit is gone,
/// and how much of the weekly one. Each bar is labelled, because an unlabelled pair of bars only
/// says "something is filling up".
///
/// Context deliberately does NOT appear here. It is per session, and someone can have ten
/// sessions open — there is no single honest number to draw, and picking the busiest one would
/// be a figure that jumps between projects for no visible reason. Context lives in the menu,
/// on the row of the session it belongs to. Limits are per account, so one bar is the truth.
struct Gauge {
    var fiveHour: Double?
    var sevenDay: Double?

    var rows: [(String, Double)] {
        [("5h", fiveHour), ("7d", sevenDay)].compactMap { label, value in
            value.map { (label, $0) }
        }
    }
    var isEmpty: Bool { rows.isEmpty }

    // Geometry is the width budget, so it lives in one place. The menu bar is not elastic: an
    // item that does not fit is not clipped, it is parked off-screen behind the overflow
    // chevron. Labelled bars cost about 45pt beside the icon.
    static let barW: CGFloat = 20, barH: CGFloat = 3
    static let labelW: CGFloat = 15, labelGap: CGFloat = 3
    static let rowH: CGFloat = 9, rowGap: CGFloat = 2
    static let sideInset: CGFloat = 3, iconGap: CGFloat = 5
    /// Ceiling, not a fixed size: the crab frames are wider than tall and must keep their shape.
    static let iconMaxW: CGFloat = 28

    static func level(_ value: Double) -> NSColor? {
        // nil means "neutral": nothing alarming, so the whole image can stay a template and
        // behave like every other menu bar icon — light on a dark bar, dark on a light one.
        if value >= 0.90 { return NSColor(srgbRed: 0.90, green: 0.25, blue: 0.20, alpha: 1) }
        if value >= 0.75 { return NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1) }
        return nil
    }

    /// `icon` is the icon the app was about to show anyway — a spark frame, a crab frame, or the
    /// amber "awaiting permission" dot — used as an alpha mask exactly as tint(_:color:frame:) does.
    ///
    /// Neutral parts are painted with NSColor.labelColor rather than a hand-picked black or
    /// white, and that is the whole trick. There is no reliable way to ask "is the menu bar
    /// dark": the bar is translucent over the wallpaper, and two independent measurements of
    /// statusItem.button.effectiveAppearance on the same dark bar disagreed — one read
    /// VibrantLight, and it flips to VibrantDark merely because the menu is open and the item is
    /// highlighted. A dynamic colour dodges the question: it resolves at draw time, against
    /// whatever appearance the menu bar is actually drawing in.
    func image(icon: NSImage?) -> NSImage {
        let shown = rows
        let h = NSStatusBar.system.thickness
        // The icon keeps its own aspect: crab frames are 25.5x18, and forcing them into an 18pt
        // square squeezes them by 29%.
        let iconSize = icon.map { NSSize(width: min($0.size.width, Gauge.iconMaxW),
                                         height: min($0.size.height, h)) } ?? .zero
        let strip = Gauge.labelW + Gauge.labelGap + Gauge.barW
        let w = Gauge.sideInset * 2 + (icon != nil ? iconSize.width + Gauge.iconGap : 0) + strip
        // One coloured bar makes the whole image non-template: the system tints a template by
        // alpha alone, so a hue cannot survive in one.
        let template = shown.allSatisfy { Gauge.level($0.1) == nil }
        let blockH = CGFloat(shown.count) * Gauge.rowH
            + CGFloat(max(shown.count - 1, 0)) * Gauge.rowGap
        let y0 = ((h - blockH) / 2).rounded()   // whole points: crisp at 1x, 2x and 3x alike
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            var x = Gauge.sideInset
            if let icon {
                let box = NSRect(x: x, y: ((h - iconSize.height) / 2).rounded(),
                                 width: iconSize.width, height: iconSize.height)
                if template {
                    // Alpha is all the system will read, so draw the frame as-is and let it ink.
                    icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                } else {
                    NSColor.labelColor.setFill()
                    box.fill()
                    icon.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
                }
                x += iconSize.width + Gauge.iconGap
            }
            // Top row first: 5h above 7d, the same order the menu lists them in.
            for (i, row) in shown.enumerated() {
                let y = y0 + CGFloat(shown.count - 1 - i) * (Gauge.rowH + Gauge.rowGap)
                let colour = Gauge.level(row.1)
                NSAttributedString(string: row.0, attributes: [
                    .font: font,
                    .foregroundColor: colour ?? NSColor.labelColor.withAlphaComponent(0.65),
                ]).draw(at: NSPoint(x: x, y: y))

                let barX = x + Gauge.labelW + Gauge.labelGap
                let barY = y + ((Gauge.rowH - Gauge.barH) / 2).rounded()
                let radius = Gauge.barH / 2
                NSColor.labelColor.withAlphaComponent(0.30).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: Gauge.barW,
                                                 height: Gauge.barH),
                             xRadius: radius, yRadius: radius).fill()
                (colour ?? NSColor.labelColor).setFill()
                let filled = max(Gauge.barH,
                                 (Gauge.barW * CGFloat(min(max(row.1, 0), 1)) * 2).rounded() / 2)
                NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: filled,
                                                 height: Gauge.barH),
                             xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = template
        // Drawn bars carry no text the system can read, so without this the item is silent to
        // VoiceOver — a regression against the plain label it replaces.
        image.accessibilityDescription = shown
            .map { "\($0.0 == "5h" ? "5 hour" : "7 day") limit \(Int(($0.1 * 100).rounded()))%" }
            .joined(separator: ", ")
        return image
    }
}
