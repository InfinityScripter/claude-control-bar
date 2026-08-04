import Cocoa

/// A menu row that toggles in place. A plain NSMenuItem closes the menu when clicked, so muting
/// five tools in a row meant opening the menu five times. This one handles the click itself: the
/// menu stays open and the switch animates immediately.
///
/// The whole row is the target, not just the switch — a 33pt switch at the end of a long tool
/// name is a small thing to hit repeatedly.
final class MCPRowView: NSView {
    private let highlight = NSVisualEffectView()
    private let mark = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let chevron = NSTextField(labelWithString: "\u{203A}")
    private let spinner = SpinnerView(size: 13)
    private let toggle: ToggleView
    private let onHover: ((NSView) -> Void)?
    private let hasChevron: Bool
    private let rowH: CGFloat = 24
    private var hovered = false
    private var markX: CGFloat = 0

    init(mark glyph: String?, markColor: NSColor, title: String, trailing tail: String,
         isOn: Bool, indent: CGFloat, width: CGFloat, enabled: Bool = true, chevron showChevron: Bool = false,
         spinning: Bool = false,
         onHover: ((NSView) -> Void)? = nil, onToggle: @escaping (Bool) -> Void) {
        self.hasChevron = showChevron
        self.toggle = ToggleView(isOn: isOn)
        self.onHover = onHover
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]

        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.isHidden = true
        addSubview(highlight)

        // A tool row has no glyph at all: the switch on the right already says on or off, and a
        // tick that repeats it is one more thing to keep in sync — and it did fall out of sync,
        // staying green under a switch the user had just turned off.
        let markW: CGFloat = glyph == nil ? 0 : 18
        if let glyph {
            mark.stringValue = glyph
            mark.font = .systemFont(ofSize: 12)
            mark.textColor = markColor
            mark.sizeToFit()
            mark.setFrameOrigin(NSPoint(x: indent, y: (rowH - mark.frame.height) / 2))
            markX = indent
            addSubview(mark)
        }

        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        label.textColor = enabled ? .labelColor : .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: indent + markW, y: (rowH - 16) / 2, width: 100, height: 16)
        label.autoresizingMask = [.maxXMargin]
        addSubview(label)

        toggle.onToggle = onToggle
        toggle.isEnabled = enabled
        toggle.autoresizingMask = [.minXMargin]
        addSubview(toggle)

        trailing.stringValue = tail
        trailing.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        trailing.textColor = .secondaryLabelColor
        trailing.alignment = .right
        trailing.autoresizingMask = [.minXMargin]
        addSubview(trailing)

        spinner.autoresizingMask = [.minXMargin]
        addSubview(spinner)
        spinner.setActive(spinning)

        // Drawn by hand rather than left to AppKit: an item with a custom view gets no submenu
        // arrow of its own. Without it a server needed a second row just to say "there is more
        // in here", which doubled the length of the whole section.
        if showChevron {
            chevron.font = .systemFont(ofSize: 13)
            chevron.textColor = .tertiaryLabelColor
            chevron.autoresizingMask = [.minXMargin]
            addSubview(chevron)
        }

        layoutRow(width: width)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Laid out right to left: switch, chevron, count, and the name takes whatever is left.
    private func layoutRow(width: CGFloat) {
        let rightInset: CGFloat = 12, gap: CGFloat = 8, chevronW: CGFloat = 12
        let toggleX = width - toggle.frame.width - rightInset
        toggle.setFrameOrigin(NSPoint(x: toggleX, y: (rowH - toggle.frame.height) / 2))
        var right = toggleX
        if hasChevron {
            chevron.frame = NSRect(x: right - gap - chevronW, y: (rowH - 16) / 2,
                                   width: chevronW, height: 16)
            right = chevron.frame.minX
        }
        if !spinner.isHidden {
            let side = spinner.frame.width
            spinner.setFrameOrigin(NSPoint(x: right - gap - side, y: (rowH - side) / 2))
            right = spinner.frame.minX
        }
        // Sized to the text, not to a fixed column: a fixed 74pt turned "new session" into
        // "new sessior", which reads as a rendering fault rather than a status.
        let tailW: CGFloat = trailing.stringValue.isEmpty ? 0
            : ceil(trailing.stringValue.size(withAttributes: [
                .font: trailing.font ?? NSFont.menuFont(ofSize: 0)]).width) + 2
        trailing.frame = NSRect(x: right - gap - tailW, y: (rowH - 16) / 2,
                                width: tailW, height: 16)
        label.frame.size.width = max(40, (tailW > 0 ? trailing.frame.minX : right)
                                        - gap - label.frame.minX)
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 5, dy: 0)
        layoutRow(width: bounds.width)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways is load-bearing: an LSUIElement app is not active while its menu tracks,
        // so .activeInKeyWindow or .activeInActiveApp would deliver no mouseEntered at all.
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        highlight.isHidden = false
        label.textColor = .white
        trailing.textColor = NSColor.white.withAlphaComponent(0.75)
        chevron.textColor = NSColor.white.withAlphaComponent(0.75)
        spinner.tint = NSColor.white.withAlphaComponent(0.75)
        onHover?(self)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        highlight.isHidden = true
        label.textColor = .labelColor
        trailing.textColor = .secondaryLabelColor
        chevron.textColor = .tertiaryLabelColor
        spinner.tint = .secondaryLabelColor
        ToolCard.shared.hide()
    }

    // The one hook that always fires when the menu goes away. mouseExited does not arrive on
    // close (measured — it simply never comes), and the tool submenu is built without a delegate,
    // so menuDidClose has nobody to call. Without this the card outlives the menu and sits on
    // screen indefinitely.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolCard.shared.hide() }
    }

    override func mouseDown(with event: NSEvent) {
        guard toggle.isEnabled else { return }
        toggle.isOn.toggle()
        toggle.onToggle?(toggle.isOn)
    }

    /// Everything on the row that can change while the menu is open. NSMenu cannot add or
    /// remove rows mid-track, but the views it already holds can be rewritten — and all of it
    /// has to be rewritten, not just the count: switching a server off left a green dot sitting
    /// beside an off switch until the menu was reopened.
    func setStatus(glyph: String, color: NSColor, trailing text: String, dim: Bool,
                   spinning: Bool = false) {
        spinner.setActive(spinning)
        mark.stringValue = glyph
        mark.textColor = color
        mark.sizeToFit()
        mark.setFrameOrigin(NSPoint(x: markX, y: (rowH - mark.frame.height) / 2))
        trailing.stringValue = text
        label.textColor = hovered ? .white : (dim ? .tertiaryLabelColor : .labelColor)
        chevron.isHidden = dim
        // The switch follows too, for the case where something else moved it — another window,
        // a hand-edit of settings.json. Guarded on inequality because ToggleView animates on
        // every assignment, and this runs on each poll tick while the menu is open.
        if toggle.isOn == dim { toggle.isOn = !dim }
        needsLayout = true
    }

    func setTrailing(_ text: String) {
        trailing.stringValue = text
        needsLayout = true
    }
}

extension StatusController {

    var mcpRowWidth: CGFloat { CGFloat(uiConfig()["boxWidth"] ?? 300) }

    /// The detail behind the bars in the menu bar: the same two percentages spelled out, with
    /// when each window resets and how old the reading is.
    func addLimitsSection(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(header("Limits"))
        guard let limits, limits.fiveHour != nil || limits.sevenDay != nil else {
            // Empty means the usage poll has not succeeded yet: switched off in Options, or
            // Claude Code is not signed in through the browser OAuth flow (a `setup-token`
            // login lacks the profile scope the endpoint wants). Saying so beats an empty
            // section, and beats inventing a number.
            menu.addItem(header(oauthLimits
                ? "  no data yet — is Claude Code signed in?"
                : "  switched off — see \"Limits via Anthropic API\""))
            return
        }
        let rows: [(String, Int?, Double?)] = [
            ("5 hours", limits.fiveHour, limits.fiveHourResets),
            ("7 days", limits.sevenDay, limits.sevenDayResets),
        ]
        for (title, value, resets) in rows {
            guard let value else { continue }
            var tail = "\(value)%"
            if let resets, resets > Date().timeIntervalSince1970 {
                tail += "  ·  resets in " + Self.until(resets)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: "  \(title)   \(tail)",
                attributes: [
                    .foregroundColor: value >= 90 ? NSColor.systemRed
                        : (value >= 75 ? NSColor.systemOrange : NSColor.labelColor),
                    .font: NSFont.systemFont(ofSize: 12),
                ])
            item.isEnabled = false
            menu.addItem(item)
        }
        let age = Int(Date().timeIntervalSince1970 - limits.ts) / 60
        menu.addItem(header(age < 1 ? "  just measured" : "  measured \(age) min ago"))
    }

    private static func until(_ stamp: Double) -> String {
        let left = Int(stamp - Date().timeIntervalSince1970)
        let hours = left / 3600, minutes = (left % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// The MCP section: a summary line, whatever changed since last time, then the servers
    /// grouped by where they are configured.
    func addMCPSection(to menu: NSMenu) {
        guard !mcp.servers.isEmpty || mcp.error != nil else { return }
        menu.addItem(.separator())

        let summary = header("")
        menu.addItem(summary)
        // Re-read from the model rather than captured, so one click updates every count that
        // depends on it without rebuilding a menu NSMenu will not let us rebuild mid-track.
        watchCount { [weak self] in
            guard let self else { return }
            summary.attributedTitle = Self.headerText(
                "MCP — \(self.mcp.live)/\(self.mcp.visible.count) connected"
                + " · \(self.mcp.toolsOn)/\(self.mcp.toolsTotal) tools on")
        }

        // "Show that the number moved" — a count that is simply different next time you look
        // tells you nothing about whether you moved it or a server did.
        if let change = mcp.freshChange() { menu.addItem(changeRow(change)) }

        for group in mcpGroups {
            let servers = mcp.servers.filter { $0.source == group.key }.sorted { $0.name < $1.name }
            guard !servers.isEmpty else { continue }
            menu.addItem(header(group.title))
            for server in servers { for row in serverRows(server) { menu.addItem(row) } }
        }

        if !mcp.waitingAuth.isEmpty {
            menu.addItem(header("Waiting for authorisation — run /mcp in a terminal"))
            for name in mcp.waitingAuth {
                let item = NSMenuItem(title: "  ◌  " + mcpShortName(name), action: nil,
                                      keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if let error = mcp.error { menu.addItem(header("Check failed: " + error)) }
    }

    private func changeRow(_ change: MCPChange) -> NSMenuItem {
        var parts: [String] = []
        if !change.down.isEmpty { parts.append("↓ " + change.down.map(mcpShortName).joined(separator: ", ")) }
        if !change.up.isEmpty { parts.append("↑ " + change.up.map(mcpShortName).joined(separator: ", ")) }
        if !change.appeared.isEmpty { parts.append("+\(change.appeared.count) server") }
        if !change.vanished.isEmpty { parts.append("−\(change.vanished.count) server") }
        if change.toolDelta != 0 {
            parts.append("\(change.toolDelta > 0 ? "+" : "−")\(abs(change.toolDelta)) tools")
        }
        let item = NSMenuItem(title: parts.joined(separator: "   "), action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: "  changed:  " + parts.joined(separator: "   "),
            attributes: [
                .foregroundColor: change.down.isEmpty ? NSColor.systemBlue : NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
        item.isEnabled = false
        // Worth saying exactly once, next to the change that prompts the question: a switch here
        // edits settings.json, and Claude Code builds a session's server and tool list when the
        // session starts. A tab that is already open keeps what it had.
        item.toolTip = "Applies to new sessions — an open one keeps the tools it started with"
        return item
    }

    /// How the tool count reads on a server row, and on its "Tools" line.
    private func toolCount(_ name: String) -> String {
        guard let server = mcp.servers.first(where: { $0.name == name }) else { return "—" }
        return server.tools.isEmpty
            ? (server.reportedTools.map(String.init) ?? "—")
            : "\(server.enabledTools)/\(server.tools.count)"
    }

    /// Whether this row is waiting on a check that is actually happening.
    private func serverChecking(_ name: String) -> Bool {
        mcp.isChecking(name, backendBusy: mcpChecking)
    }

    /// What the right-hand column says for a server. A server that did not answer says so in
    /// words — it used to be a bare "!", which next to a plainly-ON switch reads as a
    /// contradiction rather than an explanation, especially since "pending" here means
    /// "switched on, waiting for a new session".
    private func serverTail(_ name: String) -> String {
        guard let server = mcp.servers.first(where: { $0.name == name }) else { return "—" }
        switch server.state {
        case "ok", "off": return toolCount(name)
        // Empty while the check runs: the spinner in this same slot is the answer, and a word
        // beside a turning arc reads as two competing statuses. Once nothing is checking, the
        // actionable fact takes over — a re-enabled server is on, but Claude Code assembles a
        // session's server list when the session starts, so an already open one keeps what it had.
        // A server from a repo's .mcp.json that Claude Code has not been told to trust yet: it
        // is not switched on and waiting, it is waiting to be allowed at all, and only the user
        // can answer that — in Claude Code, not here.
        case "pending" where server.needsApproval: return "approve in Claude Code"
        case "pending": return serverChecking(name) ? "" : "next session"
        // A remote (http/sse) server of a project: there is no probe for it, and claiming
        // either green or red would be inventing. The tooltip carries the explanation.
        case "unknown": return "not checked"
        default: return "failed"
        }
    }

    private func serverRows(_ server: MCPServer) -> [NSMenuItem] {
        let name = server.name
        let tail = serverTail(name)

        let head = NSMenuItem()
        // Titles are unused for display when a view is set, but they are what the dump
        // diagnostic and VoiceOver can read.
        head.title = "\(server.state) \(mcpShortName(name))  \(tail)"
        let row = MCPRowView(
            mark: mcpGlyph(server.state), markColor: mcpTint(server.state),
            title: mcpShortName(name), trailing: tail,
            isOn: !server.disabled, indent: 14, width: mcpRowWidth,
            chevron: !server.tools.isEmpty, spinning: serverChecking(name)
        ) { [weak self] on in self?.setMCPServer(name, enabled: on) }
        switch server.state {
        case "ok": row.toolTip = server.project.map { "\(name) — project \($0)" } ?? name
        case "pending" where server.needsApproval:
            row.toolTip = name + "\nConfigured in this project's .mcp.json, which came with the"
                + " repository. Claude Code asks once before trusting a server from there, and"
                + " this app does not start it — or read its tools — until you have said yes."
                + "\nRun /mcp in that project to decide."
        case "pending":
            row.toolTip = name + "\nSwitched on. Claude Code builds a session's list of servers"
                + " when the session starts, so one that is already open keeps what it had."
                + "\nThe tool count returns here once the check finishes."
        // The project belongs here most of all. One name is one row (settings.json addresses a
        // server by serverName alone), so when two open projects both configure a `db`, the row
        // takes the worse of the two states — and then "failed" without a project name leaves
        // the user checking the wrong repository.
        default: row.toolTip = name + " · " + server.status
            + (server.project.map { "\nproject \($0)" } ?? "")
        }
        head.view = row

        // The tool list hangs off the server's own row rather than a separate "Tools ›" line
        // beneath it. Twelve servers meant twenty-four rows to say twelve things.
        if !server.tools.isEmpty {
            let submenu = NSMenu()
            submenu.addItem(header("Click a row to switch a tool on or off"))
            for tool in server.tools { submenu.addItem(toolRow(tool, of: server, indent: 14)) }
            head.submenu = submenu
        }
        // Registered for every server, tools or not: this used to sit behind the submenu, so a
        // server with no tool list of its own never re-rendered at all. Stale text was easy to
        // miss; a spinner that never stops is not.
        //
        // The whole row re-renders, not just its count. Switching a server off used to leave a
        // green dot next to an off switch until the menu was reopened, which read as the click
        // having done nothing.
        watchCount { [weak self, weak row] in
            guard let self, let row,
                  let now = self.mcp.servers.first(where: { $0.name == name }) else { return }
            row.setStatus(glyph: mcpGlyph(now.state), color: mcpTint(now.state),
                          trailing: self.serverTail(name), dim: now.disabled,
                          spinning: self.serverChecking(name))
        }
        return [head]
    }

    private func toolRow(_ tool: MCPTool, of server: MCPServer, indent: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = (tool.enabled ? "on   " : "off  ") + tool.name
        let name = tool.name, serverName = server.name
        let row = MCPRowView(
            // No glyph: the switch on the right already says on or off. A tick that repeats it
            // has to be kept in sync with it, and it was not — it stayed green under a switch
            // the user had just turned off.
            mark: nil, markColor: .clear,
            title: name, trailing: "", isOn: tool.enabled,
            indent: indent, width: mcpRowWidth + 120,
            onHover: { view in ToolCard.shared.show(tool: tool, server: serverName, near: view) }
        ) { [weak self] on in
            guard let self else { return }
            // Local first, then the backend. Rewriting settings.json and re-deriving the picture
            // takes long enough that the counts would sit stale until the menu is reopened.
            self.mcp.setToolLocally(server: serverName, tool: name, enabled: on)
            self.refreshCounts()
            self.setMCPTool("mcp__\(serverName)__\(name)", enabled: on)
        }
        // Kept alongside the card: the card needs a hover to appear, the tooltip is what
        // VoiceOver and a keyboard-driven pass over the menu can still reach.
        row.toolTip = tool.doc.isEmpty ? nil : tool.doc
        item.view = row
        return item
    }

    static func headerText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ])
    }

    static func dimmed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ])
    }
}
