import Cocoa

// Custom-drawn toggle. NSSwitch can't show its accent inside a menu (the menu's vibrant, non-key
// window draws the implicit accent gray), so we render the track + knob as layers and fill the
// "on" color explicitly. Layer-hosted so the knob can slide on Apple's switch spring (CASpringAnimation),
// with the track color crossfading; CA animations run in the render server, so they play during menu tracking.
final class ToggleView: NSView {
    static let w: CGFloat = 33, h: CGFloat = 16
    private let track = CALayer()
    private let knob = CALayer()
    private var lastToggle = Date.distantPast   // debounce: ignore a re-click within a short window
    private var hovered = false
    var isOn: Bool { didSet { updateState(animated: true) } }
    var onToggle: ((Bool) -> Void)?
    /// A switch on a row that cannot act (the tools of a server the user just turned off) still
    /// has to render, just not respond.
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: ToggleView.w, height: ToggleView.h))
        layer = CALayer()
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)
        let kh = bounds.height - 4, kw = kh + 3   // capsule: a touch wider than tall, like modern macOS
        knob.bounds = CGRect(x: 0, y: 0, width: kw, height: kh)
        knob.cornerRadius = kh / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: ToggleView.w, height: ToggleView.h) }

    private func knobCenter() -> CGPoint {
        let kw = knob.bounds.width
        return CGPoint(x: isOn ? bounds.width - kw / 2 - 2 : kw / 2 + 2, y: bounds.height / 2)
    }

    // Track fill. ON = accent. OFF = an explicit mid gray (the system's faint off color disappears on a
    // light menu, and a dynamic NSColor's .cgColor can latch the wrong appearance → white-on-white), so
    // pick black-on-light / white-on-dark from our OWN effectiveAppearance. Hover nudges it darker.
    private func trackColor() -> CGColor {
        if isOn {
            let accent = NSColor.controlAccentColor
            return (hovered ? (accent.blended(withFraction: 0.10, of: .white) ?? accent) : accent).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: CGFloat = dark ? 1.0 : 0.0
        let alpha: CGFloat = (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0)
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func updateState(animated: Bool) {
        let toColor = trackColor()
        let toPos = knobCenter()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 16; spring.stiffness = 260; spring.mass = 1; spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")
            let col = CABasicAnimation(keyPath: "backgroundColor")
            col.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            col.toValue = toColor
            col.duration = 0.2
            track.add(col, forKey: "backgroundColor")
        }
        knob.position = toPos
        track.backgroundColor = toColor
        CATransaction.commit()
    }

    // Recolor when the view actually lands in the menu (its effectiveAppearance only resolves to the
    // menu's light/dark then, not at init), so the off gray matches the menu it's drawn on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateState(animated: false) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState(animated: false) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

// A session row as a custom view so a flexible spacer can pin the timer + pill to the true trailing
// edge (a plain menu-item title can't cross the menu's reserved shortcut/submenu-arrow column).
// Layout: [icon] name  <spacer>  timer  [pill], with timer+pill pinned right via autoresizing.
final class SessionRowView: NSView {
    let id: String
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameField = NSTextField(labelWithString: "")
    private let timerField = NSTextField(labelWithString: "")
    // How full this session's context window is. Its own field rather than a suffix on the name,
    // because it has to stay put while the name truncates and the timer appears and vanishes.
    private let contextField = NSTextField(labelWithString: "")
    private let pillView = NSImageView()
    private let pad: CGFloat = 14, iconSize: CGFloat = 16, rowH: CGFloat = 24
    private let highlightView = NSVisualEffectView()  // system selection material = exact native highlight
    private var hovered = false
    private var iconBaseTint: NSColor?       // tint when not hovered (template icons); white on hover
    private var contextBase: NSColor = .secondaryLabelColor  // green/amber/red by fill, white on hover
    private var pillNormal: NSImage?, pillSelected: NSImage?
    private var nameText = "", branchText = ""

    init(id: String, width: CGFloat) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        iconView.frame = NSRect(x: pad, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.maxXMargin]
        addSubview(iconView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        let spinSize = iconSize * 0.9
        spinner.frame = NSRect(x: pad + (iconSize - spinSize) / 2, y: (rowH - spinSize) / 2, width: spinSize, height: spinSize)
        spinner.autoresizingMask = [.maxXMargin]
        spinner.isHidden = true
        addSubview(spinner)
        nameField.font = .menuFont(ofSize: 0)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: pad + iconSize + 8, y: (rowH - 16) / 2, width: 160, height: 16)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)
        timerField.font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        timerField.textColor = .secondaryLabelColor
        timerField.alignment = .right
        timerField.autoresizingMask = [.minXMargin]
        addSubview(timerField)
        contextField.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.menuFont(ofSize: 0).pointSize - 1, weight: .regular)
        contextField.alignment = .right
        contextField.autoresizingMask = [.minXMargin]
        addSubview(contextField)
        pillView.imageScaling = .scaleNone
        pillView.autoresizingMask = [.minXMargin]
        addSubview(pillView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon: NSImage?, iconTint: NSColor?, spinning: Bool, name: String, branch: String, timer: String?,
                   context: Int?, contextAssumed: Bool,
                   pillNormal: NSImage?, pillSelected: NSImage?, pillInset: CGFloat, timerGap: CGFloat) {
        let w = bounds.width
        iconView.image = icon
        iconBaseTint = iconTint
        iconView.contentTintColor = hovered ? .white : iconTint
        if spinning {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
        }
        nameText = name; branchText = branch
        renderName()
        self.pillNormal = pillNormal; self.pillSelected = pillSelected
        let pill = hovered ? pillSelected : pillNormal
        var pillLeft = w - pillInset
        if let pill = pill {
            pillView.isHidden = false
            pillView.image = pill
            pillView.frame = NSRect(x: w - pillInset - pill.size.width, y: (rowH - pill.size.height) / 2,
                                    width: pill.size.width, height: pill.size.height)
            pillLeft = pillView.frame.minX
        } else { pillView.isHidden = true }
        // Laid out right to left: pill, then context, then timer, then whatever is left over goes
        // to the name. Context sits inboard of the pill so it holds one column across all rows
        // while the timer comes and goes with the turn.
        if let context {
            contextField.isHidden = false
            // "~" marks a percentage computed against a window size that was inferred rather
            // than known — better than quietly presenting a guess as a measurement.
            contextField.stringValue = (contextAssumed ? "~" : "") + "\(context)%"
            contextBase = context >= 90 ? .systemRed
                : (context >= 75 ? .systemOrange : .secondaryLabelColor)
            contextField.textColor = hovered ? .white : contextBase
            let font = contextField.font ?? NSFont.menuFont(ofSize: 0)
            let cw = ceil(contextField.stringValue.size(withAttributes: [.font: font]).width) + 2
            contextField.frame = NSRect(x: pillLeft - timerGap - cw, y: (rowH - 16) / 2,
                                        width: cw, height: 16)
            pillLeft = contextField.frame.minX
        } else {
            contextField.isHidden = true
        }
        if let timer = timer {
            timerField.isHidden = false
            timerField.stringValue = timer
            // Fit the column to the text (mono font, right edge anchored at the pill): a fixed-width
            // column reserved ~50pt of blank space that pixel-truncated the name · branch next to it.
            let font = timerField.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
            let tw = ceil(timer.size(withAttributes: [.font: font]).width) + 2
            // Same point size and same box (y/height) as the name field, so the timer sits on the name's
            // baseline instead of floating at the row's vertical center.
            timerField.frame = NSRect(x: pillLeft - timerGap - tw, y: (rowH - 16) / 2, width: tw, height: 16)
        } else { timerField.isHidden = true }
        // Name stretches to whatever the timer/pill leave free (branch text made the fixed 160 tight);
        // pixel truncation via the paragraph style handles overflow.
        let nameRight = timer != nil ? timerField.frame.minX : pillLeft
        nameField.frame.size.width = max(40, nameRight - timerGap - nameField.frame.minX)
    }
    // name in the label color, " · branch" dimmed — mirrored on hover, where setting textColor
    // can't restyle an attributed string.
    private func renderName() {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // Barely-overflowing text otherwise gets its tracking silently condensed to fit ("default
        // tightening"), so the same name renders visibly squished on a row whose timer narrows the
        // field. Constant tracking on every row; overflow shows an honest ellipsis instead.
        para.allowsDefaultTighteningForTruncation = false
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: nameText, attributes: [
            .font: font, .paragraphStyle: para,
            .foregroundColor: hovered ? NSColor.white : .labelColor,
        ])
        if !branchText.isEmpty {
            text.append(NSAttributedString(string: " · " + branchText, attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: hovered ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor,
            ]))
        }
        nameField.attributedStringValue = text
    }
    // Custom views don't get the menu's automatic hover highlight, so draw it ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        hovered = h
        highlightView.isHidden = !h
        renderName()
        timerField.textColor = h ? .white : .secondaryLabelColor
        contextField.textColor = h ? .white : contextBase
        iconView.contentTintColor = h ? .white : iconBaseTint
        if !pillView.isHidden { pillView.image = h ? pillSelected : pillNormal }
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// Custom view for the same reason as SessionRowView (a trailing-edge icon needs a flexible
// spacer; a plain menu item can't cross the shortcut/submenu-arrow gutter), with the same
// self-drawn hover highlight.
final class CopyRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let highlightView = NSVisualEffectView()
    private let command: String
    private let pad: CGFloat = 14, rowH: CGFloat = 24, iconSize: CGFloat = 15
    private var copied = false

    init(title: String, command: String, width: CGFloat) {
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.stringValue = title
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: pad, y: (rowH - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        addSubview(label)
        icon.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: width - pad - iconSize, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        icon.autoresizingMask = [.minXMargin]
        addSubview(icon)
        toolTip = command
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        highlightView.isHidden = !h
        label.textColor = h ? .white : .labelColor
        icon.contentTintColor = h ? .white : (copied ? .labelColor : .secondaryLabelColor)
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        copied = true
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        icon.contentTintColor = .white  // click happens mid-hover; setHover keeps it labelColor otherwise
        // Give the checkmark a beat to register before the menu closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.enclosingMenuItem?.menu?.cancelTracking()
        }
    }
}
