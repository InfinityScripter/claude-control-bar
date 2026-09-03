import Cocoa

// How a session reads in the menu: the row view configuration, its symbols, labels and
// truncation, plus the per-session ranking the status item and the rows share.
extension StatusController {
    /// evaluate() caches the effective state on the session once per tick; anything that runs
    /// before that tick (a menu opened on a freshly read file) computes it on the spot.
    func effState(_ s: Session, now: Double) -> String {
        s.eff.isEmpty ? engine.effectiveState(s, now: now) : s.eff
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = effState(s, now: now)
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed. Same name length
        // as the drawn row (nameMax) so the accessible title and the pixels agree.
        var line = truncated(sessionName(s), max: 30, keep: 30)
        if !s.branch.isEmpty { line += " · " + truncated(s.branch, max: 22, keep: 20) }
        if isWorkingState(eff), s.startedAt > 0 {
            line += "  " + elapsed(max(0, (now - s.startedAt).clampedInt))
        }
        return line
    }

    // Live layout knobs from ~/.claude/control-bar/uiconfig.json (nameMax, pillInset, timerGap,
    // boxWidth), so numeric tweaks take effect on the next menu open with NO rebuild. Re-read only
    // when the file's mtime moves: this runs for every row on every tick while the menu is open,
    // and parsing the same file three times per row at 2.5 Hz was the one uncached I/O on that path.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/uiconfig.json")
        let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        if let cached = uiConfigCache, cached.mtime == m { return cached.values }
        var values: [String: Double] = [:]
        if let d = FileManager.default.contents(atPath: p),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            values = j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        uiConfigCache = (m, values)
        return values
    }

    var boxWidth: CGFloat { CGFloat(uiConfig()["boxWidth"] ?? 300) }

    func configureSessionRow(_ v: SessionRowView, _ s: Session, eff: String) {
        let cfg = uiConfig()
        let now = Date().timeIntervalSince1970
        // Generous cap: the row's pixel truncation does the real limiting now that the name field
        // sizes to the free space; this only guards against pathological strings.
        let nameMax = (cfg["nameMax"] ?? 30).clampedInt
        let working = isWorkingState(eff) && s.startedAt > 0
        let resting = !isActiveState(eff)  // the dim caret
        let tag = surfaceTag(s)
        v.configure(icon: sessionSymbol(s, eff: eff),
                    iconTint: resting ? .tertiaryLabelColor : .labelColor,  // caret dim; spinner matches the name font; amber image ignores tint
                    spinning: isWorkingState(eff),
                    name: truncated(sessionName(s), max: nameMax, keep: nameMax),
                    branch: truncated(s.branch, max: 22, keep: 20),
                    timer: working ? elapsed(max(0, (now - s.startedAt).clampedInt)) : nil,
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

    // Only ever asked for an active state: a resting lead renders the bare icon, no text.
    func statusText(_ s: Session, eff: String) -> String {
        eff == "permission" ? "Needs you" : workingLabel(s)
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


    func symbolImage(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let tint = tint, #available(macOS 12.0, *) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        img.isTemplate = true
        return img
    }

    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    // Clamped at zero: `keep` arrives from uiconfig.json (a hand-tuning file), and String.prefix
    // TRAPS on a negative length — "nameMax": -1 typed there crashed every menu open, straight
    // into the hooks' relaunch loop. The one file-fed number that reached a trapping stdlib call.
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        let keep = Swift.max(0, keep)
        return s.count > Swift.max(max, keep) ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` only ever yields
    // permission / thinking / tool / idle (done collapses to idle; waiting is never emitted).
    func priority(of eff: String) -> Int {
        eff == "permission" ? 2 : (isWorkingState(eff) ? 1 : 0)   // idle / unknown = 0
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
}
