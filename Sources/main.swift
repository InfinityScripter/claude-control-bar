import Cocoa
import UserNotifications

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

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar")
    let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/state.d")
    let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    // MARK: MCP + limits
    lazy var mcp = MCPModel(
        path: (root as NSString).appendingPathComponent("mcp.json"))
    var limits: Limits?
    var mcpBusy = false
    var recheckTimer: Timer?
    /// Every label in the open menu that shows a count. NSMenu will not let rows be added or
    /// removed while it is tracking, but the items it already holds can be rewritten — which is
    /// how switching one tool moves its server's total and the grand total on the spot, instead
    /// of leaving both stale until the menu is reopened.
    var mcpCountLabels: [() -> Void] = []
    /// How often the MCP picture is rebuilt from scratch in the background. Measured at ~34s a
    /// run, essentially all of it `claude mcp list` starting every configured server and waiting
    /// — which is why it is not on the render path. Without it the picture never updates at all,
    /// which is how a server that had reconnected went on showing a red cross indefinitely.
    static let mcpRefreshInterval: TimeInterval = 600
    /// Opening the menu rebuilds the picture if it is older than this. Short enough that what is
    /// on screen is worth trusting, long enough that opening the menu repeatedly is free.
    static let mcpOpenStaleAfter: TimeInterval = 120
    var lastGauge: (Gauge, Bool)?
    /// Everything the MCP half needs to run: the interpreter and the script. Written by the
    /// plugin's bootstrap hook so the app survives the plugin moving between versions; falls
    /// back to the copy inside the app bundle, which is what the brew/DMG channel has.
    lazy var backend: (python: String, script: String) = {
        let paths = (root as NSString).appendingPathComponent("paths.json")
        if let data = FileManager.default.contents(atPath: paths),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let script = root["script"] as? String, FileManager.default.fileExists(atPath: script) {
            return (root["python"] as? String ?? "/usr/bin/python3", script)
        }
        let bundled = Bundle.main.path(forResource: "mcpbar", ofType: "py", inDirectory: "scripts")
        return ("/usr/bin/python3", bundled ?? "")
    }()

    struct Limits {
        let fiveHour: Int?
        let sevenDay: Int?
        let fiveHourResets: Double?
        let sevenDayResets: Double?
        let ts: Double
    }

    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    // "Hide idle after" setting (seconds): hide a resting session's ROW once it's been quiet this long.
    // Render-only — it never deletes the file or affects liveness (that's pid-driven now), and the
    // most-recent session is always kept visible (floor at one). 0 = Never. Defaults to 15 min.
    // No UI writes it: it is a `defaults write` knob for someone who wants a different number.
    var stalePruneAge: TimeInterval { UserDefaults.standard.object(forKey: "hideIdleAfter") as? Double ?? 900 }

    struct Session {
        var id: String, state: String, label: String, project: String, transcript: String
        var cwd: String         // session working directory; "" on pre-upgrade files
        var entrypoint: String  // CLAUDE_CODE_ENTRYPOINT: "cli", "claude-desktop", …
        var termProgram: String // TERM_PROGRAM for CLI sessions: "Apple_Terminal", "iTerm.app", …
        var termBundle: String  // __CFBundleIdentifier of the hosting app; "" over ssh / pre-upgrade files
        var pid: Int32          // the session's `claude` process; kill(pid,0) drives liveness. 0 = pre-upgrade file.
        var started: Bool       // true once the session had real activity (a prompt/tool); a merely-opened
                                // conversation seeds started=false and stays out of the dropdown.
        var startedAt: Double, ts: Double
        // How full this session's context window is, measured by hooks/update.js from the
        // transcript on every event. Claude Code hands this number to statusLine and to nothing
        // else, and the desktop app never runs statusLine — so it is recomputed rather than read.
        var pct: Int?
        var tokens: Int?
        var window: Int?
        var model: String = ""
        var assumed = false    // the window size is a family guess, not a known figure

        var eff: String = ""   // effective state, recomputed once per tick in evaluate()
        var branch: String = ""      // git branch (or short SHA when detached); "" outside a repo
        var displayName: String = "" // project, parent-qualified when two live sessions share a name

        init(json o: [String: Any], id: String) {
            self.id = id
            self.state = o["state"] as? String ?? "idle"
            self.label = o["label"] as? String ?? ""
            self.project = o["project"] as? String ?? ""
            self.transcript = o["transcript"] as? String ?? ""
            self.cwd = o["cwd"] as? String ?? ""
            self.entrypoint = o["entrypoint"] as? String ?? ""
            self.termProgram = o["term_program"] as? String ?? ""
            self.termBundle = o["term_bundle"] as? String ?? ""
            self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
            self.started = o["started"] as? Bool ?? false
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
            self.pct = (o["pct"] as? NSNumber)?.intValue
            self.tokens = (o["tokens"] as? NSNumber)?.intValue
            self.window = (o["window"] as? NSNumber)?.intValue
            self.model = o["model"] as? String ?? ""
            self.assumed = o["assumed"] as? Bool ?? false
        }
    }
    var sessions: [String: Session] = [:]  // id -> latest parsed per-session state
    var fileMTimes: [String: Date] = [:]   // "<id>.json" -> last-parsed mtime (re-parse only on change)
    var gitHeadCache: [String: String] = [:]  // cwd -> resolved HEAD path ("" = confirmed non-git)
    var prevState: [String: String] = [:]  // id -> previous raw state per session
    var menuIsOpen = false                  // refresh the dropdown's per-session timers only while open
    var sessionMenuItems: [(item: NSMenuItem, id: String)] = []
    var activeBase = ""        // label without the elapsed clock
    var renderedTitle: String? // what the status item is actually showing, to skip identical redraws
    var lastLifecycleCheck: Double = 0  // the quit decision is sampled far slower than the UI
    var notificationsDenied = false     // the one macOS permission this app has; see notify()
    var selfUpdating = false            // one build-from-source update at a time; also the menu text
    var updateBuild: Process?           // the in-flight update's build; Quit terminates it (see quit())
    // Never `xcrun --find`: querying xcrun with no developer tools installed pops the system's
    // "install the command line developer tools?" dialog — from a menu bar app, out of nowhere.
    // A missing toolchain must read as "not available", never as a prompt. The fixed paths cover
    // the stock installs; `xcode-select -p` (prompt-free) covers one moved with --switch.
    lazy var canBuildFromSource: Bool = {
        let stock = ["/Library/Developer/CommandLineTools/usr/bin/swiftc",
                     "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"]
        if stock.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        probe.arguments = ["-p"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0,
              let root = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { return false }
        return [root + "/usr/bin/swiftc",
                root + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }()
    var turnLineCache: [String: (size: UInt64, mtime: Date, interrupted: Bool, turnTs: Double?)] = [:]
    var iconCache: [Int: NSImage] = [:]  // composed menu bar frames, rebuilt only when the look changes
    var iconCacheKey = ""
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    enum AnimStyle: String { case web, code, crab }
    var animStyle: AnimStyle = .web
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var useThinkingWords = true     // rotate a playful verb ("Manifesting…") in place of "Thinking…"
    var oauthLimits = true          // poll Anthropic's usage endpoint for the 5h/7d limits
    var sessionWord: [String: String] = [:] // id -> current thinking word; re-picked on each entry into "thinking"
    var soundThreshold: Double = 0  // 0 = off; else the min turn length (seconds) that chimes on completion
    var turnStart: [String: Double] = [:]  // id -> active turn start, for the completion-sound length gate
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    // Claude Code's SPINNER_VERBS, minus the hyphenated/tongue-twister ones. Longest kept is ~14 chars
    // ("Hullaballooing"/"Metamorphosing"); with the timer showing they can get wide in a crowded menu bar.
    let thinkingWords = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'",
        "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping",
        "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing",
        "Cascading", "Catapulting", "Cerebrating", "Channeling", "Channelling", "Churning", "Clauding",
        "Coalescing", "Cogitating", "Combobulating", "Composing", "Computing", "Concocting", "Considering",
        "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing", "Cultivating",
        "Deciphering", "Deliberating", "Determining", "Doing", "Doodling", "Drizzling", "Ebbing",
        "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Evaporating", "Fermenting",
        "Finagling", "Flambéing", "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking",
        "Gallivanting", "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating", "Gitifying",
        "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
        "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring", "Infusing",
        "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening", "Levitating", "Lollygagging",
        "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking", "Moseying",
        "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Noodling", "Nucleating", "Orbiting",
        "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing", "Pollinating", "Pondering",
        "Pontificating", "Pouncing", "Precipitating", "Processing", "Proofing", "Propagating", "Puttering",
        "Puzzling", "Quantumizing", "Razzmatazzing", "Reticulating", "Roosting", "Ruminating", "Sautéing",
        "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
        "Skedaddling", "Sketching", "Slithering", "Smooshing", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering",
        "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Transfiguring", "Transmuting", "Twisting",
        "Undulating", "Unfurling", "Unravelling", "Vibing", "Waddling", "Wandering", "Warping",
        "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging"]
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let codeGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let codePeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let codeDip: CGFloat = 0.14 // glyph shrinks to this at each swap
    let codeSub = 18            // sub-frames per glyph (tween smoothness)
    let codeCycle: Double = 3.8 // seconds for the full loop (lower = faster)
    lazy var codeGlyphMasks: [NSImage] = codeGlyphs.map { StatusController.glyphMask($0) }
    let crabFPS: Double = 12.5 // matches the source GIF's 0.08s frame delay
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    // Template frames: bright pixels (white eyes) become transparent holes so they're
    // visible as negative space against the menu bar in System color mode.
    lazy var crabTemplateFrames: [NSImage] = crabFrames.map { adaptiveCrabFrame($0) }
    var fps: Double {
        switch animStyle {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab: return crabFPS
        }
    }
    var frameCount: Int {
        switch animStyle {
        case .web: return max(1, frames.count)
        case .code: return codeGlyphs.count * codeSub
        case .crab: return max(1, crabFrames.count)
        }
    }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "thinkingWords") != nil { useThinkingWords = d.bool(forKey: "thinkingWords") }
        if d.object(forKey: "oauthLimits") != nil { oauthLimits = d.bool(forKey: "oauthLimits") }
        if d.object(forKey: "soundThreshold") != nil { soundThreshold = d.double(forKey: "soundThreshold") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        // Rebuilding the MCP picture is expensive (`claude mcp list` plus a tools/list round trip
        // per server) so it gets its own slow timer rather than riding the 0.4s render tick.
        Timer.scheduledTimer(withTimeInterval: Self.mcpRefreshInterval, repeats: true) {
            [weak self] _ in self?.refreshMCP()
        }
        refreshMCP()
        // Limits come from the same endpoint /usage reads, on their own cadence: the statusLine
        // capture only fires while a terminal CLI is redrawing its TUI, so for someone working in
        // the desktop app it never fires at all — which left the bars frozen on whatever they
        // last showed. Five minutes is well clear of the endpoint's rate limiting (community
        // consensus puts the floor at three).
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in self?.pollLimits()
        }
        pollLimits()
        refreshNotificationAuthStatus()
        tick()
        try? FileManager.default.removeItem(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/quit-intent"))
        // CONTROL_BAR_DUMP_MENU=1 builds the dropdown once, prints it and quits. Looking at the
        // real thing is not a reliable check: a crowded menu bar parks items off-screen behind a
        // manager's chevron (measured at x ≈ −8650 on this machine), so they are invisible while
        // perfectly healthy. This reads the menu that would be drawn.
        // CONTROL_BAR_DIAGNOSE=1 answers the single most common report — "the icon is gone" —
        // with measurements instead of guesses. A status item that does not fit beside the notch
        // is not clipped: macOS parks it off-screen behind the overflow chevron, and from the
        // outside that is indistinguishable from an app that failed to start.
        // CONTROL_BAR_DIAGNOSE=menu opens the dropdown by itself, so it can be screenshotted.
        // There is no other way to look at it: the menu closes the moment anything else takes
        // over, and a crowded menu bar can hide the item that opens it.
        if ProcessInfo.processInfo.environment["CONTROL_BAR_DIAGNOSE"] == "menu" {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                // An accessory app is not active, and performClick on an inactive app's status
                // button does nothing at all.
                NSApp.activate(ignoringOtherApps: true)
                self?.statusItem.button?.performClick(nil)
            }
        } else if ProcessInfo.processInfo.environment["CONTROL_BAR_DIAGNOSE"] != nil {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self else { return }
                let gauge = self.currentGauge()
                print("gauge 5h=\(gauge.fiveHour as Any) 7d=\(gauge.sevenDay as Any)")
                print("sessions=\(self.sessions.count) mcp servers=\(self.mcp.servers.count)")
                guard let button = self.statusItem.button else {
                    print("no status item button at all"); NSApp.terminate(nil); return
                }
                print("image=\(button.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")"
                    + " template=\(button.image?.isTemplate as Any) length=\(self.statusItem.length)")
                if let window = button.window {
                    let screen = NSScreen.main?.frame ?? .zero
                    print("item window=\(window.frame) visible=\(window.isVisible) screen=\(screen)")
                    print(window.frame.maxX > screen.maxX || window.frame.minX < 0
                          ? "VERDICT: parked off-screen — the menu bar is full, it is behind the › chevron"
                          : "VERDICT: on screen at x=\(Int(window.frame.minX))")
                } else {
                    print("button has no window yet")
                }
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["CONTROL_BAR_DUMP_MENU"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self, let menu = self.statusItem.menu else { return }
                self.menuNeedsUpdate(menu)
                print(StatusController.describe(menu))
                NSApp.terminate(nil)
            }
        }
        enforceSingleInstance()
        retirePredecessors()
        ensureHooksInstalled()
        checkForUpdate()
    }

    // Bundles this project shipped under earlier names. See identity.env: upstream's
    // com.local.claudestatusbar is deliberately absent — claude-status-bar is a separate
    // product the user may want, and a fork that deletes the app it forked from is a bug with
    // a very bad blast radius. The inherited routine did exactly that, by id.
    let legacyBundleIDs = ["com.local.mcpstatus", "com.local.mcpbar"]

    // A rename leaves the previous copy installed and running: same job, second menu bar icon,
    // two apps writing one state directory. Measured on the development machine mid-merge —
    // MCPStatus and an orphaned MCP Bar.app from an earlier rename were both still on disk.
    //
    // Retired to the Trash, not unlinked: an app the user can drag back is a different promise
    // from one this deleted on its own authority during a routine launch.
    /// True only for a copy living under /Applications or ~/Applications. A build run straight out
    /// of build/ is a development artifact and must keep its hands off the user's machine — it
    /// has no business installing hooks into settings.json or moving installed apps to the Trash
    /// just because someone launched it to look at the menu. (Learned the direct way: a dev run
    /// wrote eight hooks into a live settings.json.)
    ///
    /// Anchored at the front of the path, not searched anywhere inside it: a plain `contains`
    /// promoted `/tmp/Applications/scratch/…` and `~/projects/Applications/demo/…` to installed
    /// copies, which is the exact dev run this guard exists to hold back. A prefix rather than an
    /// exact parent, because organising apps into /Applications/Utilities is normal and a copy
    /// filed away there is installed by any honest reading.
    var isInstalledCopy: Bool {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath).resolvingSymlinksInPath().path
        // Both sides resolved, or a home directory that is itself a link never matches.
        let personal = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("Applications").path
        return bundle.hasPrefix("/Applications/") || bundle.hasPrefix(personal + "/")
    }

    func retirePredecessors() {
        guard isInstalledCopy else { return }
        let fm = FileManager.default
        for id in legacyBundleIDs where id != Bundle.main.bundleIdentifier {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == id {
                app.terminate()
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  // Re-read the id off disk: urlForApplication answers from Launch Services'
                  // cache, which keeps pointing at a path long after the bundle moved.
                  let info = NSDictionary(
                    contentsOfFile: url.appendingPathComponent("Contents/Info.plist").path),
                  info["CFBundleIdentifier"] as? String == id,
                  url.path != Bundle.main.bundlePath
            else { continue }
            var trashed: NSURL?
            do { try fm.trashItem(at: url, resultingItemURL: &trashed) } catch {
                NSLog("ClaudeControlBar: could not retire \(url.path): \(error)")
            }
        }
    }

    // Two bundles can carry one id (the plugin builds into ~/Applications, brew installs into
    // /Applications) and macOS will happily run both — one id, two menu bar items, and `open -b`
    // picking between them at random. The copy in /Applications wins because that is the one
    // brew updates; a plugin build stands down rather than fighting it.
    func enforceSingleInstance() {
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = Bundle.main.bundlePath
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != me
        }
        guard !others.isEmpty else { return }
        let systemWide = mine.hasPrefix("/Applications/")
        for other in others {
            let theirs = other.bundleURL?.path ?? ""
            if systemWide && !theirs.hasPrefix("/Applications/") {
                other.terminate()
            } else if !systemWide {
                NSLog("ClaudeControlBar: \(theirs) already running, standing down")
                NSApp.terminate(nil)
                return
            }
        }
    }

    // Re-runs on first install AND on every version change, so upgrades pick up hook
    // changes and retire old artifacts.
    func ensureHooksInstalled() {
        // Run on every launch, not once per version. The installer is idempotent — it compares
        // and writes nothing when nothing differs — and it is also what reclaims the hooks when
        // the plugin channel goes away, which is not a version change at all. A version gate got
        // this exactly backwards: remove the hooks by hand (or have another install remove them)
        // and the app would never put them back, because UserDefaults still said "done".
        guard isInstalledCopy,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            guard let node = Self.locateNode() else {
                NSLog("ClaudeControlBar: could not find node; hooks not installed (will retry next launch)")
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: node)
            task.arguments = [installer]
            try? task.run()
            task.waitUntilExit()
        }
    }

    // `/bin/zsh -lc node` saw only the login PATH, missing nvm/fnm set in .zshrc.
    static func locateNode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            // Component-wise, not alphabetical: as text "v9.11.2" sorts above "v20.19.0", so the
            // newest-first intent picked the oldest Node on the machine — and the installer this
            // runs uses APIs a Node that old does not have.
            for v in versions.sorted(by: { versionIsNewer($0, than: $1) }) {
                candidates.append("\(nvmDir)/\(v)/bin/node")
            }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    /// The version of the bundle sitting on disk, read fresh from the file rather than from the
    /// Info.plist the process cached at launch.
    ///
    /// A DMG install or `brew upgrade --cask` replaces the bundle under a live process, and macOS
    /// keeps the running executable image alive until the app is restarted. Measured on the
    /// development machine: a 0.5.1 bundle in /Applications and a 0.5.0 process in the menu bar,
    /// for two hours, with nothing anywhere saying so. And it is worse than cosmetic — a process
    /// whose bundle was replaced could no longer write its own preferences at all, so the update
    /// check had nowhere to keep the latest tag and the "Update to X" line could never appear
    /// again either. The one thing that fixes it is a restart, so that is what gets offered.
    var installedVersion: String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
    }
    let releaseAPIURL = "https://api.github.com/repos/InfinityScripter/claude-control-bar/releases/latest"
    let releasePageURL = "https://github.com/InfinityScripter/claude-control-bar/releases/latest"
    // Homebrew: the cask lags a GitHub release by up to ~a day (autobump), so brew-managed
    // installs gate "update available" on the CASK version, so the copy command always works
    // when offered. Public JSON, nothing sent anywhere (same privacy story as the GitHub check).
    let brewCaskAPIURL = "https://formulae.brew.sh/api/cask/claude-control-bar.json"
    let brewUpgradeCommand = "brew upgrade --cask claude-control-bar"
    // The trailing `open` matters: brew only copies the app, and the first launch of the new copy
    // is what installs hooks and removes the old-named bundle (0.4.0 rename transition).
    let brewInstallCommand = "brew install --cask claude-control-bar && open -a \"Claude Control Bar\""
    var brewManaged: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/claude-control-bar")
            || FileManager.default.fileExists(atPath: "/usr/local/Caskroom/claude-control-bar")
    }

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    func checkForUpdate() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        // Stamped here, before the requests, not in the success handler. Written on success only,
        // an unreachable GitHub meant every subsequent menu open fired both requests again — the
        // opposite of the once-a-day check PRIVACY.md promises, and worst exactly when the network
        // is already in trouble. An attempt is what the throttle counts; the outcome is separate.
        d.set(now, forKey: "lastUpdateCheck")
        guard let url = URL(string: releaseAPIURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("ClaudeControlBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            UserDefaults.standard.set(now, forKey: "lastUpdateSuccess")
        }.resume()
        guard let brewURL = URL(string: brewCaskAPIURL) else { return }
        URLSession.shared.dataTask(with: URLRequest(url: brewURL)) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ver = obj["version"] as? String else { return }
            UserDefaults.standard.set(ver, forKey: "brewCaskVersion")
        }.resume()
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    /// Static because the Node search needs it too, and that runs before any instance exists.
    /// A leading "v" is tolerated: release tags and nvm directories both carry one.
    ///
    /// Everything from the first non-numeric component on is dropped, so a pre-release compares as
    /// its own base version and never above it. Mapping an unparsable component to 0 instead had
    /// "0.6.0-rc.1" split into 0, 6, "0-rc" -> 0, 1 — one component longer than "0.6.0" and
    /// therefore newer, which is backwards: a release candidate would have been offered as an
    /// update to the release it precedes.
    static func versionIsNewer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in
            s.drop(while: { $0 == "v" }).split(separator: ".")
                .prefix(while: { Int($0) != nil }).map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    /// Quit, then come back as the copy on disk.
    ///
    /// The relaunch waits for this process to be gone rather than firing alongside it: two copies
    /// of the SAME bundle path coexist happily — enforceSingleInstance only stands one down when
    /// the paths differ — so an overlap means two menu bar icons and two backends writing one
    /// state directory. The quit marker is written for the same reason the Quit item writes it:
    /// a hook firing in the gap would otherwise race the app back up before `open` runs. The new
    /// process clears the marker as it starts.
    @objc func restartIntoInstalledCopy() {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/quit-intent")
        FileManager.default.createFile(atPath: marker, contents: nil)
        let quoted = "'" + Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null;"
                          + " do sleep 0.2; done; exec /usr/bin/open \(quoted)"]
        do { try task.run() } catch {
            // Quitting with no relauncher running would just make the app vanish. Staying alive
            // is strictly better: the copy on disk is already the new one, so the menu's
            // "Restart to finish updating" row appears on the next open and offers this again.
            logProblem("relaunch spawn failed: \(error)")
            selfUpdating = false
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: self-update (build from source)

    /// Best-effort breadcrumb for the failures a menu bar app has nowhere to show live.
    func logProblem(_ text: String) {
        NSLog("ClaudeControlBar: %@", text)
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/problems.log"
        let prev = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        try? (prev + text + "\n").write(toFile: log, atomically: true, encoding: .utf8)
    }

    /// The DMG channel's automatic update: download the release source, build it with the same
    /// script every channel uses, let its staging swap replace this bundle, restart into it.
    ///
    /// No signature is involved anywhere — the binary is compiled on this machine, and
    /// Gatekeeper's quarantine applies to downloaded executables, not locally built ones. This is
    /// the plugin channel's own mechanism offered to the bundle install; the alternative —
    /// shipping a prebuilt update and stripping its quarantine — works exactly until it doesn't,
    /// and each ad-hoc re-sign would read to macOS as a different app, dropping notification
    /// permission along the way.
    @objc func selfUpdate() {
        guard !selfUpdating, let latest = UserDefaults.standard.string(forKey: "latestVersion"),
              let url = URL(string:
                "https://github.com/InfinityScripter/claude-control-bar/archive/refs/tags/v\(latest).tar.gz")
        else { return }
        selfUpdating = true
        let target = Bundle.main.bundlePath
        let fail: (String) -> Void = { [weak self] reason in
            self?.logProblem("self-update to \(latest) failed: \(reason)")
            DispatchQueue.main.async { self?.selfUpdating = false }
        }
        URLSession.shared.downloadTask(with: url) { [weak self] file, _, error in
            // The download lands in URLSession's temporary file, which dies with this callback —
            // move it out synchronously, then leave the session's queue before the slow part:
            // a build takes a minute, and this queue also serves the daily update check.
            let tar = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ccb-update-\(latest).tar.gz")
            guard let file else { return fail(error.map(String.init(describing:)) ?? "empty download") }
            try? FileManager.default.removeItem(at: tar)
            do { try FileManager.default.moveItem(at: file, to: tar) } catch { return fail("move: \(error)") }
            DispatchQueue.global(qos: .utility).async {
                self?.buildAndSwap(tar: tar, target: target, latest: latest, fail: fail)
            }
        }.resume()
    }

    private func buildAndSwap(tar: URL, target: String, latest: String, fail: (String) -> Void) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccb-update-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: tar) }
        do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
        catch { return fail("mkdir: \(error)") }

        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xzf", tar.path, "-C", tmp.path]
        do { try untar.run() } catch { return fail("tar: \(error)") }
        untar.waitUntilExit()
        guard untar.terminationStatus == 0 else { return fail("tar exited \(untar.terminationStatus)") }

        // GitHub archives unpack into <repo>-<version>/ — located by its build.sh, not by name,
        // so a fork or a renamed tag cannot break the path.
        guard let src = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
                .map({ tmp.appendingPathComponent($0) })
                .first(where: { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("build.sh").path) })
        else { return fail("no build.sh in the archive") }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [src.appendingPathComponent("build.sh").path]
        build.currentDirectoryURL = src
        var env = ProcessInfo.processInfo.environment
        env["CONTROL_BAR_APP"] = target
        build.environment = env
        // stdout to the bit bucket; stderr drained by a handler, not a blocking
        // readDataToEndOfFile — that read returns only when every holder of the write end closes
        // it, so a compiler child outliving bash would pin this thread forever. The watchdog
        // bounds the build for the same reason: a hang here would otherwise leave
        // selfUpdating=true (a greyed menu row, no retry) for the process's whole lifetime.
        build.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        build.standardError = errPipe
        var stderrData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { stderrData.append($0.availableData) }
        do { try build.run() } catch { return fail("build launch: \(error)") }
        DispatchQueue.main.async { [weak self] in self?.updateBuild = build }
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) { [weak build] in
            if let build, build.isRunning { build.terminate() }
        }
        build.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async { [weak self] in self?.updateBuild = nil }
        guard build.terminationStatus == 0 else {
            let tail = String(decoding: stderrData.suffix(2000), as: UTF8.self)
            return fail("build exited \(build.terminationStatus):\n\(tail)")
        }
        // The bundle at `target` is already the new version (build.sh swaps only a verified
        // staging copy). restartIntoInstalledCopy quits us and opens whatever is on disk.
        DispatchQueue.main.async { [weak self] in self?.restartIntoInstalledCopy() }
    }

    // MARK: MCP backend

    /// Any mcpbar.py command: off the main queue, UI updated back on it. Nothing here parses the
    /// script's output — the script writes mcp.json and the model re-reads it.
    ///
    /// Serial, deliberately. A full check starts every configured MCP server and takes about
    /// half a minute; on a concurrent queue a toggle during one of those launched a second
    /// backend over the same servers and the same cache files, and whichever finished first
    /// cleared mcpBusy while the rest were still running — the menu said "done" mid-flight.
    let backendQueue = DispatchQueue(
        label: "io.github.infinityscripter.claude-control-bar.backend")
    /// Operations handed to the queue and not yet finished. A plain Bool could not survive two
    /// of them: the first to return cleared it.
    var backendRunning = 0

    func runBackend(_ arguments: [String], then done: (() -> Void)? = nil) {
        guard !backend.script.isEmpty else {
            NSLog("ClaudeControlBar: no mcpbar.py — the bootstrap hook has not run")
            done?()
            return
        }
        backendRunning += 1
        mcpBusy = true
        backendQueue.async { [weak self] in
            guard let self else { return }
            let task = Process()
            // Absolute paths: a GUI process gets a stripped PATH with no pyenv and no nvm in it.
            task.executableURL = URL(fileURLWithPath: self.backend.python)
            task.arguments = [self.backend.script] + arguments
            task.standardOutput = FileHandle.nullDevice
            // stderr and the exit code used to go to /dev/null together, so a backend that died
            // on a traceback looked exactly like one that had nothing to report — the menu simply
            // showed the previous picture and said nothing. Read into a pipe (not inherited: a
            // GUI process's stderr is the system log, where it is nobody's) and surfaced only on
            // a non-zero exit, so a healthy run stays as quiet as it was.
            let errors = Pipe()
            task.standardError = errors
            do {
                try task.run()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let text = String(data: stderr.suffix(2000), encoding: .utf8) ?? ""
                    NSLog("ClaudeControlBar: mcpbar.py \(arguments.first ?? "") exited"
                          + " \(task.terminationStatus): \(text)")
                }
            } catch {
                NSLog("ClaudeControlBar: \(self.backend.python) failed: \(error)")
            }
            DispatchQueue.main.async {
                self.backendRunning = max(0, self.backendRunning - 1)
                self.mcpBusy = self.backendRunning > 0
                self.mcp.reloadIfChanged(force: true)
                self.notifyMCPChange()
                // The backend's own answer has to land in the open menu too, not just the
                // optimistic guess that preceded it — otherwise a toggle the backend refused
                // would keep showing as applied.
                self.refreshCounts()
                self.evaluate()
                done?()
            }
        }
    }

    /// True from the moment a full check is asked for until it has finished.
    var refreshQueued = false
    /// A check asked for while one was already running. Dropping it outright was wrong: the run
    /// in flight started BEFORE the toggle and cannot know about it, so a server switched off
    /// mid-check kept its old row until the ten-minute timer came round — a stale answer that
    /// reads as the click having done nothing.
    var refreshAgain = false

    /// Refreshes coalesce: a second full check queued behind one still running buys nothing but
    /// another half-minute of every configured server being started again. It is remembered, not
    /// discarded, and runs once as soon as the current one lands.
    @objc func refreshMCP() {
        guard !refreshQueued else { refreshAgain = true; return }
        refreshQueued = true
        runBackend(["refresh"]) { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refreshMCP()
            }
        }
    }

    /// One usage poll: mcpbar.py reads the account limits from Anthropic's usage endpoint —
    /// the same one /usage in Claude Code asks — and rewrites limits.json; the 0.4s tick picks
    /// the file up. Not routed through runBackend: that toggles mcpBusy and re-reads mcp.json,
    /// and a limits poll has nothing to say about either. Off switch in Options, because it
    /// spends the user's own OAuth token, even if only against Anthropic's own API.
    func pollLimits() {
        guard oauthLimits, !backend.script.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.backend.python)
            task.arguments = [self.backend.script, "limits"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    func watchCount(_ update: @escaping () -> Void) {
        mcpCountLabels.append(update)
        update()
    }

    func refreshCounts() { mcpCountLabels.forEach { $0() } }

    func setMCPServer(_ name: String, enabled: Bool) {
        mcp.setServerLocally(name, enabled: enabled)
        runBackend(["toggle-server", name, enabled ? "--on" : "--off"])
        scheduleRecheck()
        // Last, not first: the row draws a spinner while a check is running or ordered, so it has
        // to be redrawn after the work is on its way rather than before.
        refreshCounts()
    }

    /// Whether anything is being worked out right now — a backend run in flight, or one already
    /// ordered and counting down. What the spinner on a server row is allowed to claim.
    var mcpChecking: Bool { mcpBusy || (recheckTimer?.isValid ?? false) }

    /// A toggle leaves the row spinning, and something has to go and check. Waiting for
    /// the ten-minute timer meant a server switched back on sat unresolved long enough to read as
    /// broken. Debounced, because flipping several servers in a row should cost one check, not one
    /// each — a full check re-runs `claude mcp list` and a tools/list round trip per server.
    func scheduleRecheck() {
        recheckTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in self?.refreshMCP() }
        // .common, so it fires while the menu is open — which is exactly when toggles happen.
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    /// The rule goes first for an older mcpbar.py, which reads exactly one positional argument;
    /// `--server`/`--tool` is what a current one uses, because only it can turn a display name
    /// into the spelling Claude Code actually uses inside a tool name. Building the rule here was
    /// the bug: for a plugin or a claude.ai connector it produced `mcp__claude.ai Figma__…`,
    /// which matches no tool at all — the switch went off and the tool kept loading.
    func setMCPTool(server: String, tool: String, prefix: String, enabled: Bool) {
        runBackend(["toggle-tool", MCPServer.fullToolName(prefix: prefix, tool: tool),
                    "--server", server, "--tool", tool, enabled ? "--on" : "--off"])
    }

    @objc func openSettingsJSON() {
        NSWorkspace.shared.open(URL(fileURLWithPath:
            (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")))
    }

    func loadLimits() {
        let path = (root as NSString).appendingPathComponent("limits.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Opting out has to mean the numbers go away, not just that they stop moving. The file
        // survives the switch (the statusLine capture writes the same one), so the source is
        // what decides: figures that came from the API are dropped the moment the API is off,
        // and the section says it has no data — which is what the README promises. Anything
        // captured from statusLine is the user's own second source and stays.
        if !oauthLimits, (root["source"] as? String) == "oauth" {
            limits = nil
            return
        }
        // as? Int, deliberately: the statusLine payload reports fractional percentages and
        // hooks/statusline.py rounds them on the way in. If a writer ever forgets, the limits
        // vanish from the menu while limits.json still looks perfectly healthy — so the
        // rounding lives in one place and is covered by a test.
        let five = root["five_hour"] as? [String: Any]
        let seven = root["seven_day"] as? [String: Any]
        limits = Limits(
            fiveHour: five?["used_percentage"] as? Int,
            sevenDay: seven?["used_percentage"] as? Int,
            fiveHourResets: five?["resets_at"] as? Double,
            sevenDayResets: seven?["resets_at"] as? Double,
            ts: root["ts"] as? Double ?? 0)
    }

    /// A server falling over is worth interrupting for; a tool count moving is not — that is
    /// usually the user, one click ago, in this very menu.
    func notifyMCPChange() {
        guard let change = mcp.freshChange(), change.deservesNotification else { return }
        if !change.down.isEmpty {
            notify(title: change.down.count == 1
                    ? "MCP: \(mcpShortName(change.down[0])) went down"
                    : "MCP: \(change.down.count) servers went down",
                   body: change.down.map(mcpShortName).joined(separator: ", "))
        }
        if !change.up.isEmpty {
            notify(title: change.up.count == 1
                    ? "MCP: \(mcpShortName(change.up[0])) is back"
                    : "MCP: \(change.up.count) servers are back",
                   body: change.up.map(mcpShortName).joined(separator: ", "))
        }
    }

    /// Notifications were posted without permission ever being asked for — `requestAuthorization`
    /// appears nowhere in this project's history — so macOS declined every one of them: an app
    /// sitting at `.notDetermined` is not prompted on delivery, the request simply fails, and the
    /// only trace was an NSLog nobody reads. Asked here rather than
    /// at launch, so the prompt arrives attached to a real event — a server that just fell over —
    /// instead of ambushing the first launch.
    ///
    /// A refusal is remembered, not retried: macOS shows the system dialog once per app, ever —
    /// no later version, reinstall or second `requestAuthorization` brings it back, only the user
    /// in System Settings. So a denial used to be swallowed whole, and someone who declined a year
    /// ago could never learn why alerts stopped. It now sets `notificationsDenied`, which the menu
    /// answers with a row that opens the right Settings pane.
    func notify(title: String, body: String) {
        // UNUserNotificationCenter.current() traps (NSInternalInconsistencyException,
        // "bundleProxyForCurrentProcess is nil") when the process runs outside an .app bundle —
        // which is exactly how the diagnostic modes (CONTROL_BAR_DUMP_MENU/DIAGNOSE) and ad-hoc
        // builds run the bare binary. No bundle, no notification delivery anyway.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        let deliver = {
            center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            ) { error in if let error { NSLog("ClaudeControlBar: notification failed: \(error)") } }
        }
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { NSLog("ClaudeControlBar: notification permission: \(error)") }
                    // The system now holds the stored answer; the one canonical mapping reads it
                    // back, rather than a second spelling (!granted) drifting beside it.
                    self?.refreshNotificationAuthStatus()
                    if granted { deliver() }
                }
                return
            }
            let denied = settings.authorizationStatus == .denied
            // Written on the allowed path too: flipping the switch back on in System Settings
            // must clear the menu row on the next event, not only on the next menu open.
            DispatchQueue.main.async { self?.notificationsDenied = denied }
            if !denied { deliver() }
        }
    }

    /// The stored answer, refreshed at launch and on every menu open: flipping the switch in
    /// System Settings must clear the menu row without a restart.
    func refreshNotificationAuthStatus() {
        guard Bundle.main.bundleIdentifier != nil else { return }  // see notify(): traps bundle-less
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationsDenied = settings.authorizationStatus == .denied
            }
        }
    }

    // MARK: menu

    // The poll timer runs in .common mode, so it keeps firing while the menu tracks; we use that
    // to live-update the per-session elapsed clocks. menuNeedsUpdate rebuilds the rows on each open.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // Async by nature, so the answer lands a beat after menuNeedsUpdate has built the rows —
        // it serves the NEXT open. Fresh enough: the launch-time check covers the first one.
        refreshNotificationAuthStatus()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        sessionMenuItems.removeAll()
        mcpCountLabels.removeAll()   // they capture menu items that are about to be discarded
    }

    // The session SET only changes on reopen (NSMenu can't add/remove rows reliably mid-track).
    func refreshOpenMenuRows() {
        let now = Date().timeIntervalSince1970
        for (item, id) in sessionMenuItems {
            guard let s = sessions[id], let v = item.view as? SessionRowView else { continue }
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            configureSessionRow(v, s, eff: eff)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        mcpCountLabels.removeAll()
        // Opening the menu is the moment the picture gets looked at, so it is the moment to
        // notice it has gone stale. Not on EVERY open, though: a check costs about 34 seconds
        // and nearly all of it is `claude mcp list`, which starts every configured MCP server
        // and waits for each to answer. Two minutes means a burst of opens costs one check.
        if !mcpBusy, Date().timeIntervalSince1970 - mcp.checkedAt > Self.mcpOpenStaleAfter {
            refreshMCP()
        }
        // A sleeping Mac misses timer ticks, so the five-minute cadence can silently become an
        // hour. Opening the menu is the moment the figures get looked at — worth a poll if the
        // reading is older than the timer could explain.
        if Date().timeIntervalSince1970 - (limits?.ts ?? 0) > 600 { pollLimits() }
        checkForUpdate() // refreshes the update cache for next open (gated to once a day)

        // Branches otherwise refresh only on hook events, so re-read on open (one tiny file read per
        // session) to catch a checkout made while a session sat idle.
        for (id, s) in sessions where !s.cwd.isEmpty {
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }  // recheck non-git: may have been git-init'd since
            var u = s; u.branch = branchForCwd(u.cwd); sessions[id] = u
        }

        sessionMenuItems.removeAll()
        let now = Date().timeIntervalSince1970
        // Gate ONLY the desktop app: opening/clicking a conversation there seeds an idle session without
        // real activity (the click-through clutter), so a desktop session stays out of the dropdown until
        // a prompt/tool fires (started=true). CLI / terminal / editor sessions are launched deliberately,
        // so they surface the moment they start. Any active state counts as started too (and covers
        // pre-upgrade files with no flag).
        let allOrdered = sessions.values.sorted { $0.ts > $1.ts }   // most-recent first
        let ordered = allOrdered.filter { s in
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
                let gated = s.entrypoint == "claude-desktop"   // only the desktop app is gated
                return !gated || s.started || !resting
            }
        // Hide rows idle past the threshold, but ALWAYS keep the most-recent started session (floor at
        // one) so the dropdown never goes empty while a session is alive. Hiding is render-only; the file
        // (and thus liveness) is untouched — see stalePruneAge and the pid-driven reap in evaluate().
        var visible = ordered.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }   // floor: never empty while alive

        if !visible.isEmpty {
            menu.addItem(header("Sessions"))
            for s in visible {
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let view = SessionRowView(id: s.id, width: CGFloat(uiConfig()["boxWidth"] ?? 300))
                let sid = s.id, ep = s.entrypoint, tp = s.termProgram, tb = s.termBundle
                view.onClick = { [weak self] in menu.cancelTracking(); self?.openSession(sid, entrypoint: ep, termProgram: tp, termBundle: tb) }
                configureSessionRow(view, s, eff: eff)
                let it = NSMenuItem()
                let tag = surfaceTag(s)
                it.title = sessionMenuLine(s) + (s.pct.map { "  ctx \($0)%" } ?? "")
                    + (tag.isEmpty ? "" : "  " + tag)
                it.view = view
                menu.addItem(it)
                sessionMenuItems.append((it, s.id))  // kept so tick() can live-update the timers
            }
            menu.addItem(.separator())
        } else if claudeDesktopRunning() {
            // No live session to pin, but the desktop app is up — give a way to jump back in.
            menu.addItem(header("Sessions"))
            let open = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        }

        addLimitsSection(to: menu)
        addMCPSection(to: menu)

        menu.addItem(.separator())
        menu.addItem(header("Options"))
        menu.addItem(toggleRow(title: "Show timer", isOn: showTimer) { [weak self] on in
            self?.showTimer = on
            UserDefaults.standard.set(on, forKey: "showTimer")
            self?.applyTitle()
        })
        menu.addItem(toggleRow(title: "Thinking words", isOn: useThinkingWords) { [weak self] on in
            self?.useThinkingWords = on
            UserDefaults.standard.set(on, forKey: "thinkingWords")
            self?.evaluate()   // re-render the bar label immediately with/without the rotating word
        })
        // Off is a real choice here, not decoration: the poll authenticates with the user's own
        // Claude OAuth token (sent to api.anthropic.com and nowhere else). Switching it back on
        // polls immediately — waiting up to five minutes to see the effect of a click reads as
        // the click having failed.
        menu.addItem(toggleRow(title: "Limits via Anthropic API", isOn: oauthLimits) { [weak self] on in
            self?.oauthLimits = on
            UserDefaults.standard.set(on, forKey: "oauthLimits")
            if on { self?.pollLimits() }
        })

        let animParent = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let animSub = NSMenu()
        for (style, name) in [(AnimStyle.web, "Claude Spark"), (AnimStyle.code, "Claude Code"), (AnimStyle.crab, "Crab Walking")] {
            let it = NSMenuItem(title: name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            animSub.addItem(it)
        }
        animParent.submenu = animSub
        menu.addItem(animParent)

        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (sys, name) in [(false, "Orange"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            colorSub.addItem(it)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)

        let soundParent = NSMenuItem(title: "Completion Sound", action: nil, keyEquivalent: "")
        let soundSub = NSMenu()
        for (secs, name) in [(0.0, "Off"), (0.1, "Every turn"), (60.0, "1 min+"), (300.0, "5 min+"), (900.0, "15 min+")] {
            let it = NSMenuItem(title: name, action: #selector(chooseSound(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: secs)
            it.state = soundThreshold == secs ? .on : .off
            soundSub.addItem(it)
        }
        soundParent.submenu = soundSub
        menu.addItem(soundParent)

        menu.addItem(.separator())
        let recheck = NSMenuItem(title: mcpBusy ? "Checking MCP…" : "Check MCP now",
                                 action: #selector(refreshMCP), keyEquivalent: "r")
        recheck.target = self
        recheck.isEnabled = !mcpBusy
        menu.addItem(recheck)
        let settings = NSMenuItem(title: "Open settings.json", action: #selector(openSettingsJSON),
                                  keyEquivalent: "")
        settings.target = self
        settings.toolTip = "Every server and tool switch is written here"
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        // Checked before the download line and instead of it: when the newer copy is already on
        // disk there is nothing left to fetch, and offering "Update to 0.5.1" next to a 0.5.1
        // bundle sends the user to download what they installed an hour ago.
        if let onDisk = installedVersion, Self.versionIsNewer(onDisk, than: currentVersion) {
            let it = NSMenuItem(title: "Restart to finish updating",
                                action: #selector(restartIntoInstalledCopy), keyEquivalent: "")
            it.target = self
            it.toolTip = "\(onDisk) is already installed. macOS keeps the copy that was running"
                + " when it was replaced, so this one is still \(currentVersion) until it restarts."
            menu.addItem(it)
        } else if let latest = UserDefaults.standard.string(forKey: "latestVersion"), Self.versionIsNewer(latest, than: currentVersion) {
            let width = CGFloat(uiConfig()["boxWidth"] ?? 300)
            let brewVer = UserDefaults.standard.string(forKey: "brewCaskVersion")
            if brewManaged {
                // Silent until the cask catches up (autobump lag): never offer a command that
                // would report "already up to date".
                if let bv = brewVer, Self.versionIsNewer(bv, than: currentVersion) {
                    let title = "Update available"
                    let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    it.view = CopyRowView(title: title, command: brewUpgradeCommand, width: width)
                    menu.addItem(it)
                }
            } else if canBuildFromSource {
                // With a Swift toolchain on the machine the update is one click: the release
                // source is downloaded and built in place — no DMG, no Gatekeeper (the binary is
                // compiled locally, quarantine never applies). A nil action while the build runs
                // is what greys the row out under autoenablesItems.
                let up = NSMenuItem(title: selfUpdating ? "Updating to \(latest)…" : "Update to \(latest)",
                                    action: selfUpdating ? nil : #selector(selfUpdate), keyEquivalent: "")
                up.target = self
                up.toolTip = selfUpdating
                    ? "Downloading and rebuilding in place — the app restarts itself when done."
                    : "\(latest) is out — this copy is \(currentVersion). One click downloads the"
                        + " release source, rebuilds this app in place (about a minute) and"
                        + " restarts it. Errors land in ~/.claude/control-bar/problems.log."
                menu.addItem(up)
            } else {
                // The version number lives in the tooltip, not the title: the line above already
                // says which version is running, and a second number beside it reads as a riddle.
                let up = NSMenuItem(title: "Update available", action: #selector(openLatestRelease), keyEquivalent: "")
                up.target = self
                up.toolTip = "\(latest) is out — this copy is \(currentVersion)"
                menu.addItem(up)
                // Only once the cask actually exists. brewCaskVersion is written solely by a
                // successful cask-API response, so while the cask is unpublished the key is
                // absent — and the row would be handing out a command that is guaranteed to
                // fail with "cask not found".
                if brewVer != nil {
                    let sw = NSMenuItem(title: "Switch to Homebrew", action: nil, keyEquivalent: "")
                    sw.view = CopyRowView(title: "Switch to Homebrew", command: brewInstallCommand, width: width)
                    menu.addItem(sw)
                }
            }
        }
        if notificationsDenied {
            let n = NSMenuItem(title: "Notifications are off — open System Settings",
                               action: #selector(openNotificationSettings), keyEquivalent: "")
            n.target = self
            n.toolTip = "macOS asks once per app, ever. Alerts like \"MCP server went down\" stay"
                + " muted until notifications are switched back on in System Settings."
            menu.addItem(n)
        }
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    // Files & Folders — the pane holding the per-app network-volumes switch. Same undocumented
    // scheme as the notifications pane below; the bare Privacy pane is the fallback.
    @objc func openFilesPrivacySettings() {
        for link in ["x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
                     "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
        NSLog("ClaudeControlBar: privacy settings pane did not open")
    }

    // Deep link into this app's own Notifications pane. URL(string:) only checks syntax; whether
    // the pane id still resolves is decided by System Settings at open() — the scheme is
    // undocumented and has shifted between macOS releases — so a failed open falls back to
    // Settings' root: a landing page and a Console trace instead of a click that does nothing.
    @objc func openNotificationSettings() {
        var link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier { link += "?id=" + id }
        if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        NSLog("ClaudeControlBar: notification settings pane did not open")
        if let root = URL(string: "x-apple.systempreferences:com.apple.systempreferences") {
            NSWorkspace.shared.open(root)
        }
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func toggleRow(title: String, qualifier: String? = nil, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = CGFloat(uiConfig()["boxWidth"] ?? 300), height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.autoresizingMask = [.width]

        let labelFont = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = labelFont
        label.textColor = .labelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: leftInset, y: (height - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        let toggle = ToggleView(isOn: isOn)
        toggle.onToggle = onToggle
        let toggleX = width - toggle.frame.width - rightInset
        toggle.setFrameOrigin(NSPoint(x: toggleX, y: (height - toggle.frame.height) / 2))
        toggle.autoresizingMask = [.minXMargin]
        row.addSubview(toggle)

        // Optional trailing qualifier ("5 min+") pinned just left of the toggle, in the SAME font/size/color
        // and right-alignment as the session-row timer, so the two read as the same kind of trailing note.
        if let qualifier = qualifier {
            let qW: CGFloat = 74, gap: CGFloat = 8
            let q = NSTextField(labelWithString: qualifier)
            q.font = NSFont.monospacedSystemFont(ofSize: labelFont.pointSize - 2, weight: .regular)
            q.textColor = .secondaryLabelColor
            q.alignment = .right
            q.frame = NSRect(x: toggleX - gap - qW, y: (height - 16) / 2, width: qW, height: 16)
            q.autoresizingMask = [.minXMargin]
            row.addSubview(q)
        }

        let item = NSMenuItem()
        item.view = row
        return item
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff  // cached by evaluate() each tick
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed.
        var line = truncated(sessionName(s))
        if !s.branch.isEmpty { line += " · " + truncated(s.branch, max: 22, keep: 20) }
        if eff == "thinking" || eff == "tool", s.startedAt > 0 {
            line += "  " + elapsed(max(0, Int(now - s.startedAt)))
        }
        return line
    }

    // Live layout knobs read fresh from ~/.claude/control-bar/uiconfig.json each render, so numeric
    // tweaks (timer column, pill offset, gap) take effect on the next menu open with NO rebuild.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/uiconfig.json")
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func configureSessionRow(_ v: SessionRowView, _ s: Session, eff: String) {
        let cfg = uiConfig()
        let now = Date().timeIntervalSince1970
        // Generous cap: the row's pixel truncation does the real limiting now that the name field
        // sizes to the free space; this only guards against pathological strings.
        let nameMax = Int(cfg["nameMax"] ?? 30)
        let working = (eff == "thinking" || eff == "tool") && s.startedAt > 0
        let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")  // the dim caret
        let tag = surfaceTag(s)
        v.configure(icon: sessionSymbol(s, eff: eff),
                    iconTint: resting ? .tertiaryLabelColor : .labelColor,  // caret dim; spinner matches the name font; amber image ignores tint
                    spinning: (eff == "thinking" || eff == "tool"),
                    name: truncated(sessionName(s), max: nameMax, keep: nameMax),
                    branch: truncated(s.branch, max: 22, keep: 20),
                    timer: working ? elapsed(max(0, Int(now - s.startedAt))) : nil,
                    context: s.pct, contextAssumed: s.assumed,
                    pillNormal: tag.isEmpty ? nil : pillImage(tag),
                    pillSelected: tag.isEmpty ? nil : pillImage(tag, selected: true),
                    pillInset: CGFloat(cfg["pillInset"] ?? 12),
                    timerGap: CGFloat(cfg["timerGap"] ?? 10))
        // Truncated rows stay inspectable: full name, branch, and path on hover.
        var tip = sessionName(s)
        if !s.branch.isEmpty { tip += " · " + s.branch }
        if let pct = s.pct, let tokens = s.tokens, let window = s.window {
            tip += "\ncontext \(pct)% — \(Self.grouped(tokens)) of \(Self.grouped(window)) tokens"
            if !s.model.isEmpty { tip += " · " + s.model }
            if s.assumed { tip += "\nwindow size inferred, not reported by this model" }
        }
        if !s.cwd.isEmpty { tip += "\n" + s.cwd }
        v.toolTip = tip
    }

    func statusText(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission":       return "Awaiting permission"
        case "thinking", "tool": return workingLabel(s)
        default:                 return s.state == "done" ? "Done" : "Idle"
        }
    }

    // Just the repo/cwd (parent-qualified on a name collision); the surface (CLI/APP) renders as a
    // trailing badge instead of inline.
    func sessionName(_ s: Session) -> String {
        if !s.displayName.isEmpty { return s.displayName }
        return s.project.isEmpty ? "session" : s.project
    }

    // CLAUDE_CODE_ENTRYPOINT (+ TERM_PROGRAM) -> a short all-caps badge tag, one uniform
    // 3-letter pill per surface. APP is the desktop app. IDE is a session living inside an
    // editor — the Claude Code extension panel (entrypoint "claude-vscode") or the CLI in a
    // VS Code-family integrated terminal (Cursor, Windsurf and VS Code all report
    // TERM_PROGRAM="vscode"). CLI is a standalone terminal (Apple_Terminal, iTerm.app, …).
    func surfaceTag(_ s: Session) -> String {
        if s.entrypoint == "claude-desktop" { return "APP" }
        if s.entrypoint.isEmpty { return "" }
        if s.entrypoint == "claude-vscode" || s.termProgram == "vscode" { return "IDE" }
        return "CLI"
    }

    // CLI/APP pill rendered as an image so it can sit inside the row text (right after the timer)
    // rather than as a system badge pinned to the menu edge with a fixed, uncloseable gap.
    func pillImage(_ text: String, selected: Bool = false) -> NSImage {
        let t = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)  // mono -> 3 chars = uniform width
        let pad: CGFloat = 7, h: CGFloat = 15
        let cfg = uiConfig()
        let dy = CGFloat(cfg["pillTextY"] ?? -1)  // negative nudges the text down (it reads top-heavy)
        // Pill bg is a tunable gray per mode (black-on-light / white-on-dark at a low alpha) so light
        // mode can be lightened independently. On a selected (blue) row it's a light translucent pill.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bgAlpha = CGFloat(cfg[dark ? "pillBgDark" : "pillBgLight"] ?? (dark ? 0.14 : 0.10))
        let bg = selected ? NSColor.white.withAlphaComponent(0.22)
                          : (dark ? NSColor.white : NSColor.black).withAlphaComponent(bgAlpha)
        let fg = selected ? NSColor.white : NSColor.labelColor
        let w = ceil(t.size(withAttributes: [.font: font]).width) + pad * 2
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let ts = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2 + dy), withAttributes: a)
            return true
        }
    }

    func sessionSymbol(_ s: Session, eff: String) -> NSImage? {
        switch eff {
        case "permission":       return symbolImage("exclamationmark.circle.fill", tint: amber)
        case "thinking", "tool": return nil
        default:                 return restingCaret   // done/idle merged: dim "ready for input" caret
        }
    }

    // The shell-style prompt caret (U+276F, what Claude Code shows when idle), dimmed and centered in
    // a square that matches the spinner gutter so the resting rows align with the working ones.
    lazy var restingCaret: NSImage? = {
        let glyph = "\u{276F}" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let side: CGFloat = 15
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let g = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: (side - g.width) / 2, y: (side - g.height) / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true   // tint via contentTintColor: dim (tertiary) normally, white on hover
        return img
    }()

    func symbolImage(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let tint = tint, #available(macOS 12.0, *) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        img.isTemplate = true
        return img
    }

    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        s.count > max ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` only ever yields
    // permission / thinking / tool / idle (done collapses to idle; waiting is never emitted).
    func priority(of eff: String) -> Int {
        switch eff {
        case "permission":       return 2
        case "thinking", "tool": return 1
        default:                 return 0   // idle / unknown
        }
    }

    func workingLabel(_ s: Session) -> String {
        // Off means no word, not a duller word. It used to fall through to the hook's own label,
        // so unchecking "Thinking words" left the bar reading "Thinking…" — indistinguishable
        // from the switch doing nothing, and reported as exactly that. The icon already says
        // Claude is working and the timer says for how long.
        guard useThinkingWords else { return "" }
        if s.state == "thinking", let w = sessionWord[s.id], !w.isEmpty { return w + "…" }
        if !s.label.isEmpty { return s.label }
        return s.state == "tool" ? "Working…" : "Thinking…"
    }

    // Re-pick a word each time a session ENTERS the thinking state (prompt, or a tool->thinking `post`),
    // avoiding an immediate repeat, so a tool round-trip lands a different word. Held steady while the
    // session stays thinking. Computed regardless of the toggle so flipping it on shows instantly.
    func updateThinkingWord(_ s: Session) {
        let prev = prevState[s.id] ?? ""
        guard s.state == "thinking", prev != "thinking" else { return }
        var w = thinkingWords.randomElement() ?? "Thinking"
        if thinkingWords.count > 1 { while w == sessionWord[s.id] { w = thinkingWords.randomElement() ?? w } }
        sessionWord[s.id] = w
    }

    static func describe(_ menu: NSMenu, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        return menu.items.map { item -> String in
            if item.isSeparatorItem { return pad + "──" }
            var line = pad + (item.title.isEmpty ? item.attributedTitle?.string ?? "" : item.title)
            if let tip = item.toolTip { line += "   [tip: " + tip.replacingOccurrences(of: "\n", with: " ⏎ ") + "]" }
            if let sub = item.submenu { line += "\n" + describe(sub, depth: depth + 1) }
            return line
        }.joined(separator: "\n")
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "   // thin, language-neutral: 154 452 reads the same everywhere
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // "1m 1s" / "43s" — Claude Code's elapsed-clock style.
    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    // The marker keeps update.js's self-relaunch from undoing an explicit Quit; cleared on the
    // next SessionStart (lifecycle.js) or the next manual launch (below), whichever comes first.
    @objc func quit() {
        // NSApp.terminate tears down our threads but NOT the spawned build — bash and its
        // compilers would be orphaned, finish minutes later and swap the bundle with nobody
        // left to restart into it. Ending the child turns that into an ordinary failed build.
        updateBuild?.terminate()
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/quit-intent")
        FileManager.default.createFile(atPath: marker, contents: nil)
        NSApp.terminate(nil)
    }

    @objc func openClaude() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Row click. Desktop session: switch the app to THAT conversation (see DesktopSessions).
    // Merely focusing the app was the bug — it is normally frontmost already, so every row did
    // nothing visible and all of them did the same nothing. Focusing the app is still the
    // fallback for a conversation this machine has no record of.
    // CLI session: bring its terminal APP to the front (zero permission). Targeting the exact
    // window/tab needs a one-time Automation grant, deferred to the opt-in build (issue #19).
    func openSession(_ id: String, entrypoint: String, termProgram: String, termBundle: String) {
        if entrypoint == "claude-desktop" {
            guard let local = DesktopSessions.sessionID(forCLI: id),
                  let url = DesktopSessions.focusURL(sessionID: local)
            else { openClaude(); return }
            NSWorkspace.shared.open(url)
            return
        }
        // The hooks record __CFBundleIdentifier, which names the exact hosting app — the
        // TERM_PROGRAM map below cannot: Cursor, Windsurf and VS Code all report "vscode"
        // (so the click opened the wrong editor), and the IDE extension panel sets no
        // TERM_PROGRAM at all (so the click did nothing). `open -b` takes the id verbatim.
        if !termBundle.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-b", termBundle]
            try? p.run()
            return
        }
        // Map TERM_PROGRAM to a name `open -a` understands; most terminals match verbatim.
        let app: String
        switch termProgram {
        case "Apple_Terminal": app = "Terminal"
        case "iTerm.app":      app = "iTerm"
        case "vscode":         app = "Visual Studio Code"
        case "WarpTerminal":   app = "Warp"
        case "":               return  // unknown surface, nothing to focus
        default:               app = termProgram  // Ghostty, WezTerm, Tabby, Hyper, kitty, …
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        try? p.run()
    }


    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate() // re-render the current state in the new color
    }

    @objc func chooseSound(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        soundThreshold = n.doubleValue
        UserDefaults.standard.set(soundThreshold, forKey: "soundThreshold")
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        evaluate()
    }

    // MARK: state polling

    func tick() {
        // Whether to quit is not a four-times-a-second question — the decision behind it is
        // debounced by idleQuitDelay anyway, so checking at this rate only bought the app a
        // steady CPU cost for an answer that cannot change meaningfully between looks.
        let now = Date().timeIntervalSince1970
        if now - lastLifecycleCheck >= 2 {
            lastLifecycleCheck = now
            checkLifecycle()
        }
        reloadSessions()
        // Both are mtime checks against a file another process rewrites atomically, so this is
        // a stat() per tick, not a parse — the parse happens only when something actually moved.
        if mcp.reloadIfChanged() {
            notifyMCPChange()
            if menuIsOpen { refreshCounts() }
        }
        loadLimits()
        evaluate()
        if menuIsOpen { refreshOpenMenuRows() }
    }

    /// Bars ride in the same status item as the icon. A second status item would be cleaner to
    /// build and cost another ~33pt of a menu bar that, on this machine, is already ~220pt past
    /// what fits beside the notch — and overflow there does not clip, it disappears.
    func decorate(_ icon: NSImage?) -> NSImage? {
        let gauge = currentGauge()
        guard !gauge.isEmpty else { return icon }
        return gauge.image(icon: icon)
    }

    func currentGauge() -> Gauge {
        Gauge(fiveHour: limits?.fiveHour.map { Double($0) / 100 },
              sevenDay: limits?.sevenDay.map { Double($0) / 100 })
    }

    // The .json session files currently in state.d/ (ignores the .tmp files mid-write).
    func stateFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? []).filter { $0.hasSuffix(".json") }
    }

    // Refresh `sessions` from state.d/, re-parsing only files whose mtime changed (writes are
    // atomic renames, so a content update bumps mtime and is never read torn).
    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFileNames()
        let present = Set(files)
        for key in Array(fileMTimes.keys) where !present.contains(key) {
            fileMTimes[key] = nil
            sessions[(key as NSString).deletingPathExtension] = nil
        }
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if fileMTimes[f] == m { continue }
            fileMTimes[f] = m
            guard let data = fm.contents(atPath: full),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = (f as NSString).deletingPathExtension
            var s = Session(json: o, id: id)
            // A hook event means activity in that cwd, which may have JUST become a repo (git init /
            // first branch mid-session) — a cached "" (non-git) would otherwise stick until app restart.
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }
            s.branch = branchForCwd(s.cwd)   // only on file change (a hook event), never on a bare tick
            sessions[id] = s
        }
    }

    // MARK: git branch (no `git` spawn — .git/HEAD is a tiny text file)

    // Resolve <cwd>'s HEAD path by walking toward /. A worktree/submodule has .git as a FILE
    // containing "gitdir: <path>". Resolution walks directories, so cache it per cwd; a cached
    // "" means confirmed non-git. Dropped by branchForCwd if the HEAD read later fails.
    func gitHeadPath(_ cwd: String) -> String? {
        if let hit = gitHeadCache[cwd] { return hit.isEmpty ? nil : hit }
        let fm = FileManager.default
        var dir = cwd, isDir: ObjCBool = false
        for _ in 0..<40 {
            let g = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: g, isDirectory: &isDir) {
                var head: String? = nil
                if isDir.boolValue {
                    head = (g as NSString).appendingPathComponent("HEAD")
                } else if let d = fm.contents(atPath: g), d.count <= 4096,
                          let s = String(data: d, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    var gd = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    if !gd.hasPrefix("/") { gd = ((dir as NSString).appendingPathComponent(gd) as NSString).standardizingPath }
                    head = (gd as NSString).appendingPathComponent("HEAD")
                }
                gitHeadCache[cwd] = head ?? ""
                return head
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        gitHeadCache[cwd] = ""
        return nil
    }

    // HEAD is "ref: refs/heads/<branch>" on a branch, a bare commit hash when detached.
    // nil (no branch text, no error) for non-git dirs and anything unrecognized.
    func branchForCwd(_ cwd: String) -> String {
        guard !cwd.isEmpty, let headPath = gitHeadPath(cwd) else { return "" }
        guard let d = FileManager.default.contents(atPath: headPath), d.count <= 1024,
              let s = String(data: d, encoding: .utf8) else {
            gitHeadCache[cwd] = nil   // stale resolution (repo moved/deleted) — retry next time
            return ""
        }
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        if head.hasPrefix("ref: ") { return ((head as NSString).lastPathComponent) }
        if (40...64).contains(head.count), head.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return String(head.prefix(7))   // detached HEAD -> short SHA
        }
        return ""
    }

    // Working->done edge for the completion chime, gated on turn length >= soundThreshold (0 = off).
    // Reads prevState, which the evaluate() loop writes only AFTER this runs, so it must be called
    // there before that write. Tracks the turn's start while the session is working.
    func completionEdge(_ s: Session, now: Double) -> Bool {
        if s.state == "thinking" || s.state == "tool", s.startedAt > 0 { turnStart[s.id] = s.startedAt }
        let prev = prevState[s.id] ?? ""
        var edge = false
        if soundThreshold > 0, s.state == "done", prev != "done", let st = turnStart[s.id], st > 0, now - st >= soundThreshold { edge = true }
        if s.state == "done" { turnStart[s.id] = 0 }
        return edge
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        var chime = false

        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            s.eff = effectiveState(s, now: now)   // compute once per tick; the menu + tooltip reuse it
            // Reap on PROCESS death, not idle time: a session leaves only when its `claude` process is
            // gone (closed/crashed terminal, quit app), so an idle-but-open session stays and the icon
            // holds. Pre-upgrade files have no pid (0) — fall back to the old idle+age prune so they
            // can't linger forever. This is also what keeps state.d self-cleaning (no growing cache).
            let dead = s.pid > 0 ? !pidAlive(s.pid)
                                 : (s.eff == "idle" && stalePruneAge > 0 && now - s.ts > stalePruneAge)
            if dead {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                sessions[id] = nil; fileMTimes[id + ".json"] = nil; prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil
                if !s.transcript.isEmpty { turnLineCache[s.transcript] = nil }  // keyed by path, not id
                continue
            }
            sessions[id] = s
            updateThinkingWord(s)
            if completionEdge(s, now: now) { chime = true }
            prevState[s.id] = s.state
        }
        for id in Array(prevState.keys) where sessions[id] == nil { prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil }
        if chime { completionSound?.play() }

        // Same-named projects (two clones/worktrees of one repo) get a parent-folder qualifier
        // ("work/myrepo" vs "tmp/myrepo") so their rows stay tellable apart. Runs after the reap so
        // dead sessions can't force a qualifier onto a now-unique name.
        // Only non-empty cwds count as colliding locations: a pre-upgrade/warmup file without cwd is
        // location-unknown, and counting its "" as a distinct place forced a bogus qualifier onto a
        // genuinely unique row.
        var cwdsByProject: [String: Set<String>] = [:]
        for s in sessions.values where !s.project.isEmpty && !s.cwd.isEmpty { cwdsByProject[s.project, default: []].insert(s.cwd) }
        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            if !s.cwd.isEmpty, (cwdsByProject[s.project]?.count ?? 0) > 1 {
                let parent = (((s.cwd as NSString).deletingLastPathComponent) as NSString).lastPathComponent
                s.displayName = parent.isEmpty ? s.project : parent + "/" + s.project
            } else {
                s.displayName = s.project
            }
            sessions[id] = s
        }

        // Surface the single highest-priority session (permission > working > …); ties broken by
        // recency, so within a tier the most recently active session wins.
        let lead = sessions.values.max { a, b in
            let pa = priority(of: a.eff), pb = priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // names repo + surface + state on hover

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: statusText(lead, eff: lead.eff), color: amber, animate: false, startedAt: 0, dot: true)
        case "thinking", "tool":
            render(label: statusText(lead, eff: lead.eff), color: iconColor, animate: true, startedAt: lead.startedAt)
        default:
            renderResting()
        }
    }

    func renderResting() { render(label: "", color: iconColor, animate: false, startedAt: 0) }

    // Per-session effective state with two recovery nets: an absolute age cap, plus the transcript
    // "interrupted by user" marker (Esc / denied permission fire no hook, freezing the file). "done"
    // collapses to rest.
    func effectiveState(_ s: Session, now: Double) -> String {
        if s.state == "thinking" || s.state == "tool" || s.state == "permission" {
            // 30 minutes for permission, not the 2 hours it once was: with the transcript nets
            // below this is a last resort, and a frozen amber dot outranks every live session.
            let cap: Double = s.state == "permission" ? 1800 : 900
            if now - s.ts > cap { return "idle" }
            if !s.transcript.isEmpty {
                let facts = turnFacts(ofFileAt: s.transcript)
                if facts.interrupted { return "idle" }
                // While a permission prompt waits, the transcript is silent — the tool_use that
                // opened it is already on disk. So a turn record younger than the prompt means
                // the prompt was answered, whatever form the answer took: deny and Esc write
                // one without firing any hook. +2s keeps that same tool_use record, stamped in
                // the prompt's own second, from ending the wait it started. Permission only:
                // thinking/tool sessions append turn records as part of normal work (measured
                // median gap 1.7s), so the same test there would idle a session mid-stride.
                if s.state == "permission", let t = facts.turnTs, t > s.ts + 2 { return "idle" }
            }
            return s.state
        }
        return s.state == "done" ? "idle" : s.state
    }


    // MARK: self-quit lifecycle

    func claudeDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeDesktopBundleID }
    }

    func sessionCount() -> Int { stateFileNames().count }

    var claudeProbedAt: Double = 0
    var claudeWasRunning = false

    /// Is Claude Code itself running, whatever it has or has not written to disk?
    ///
    /// Only consulted when everything else says the app is not needed, and the answer is held for
    /// ten seconds — otherwise a session that writes no state file would have this walking the
    /// process table on every tick, forever.
    func claudeCodeRunning() -> Bool {
        let now = Date().timeIntervalSince1970
        if now - claudeProbedAt < 10 { return claudeWasRunning }
        claudeProbedAt = now
        claudeWasRunning = RunningProcesses.exists(named: "claude")
        return claudeWasRunning
    }

    // Liveness probe: is this session's `claude` process still alive? kill(pid,0) returns 0 if the
    // process exists; EPERM = exists but not ours (won't happen, same user); ESRCH = gone.
    func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // Stay while Claude desktop is open OR a session is active; otherwise quit after a
    // short debounced grace (warmup-session churn must not kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        // Sessions first. Counting files in one directory is a directory read; the other side of
        // this `||` asks LaunchServices about every running application over IPC, and a sample of
        // the running app showed that one call was half of everything the timer did. In the case
        // that matters — Claude is working, so a session file exists — it is now never reached.
        if sessionCount() > 0 || claudeDesktopRunning() {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            // The process table gets the last word. A session whose hooks never fired — no node
            // on the PATH, hooks switched off, settings sources that skip the user's file —
            // leaves no state file, and quitting on that evidence killed the app ten seconds
            // after launch with Claude Code running in a terminal the whole time.
            guard now.timeIntervalSince(since) >= idleQuitDelay, !claudeCodeRunning() else { return }
            NSApp.terminate(nil)
        } else {
            notNeededSince = now
        }
    }

    // Read the last non-empty line of a (possibly large) file by tailing ~8KB.
    func lastLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last { !$0.isEmpty }.map(String.init)
    }

    // What the transcript's last turn line (a user/assistant message, ignoring the bookkeeping
    // Claude Code appends after an interrupt) says about the session: the interrupt marker, and
    // the record's timestamp. Both answers are computed when the file changes and cached — a
    // sampling pass once put the raw per-tick read among the timer's top costs, and parsing the
    // same unchanged line every tick is the same class of waste. One stat() per tick otherwise.
    func turnFacts(ofFileAt path: String) -> (interrupted: Bool, turnTs: Double?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        if let hit = turnLineCache[path], hit.size == size, hit.mtime == mtime {
            return (hit.interrupted, hit.turnTs)
        }
        let line = readLastTurnLine(ofFileAt: path)
        let interrupted = line.map(Transcript.wasInterrupted) ?? false
        let turnTs = line.flatMap(Transcript.turnTimestamp)
        // A record that parses as a turn but carries no usable timestamp is format drift — the
        // permission net below dies silently without it. Once per file change, not per tick, so
        // Console gets a trace instead of "sessions sometimes sit amber for the whole cap".
        if let line, turnTs == nil, Transcript.isTurnRecord(line) {
            NSLog("ClaudeControlBar: turn record without a parseable timestamp — transcript format drift? \(path)")
        }
        turnLineCache[path] = (size, mtime, interrupted, turnTs)
        return (interrupted, turnTs)
    }

    private func readLastTurnLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        // Escalating windows, 8 KB first: a streaming transcript invalidates the cache on every
        // append, so the hot path must stay at the old price — the last line there IS the turn
        // record. The larger reads pay only when the tail is all bookkeeping: Claude Code appends
        // it after an interrupt in lines measured up to 112 KB, and any fixed window is a bet
        // against the next release's line, so the ladder ends at a hard ceiling instead.
        for chunk: UInt64 in [8_192, 262_144, 1_048_576] {
            try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
            guard let data = try? fh.readToEnd() else { return nil }
            // Never the failable String(data:encoding:): a window cut mid-way through a multi-
            // byte character made it return nil for the ENTIRE chunk, and the cache then pinned
            // that nil for as long as the file sat still — a permission wait, by definition.
            let s = String(decoding: data, as: UTF8.self)
            if let line = s.split(separator: "\n").last(where: {
                $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"")
            }) { return String(line) }
            if size <= chunk { return nil }  // the whole file is read — there is nowhere left to look
        }
        return nil
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = decorate(dot ? dotIcon(color: color) : restingIcon(color: color))
        }
        applyTitle()
        if button.image == nil { button.image = decorate(dot ? dotIcon(color: color) : restingIcon(color: color)) }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = cachedIcon(frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    /// The animation cycles through a small fixed set of frames forever, and each one is a bitmap
    /// composite with the limit bars drawn over it. Rebuilding the same handful of images twenty
    /// times a second was a large part of what the app did while Claude worked.
    ///
    /// Everything that can change what a frame looks like is in the key — the appearance included,
    /// because a cached image must not outlive a switch between a light and a dark menu bar.
    func cachedIcon(frame: Int) -> NSImage? {
        let key = [animStyle.rawValue,
                   activeColor.map { "\($0)" } ?? "template",
                   currentGauge().signature,
                   NSApp.effectiveAppearance.name.rawValue].joined(separator: "|")
        if key != iconCacheKey {
            iconCacheKey = key
            iconCache.removeAll()
        }
        if let hit = iconCache[frame] { return hit }
        let made = decorate(iconImage(color: activeColor, frame: frame))
        iconCache[frame] = made
        return made
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        // Joined rather than concatenated: with the word switched off the old form left the
        // separator behind, so the bar read "  4m 12s" with a hole where the word had been.
        var parts: [String] = []
        if !activeBase.isEmpty { parts.append(activeBase) }
        if showTimer, startedAt > 0 {
            parts.append(elapsed(max(0, Int(Date().timeIntervalSince1970 - startedAt))))
        }
        let text = parts.joined(separator: "  ")
        // Assigning a title re-lays-out and redraws the whole status item. This is called on
        // every animation frame — twenty times a second — and the text it would write is the
        // same one nineteen times out of twenty, since the clock only moves once a second.
        guard text != renderedTitle else { return }
        renderedTitle = text
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        if animStyle == .web { return tint(frames, color: color, frame: frame) }
        if animStyle == .crab { return crabIcon(color: color, frame: frame) }
        let i = (frame / codeSub) % codeGlyphs.count
        let local = (CGFloat(frame % codeSub) + 0.5) / CGFloat(codeSub) // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = codeDip + (codePeaks[i] - codeDip) * env
        return codeIcon(color: color, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func codeIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard glyph < codeGlyphMasks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = codeGlyphMasks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage {
        if animStyle == .crab { return crabIcon(color: color, frame: 0) }
        return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0)
    }

    // nil color (System) => adaptive shaded template (see adaptiveCrabFrame in CrabRender.swift);
    // non-nil (Orange) => the original full-color sprite, drawn as-is.
    func crabIcon(color: NSColor?, frame: Int) -> NSImage {
        guard !crabFrames.isEmpty else { return NSImage(size: NSSize(width: 18, height: 18)) }
        let pool = color == nil ? crabTemplateFrames : crabFrames
        let src = pool[frame % pool.count]
        let rep = src.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(src.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(src.size.height))
        let h: CGFloat = 18, w = (ph > 0 ? h * (pw / ph) : h)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha (destinationIn) so frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
