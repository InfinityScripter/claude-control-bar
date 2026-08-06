import Cocoa

// Hover card for an MCP tool: name, what it does, and its parameters — the detail an editor
// shows when you hover a tool in its MCP list, and the thing a one-line menu row cannot carry.
//
// It is a window of its own because a menu runs in a modal tracking loop and a subview of an
// NSMenuItem cannot draw outside the menu's bounds. Three properties do the actual work, each
// for a measured reason:
//
//   level = .popUpMenu          — 101, the level NSPopupMenuWindow itself uses, so the card is
//                                 not painted underneath the menu it belongs to.
//   ignoresMouseEvents = true   — without it the card swallows the click meant for the row under
//                                 it, and toggling a tool by clicking its row stops working.
//   orderFrontRegardless()      — a borderless window never becomes key, so the menu does not
//                                 close when the card appears.
//
// NSPopover was tried and rejected: it does show during menu tracking, but it brings its own
// light bubble and anchor arrow (foreign against the menu material), it takes mouse events, and
// its own header documents that it silently does nothing when the anchoring view is scrolled out
// of view — which is exactly what a long tool list is.
final class ToolCard {
    static let shared = ToolCard()

    private var window: NSWindow?
    private var pending: Timer?

    private static let width: CGFloat = 360
    private static let pad: CGFloat = 12
    private static let delay: TimeInterval = 0.3

    func show(tool: MCPTool, prefix: String, near row: NSView) {
        pending?.invalidate()
        let timer = Timer(timeInterval: ToolCard.delay, repeats: false) { [weak row] _ in
            // The menu can close while the delay ticks; a row pulled out of its menu has no
            // window, and positioning against it would put the card at the screen origin.
            guard let row, let host = row.window else { return }
            self.place(ToolCard.body(tool: tool, prefix: prefix), row: row, host: host)
        }
        // Menu tracking runs in NSEventTrackingRunLoopMode, and a timer scheduled the usual way
        // sits in the default mode and does not fire until the menu closes. .common covers both
        // that mode and the ordinary one — the same choice the session poll timer already makes,
        // for the same reason.
        RunLoop.current.add(timer, forMode: .common)
        pending = timer
    }

    func hide() {
        pending?.invalidate()
        pending = nil
        window?.orderOut(nil)
    }

    private func place(_ content: NSView, row: NSView, host: NSWindow) {
        let card = window ?? make()
        window = card
        // Inherit the appearance of the row, not of the app. A window of its own resolves
        // labelColor against NSApp.effectiveAppearance, and the menu is not obliged to agree
        // with it — a dark wallpaper turns the menu dark while the system stays light, which
        // would render this card black on near-black.
        card.appearance = row.effectiveAppearance
        card.contentView?.subviews.forEach { $0.removeFromSuperview() }
        let size = NSSize(width: ToolCard.width, height: content.frame.height + ToolCard.pad * 2)
        card.setContentSize(size)
        content.setFrameOrigin(NSPoint(x: ToolCard.pad, y: ToolCard.pad))
        card.contentView?.addSubview(content)

        let anchor = host.convertToScreen(row.convert(row.bounds, to: nil))
        let screen = NSScreen.screens.first { NSPointInRect(anchor.origin, $0.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let y = max(min(anchor.maxY - size.height, visible.maxY - size.height), visible.minY)

        // Right first, deliberately. The tool list is a submenu, and a submenu opens to the RIGHT
        // of the menu that spawned it — so the space on the left is exactly where the parent menu
        // is standing. Measured: a card placed left covered 287 of the parent menu's 300pt, and
        // since the card is click-through, moving the cursor left to read it landed in the menu
        // underneath, closed the submenu, and took the card with it mid-sentence.
        let right = anchor.maxX + 8
        var x = right
        if right + size.width > visible.maxX {
            let left = anchor.minX - size.width - 8
            x = left >= visible.minX ? left : max(visible.maxX - size.width, visible.minX)
        }
        card.setFrameOrigin(NSPoint(x: x, y: y))
        card.orderFrontRegardless()
    }

    private func make() -> NSWindow {
        let card = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered,
                            defer: false)
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu          // the same material the menu is drawn on
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        card.contentView = backdrop
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = true
        card.ignoresMouseEvents = true
        card.level = .popUpMenu
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                                   .ignoresCycle]
        card.hidesOnDeactivate = false
        return card
    }

    /// Internal rather than private so a harness can render the card body to an image and
    /// look at it — a window that only exists during menu tracking is otherwise unreviewable.
    ///
    /// `prefix` is the server's toolPrefix, not its display name: the identifier line below the
    /// title shows the REAL full tool name, and for a plugin or a claude.ai connector the two
    /// differ — `plugin:claude-mem:mcp-search` loads its tools as `plugin_claude-mem_mcp-search`.
    static func body(tool: MCPTool, prefix: String) -> NSView {
        let text = NSMutableAttributedString()
        let inner = width - pad * 2

        text.append(NSAttributedString(string: tool.name + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        text.append(NSAttributedString(
            string: MCPServer.fullToolName(prefix: prefix, tool: tool.name) + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        if !tool.doc.isEmpty {
            text.append(NSAttributedString(string: "\n" + tool.doc + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if !tool.params.isEmpty {
            text.append(NSAttributedString(string: "\nParameters\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            for param in tool.params {
                text.append(NSAttributedString(
                    string: param.name + (param.required ? "*" : ""),
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
                    ]))
                var tail = ""
                if !param.type.isEmpty { tail += " (\(param.type))" }
                if !param.doc.isEmpty { tail += ": " + param.doc }
                text.append(NSAttributedString(string: tail + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
        }

        let label = NSTextField(labelWithAttributedString: text)
        label.preferredMaxLayoutWidth = inner
        label.lineBreakMode = .byWordWrapping
        label.frame = NSRect(x: 0, y: 0, width: inner, height: 0)
        label.frame.size.height = label.sizeThatFits(
            NSSize(width: inner, height: .greatestFiniteMagnitude)).height
        return label
    }
}
