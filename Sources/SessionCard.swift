import Cocoa

// Hover card for a session row: what the one-line row cannot carry. The row keeps its shape;
// the card shows the branch with its uncommitted count, the context gauge with real token
// figures, and the session totals (cost, wall time, lines changed) when a status line
// captured them. Every block is optional and simply absent when its data is — a desktop-app
// session has no totals, a directory outside git has no branch.
enum SessionCard {
    static let width: CGFloat = 340
    private static let inner = width - HoverCard.pad * 2

    struct Content {
        var name: String, model: String, branch: String, dirty: Int?
        var pct: Int?, tokens: Int?, window: Int?, assumed: Bool
        var cost: Double?, duration: Int?, linesAdded: Int?, linesRemoved: Int?
        var cwd: String
    }

    static func show(_ content: Content, near row: NSView) {
        HoverCard.shared.show(near: row, width: width) { body(content) }
    }

    // Built bottom-up in a flipped container so the reading order in code is the reading order
    // on screen: y grows downward as blocks are appended.
    static func body(_ c: Content) -> NSView {
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: inner, height: 0))
        var y: CGFloat = 0

        // Title row: project name left, model right.
        let title = label(c.name, font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        title.lineBreakMode = .byTruncatingTail
        let model = label(SessionFormat.prettyModel(c.model), font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                          color: .tertiaryLabelColor)
        let modelW = model.frame.width
        title.frame = NSRect(x: 0, y: y, width: max(60, inner - modelW - 8), height: 18)
        model.frame.origin = NSPoint(x: inner - modelW, y: y + 3)
        view.addSubview(title); view.addSubview(model)
        y += 20

        if !c.branch.isEmpty {
            let text = NSMutableAttributedString(string: "⎇ " + c.branch, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            if let dirty = c.dirty, dirty > 0 {
                text.append(NSAttributedString(
                    string: " · \(dirty) uncommitted " + (dirty == 1 ? "file" : "files"),
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange]))
            }
            let line = NSTextField(labelWithAttributedString: text)
            line.lineBreakMode = .byTruncatingTail
            line.frame = NSRect(x: 0, y: y, width: inner, height: 16)
            view.addSubview(line)
            y += 20
        }

        if let pct = c.pct {
            y += 2
            let caption = label("Context", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            caption.frame.origin = NSPoint(x: 0, y: y)
            var figure = (c.assumed ? "~" : "") + "\(pct)%"
            if let tokens = c.tokens, let window = c.window {
                figure += " · \(SessionFormat.compact(tokens)) of \(SessionFormat.compact(window))"
            }
            let value = label(figure, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                              color: .secondaryLabelColor)
            value.frame.origin = NSPoint(x: inner - value.frame.width, y: y)
            view.addSubview(caption); view.addSubview(value)
            y += 20
            // Same thresholds as the row's percentage: green until three quarters, then amber,
            // then red. The width now comes from Gauge.fillWidth by way of MotionBar, so this bar
            // and the strip beside the menu bar icon agree about what a small value looks like.
            let tint: NSColor = pct >= 90 ? .systemRed : (pct >= 75 ? .systemOrange : .systemGreen)
            let bar = MotionBar(value: Double(max(0, min(100, pct))) / 100, fill: tint,
                                track: .quaternaryLabelColor, height: 4, width: inner)
            // A beat behind the card itself, so the run-up is watched rather than spent behind a
            // card that is still fading in.
            bar.revealDelay = 0.16
            bar.setFrameOrigin(NSPoint(x: 0, y: y))
            bar.setAccessibilityLabel("Context \(pct)%")
            view.addSubview(bar)
            y += 16
        }

        if let cost = c.cost, let duration = c.duration {
            y += 2
            var cells: [(String, NSAttributedString)] = [
                ("Cost", mono(String(format: "$%.2f", cost), color: .labelColor)),
                ("Duration", mono(SessionFormat.elapsed(duration), color: .labelColor)),
            ]
            if let added = c.linesAdded, let removed = c.linesRemoved, added + removed > 0 {
                let lines = NSMutableAttributedString(attributedString: mono("+\(added)", color: .systemGreen))
                lines.append(NSAttributedString(string: " "))
                lines.append(mono("−\(removed)", color: .systemRed))
                cells.append(("Lines", lines))
            }
            let colW = inner / CGFloat(cells.count)
            for (i, cell) in cells.enumerated() {
                let x = colW * CGFloat(i)
                let caption = label(cell.0.uppercased(), font: .systemFont(ofSize: 10, weight: .medium),
                                    color: .tertiaryLabelColor)
                caption.frame.origin = NSPoint(x: x, y: y)
                let value = NSTextField(labelWithAttributedString: cell.1)
                value.sizeToFit()
                value.frame.origin = NSPoint(x: x, y: y + 13)
                view.addSubview(caption); view.addSubview(value)
            }
            y += 34
        }

        if !c.cwd.isEmpty {
            let home = NSHomeDirectory()
            let shown = c.cwd.hasPrefix(home) ? "~" + c.cwd.dropFirst(home.count) : c.cwd
            let path = label(shown, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                             color: .tertiaryLabelColor)
            path.lineBreakMode = .byTruncatingMiddle
            path.frame = NSRect(x: 0, y: y + 2, width: inner, height: 14)
            view.addSubview(path)
            y += 16
        }

        view.frame.size.height = y
        return view
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.sizeToFit()
        return field
    }

    private static func mono(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: color,
        ])
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
