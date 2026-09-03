import Cocoa

// The dropdown: NSMenuDelegate, the menu assembly on every open, the Options block and the
// row click / option handlers. Session-row presentation is in SessionRows.swift.
extension StatusController {
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
            configureSessionRow(v, s, eff: effState(s, now: now))
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
                let gated = s.entrypoint == "claude-desktop"   // only the desktop app is gated
                return !gated || s.started || isActiveState(effState(s, now: now))
            }
        // Hide rows idle past the threshold, but ALWAYS keep the most-recent started session (floor at
        // one) so the dropdown never goes empty while a session is alive. Hiding is render-only; the file
        // (and thus liveness) is untouched — see stalePruneAge and the pid-driven reap in evaluate().
        var visible = ordered.filter { s in
            let resting = !isActiveState(effState(s, now: now))
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }   // floor: never empty while alive

        if !visible.isEmpty {
            menu.addItem(header("Sessions"))
            for s in visible {
                let eff = effState(s, now: now)
                let view = SessionRowView(id: s.id, width: boxWidth)
                let sid = s.id, ep = s.entrypoint, tp = s.termProgram, tb = s.termBundle
                view.onClick = { [weak self] in menu.cancelTracking(); self?.openSession(sid, entrypoint: ep, termProgram: tp, termBundle: tb) }
                configureSessionRow(view, s, eff: eff)
                let it = NSMenuItem()
                let tag = surfaceTag(s)
                // The title is what VoiceOver and CONTROL_BAR_DUMP_MENU read; same name length and
                // the same "~" inferred-window marker as the drawn row, or the two drift apart.
                it.title = sessionMenuLine(s) + (s.pct.map { "  ctx \(s.assumed ? "~" : "")\($0)%" } ?? "")
                    + (tag.isEmpty ? "" : "  " + tag)
                it.view = view
                menu.addItem(it)
                sessionMenuItems.append((it, s.id))  // kept so tick() can live-update the timers
            }
            menu.addItem(.separator())
        } else if desktopRunning {
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
        // "in menu bar", because the dropdown rows keep their own timers regardless: a switch
        // that reads "Show timer" and leaves timers visible reads as broken.
        menu.addItem(toggleRow(title: "Timer in menu bar", isOn: showTimer) { [weak self] on in
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
            // The parse gate would otherwise keep the pre-toggle figures until the file's next
            // rewrite: off must drop oauth-sourced numbers on the next tick, on must re-adopt them.
            self?.limitsMTime = nil
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

        // Two events, one submenu. The needs-you list doubles as the picker: choosing a sound
        // plays it once, so there is no separate preview control to build.
        let soundParent = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
        let soundSub = NSMenu()
        soundSub.addItem(header("When a turn finishes"))
        for (secs, name) in [(0.0, "Off"), (0.1, "Every turn"), (60.0, "1 min+"), (300.0, "5 min+"), (900.0, "15 min+")] {
            let it = NSMenuItem(title: name, action: #selector(chooseSound(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: secs)
            it.state = soundThreshold == secs ? .on : .off
            soundSub.addItem(it)
        }
        soundSub.addItem(.separator())
        soundSub.addItem(header("When Claude needs you"))
        for name in [""] + NeedsYouSound.choices {
            let it = NSMenuItem(title: name.isEmpty ? "Off" : name,
                                action: #selector(chooseNeedsYouSound(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            it.state = needsYouSound == name ? .on : .off
            soundSub.addItem(it)
        }
        soundParent.submenu = soundSub
        menu.addItem(soundParent)

        menu.addItem(.separator())
        // A nil action while a check runs is what actually greys the row out: the menu keeps the
        // default autoenablesItems, under which an item with a live target/action is re-enabled
        // at display time and a bare isEnabled=false never sticks (same pattern as the update row).
        // mcpChecking, not mcpBusy: the 2.5 s window after a toggle already spins the server rows,
        // and offering "Check MCP now" inside it queued a redundant ~34 s full check.
        let recheck = NSMenuItem(title: mcpChecking ? "Checking MCP…" : "Check MCP now",
                                 action: mcpChecking ? nil : #selector(refreshMCP), keyEquivalent: "r")
        recheck.target = self
        menu.addItem(recheck)
        let settings = NSMenuItem(title: "Open settings.json", action: #selector(openSettingsJSON),
                                  keyEquivalent: "")
        settings.target = self
        settings.toolTip = "Every server and tool switch is written here"
        menu.addItem(settings)

        menu.addItem(.separator())
        let latestVersion = UserDefaults.standard.string(forKey: "latestVersion")
        let updateAvailable = latestVersion.map {
            Self.versionIsNewer($0, than: currentVersion)
        } ?? false
        let whatsNewSelection = WhatsNewMenuSelection(
            currentIsUnseen: whatsNewUnseen == currentVersion,
            updateAvailable: updateAvailable)
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
        } else if let latest = latestVersion, updateAvailable {
            let width = boxWidth
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
        switch whatsNewSelection {
        case .current:
            // Shown until opened once, then it retires. Appears after any update — the plugin
            // channel's silent rebuild included, which is the whole reason this row exists.
            let wn = NSMenuItem(title: "What\u{2019}s new in \(currentVersion)",
                                action: #selector(showWhatsNewCurrent), keyEquivalent: "")
            wn.target = self
            wn.toolTip = "This copy was updated. One click shows what changed."
            menu.addItem(wn)
        case .latest:
            // Release notes before deciding to update. Falls back to the release page when the
            // cached response predates notes or the release body is empty.
            if let latest = latestVersion {
                let wn = NSMenuItem(title: "What\u{2019}s new in \(latest)",
                                    action: #selector(showWhatsNewLatest), keyEquivalent: "")
                wn.target = self
                menu.addItem(wn)
            }
        case .none:
            break
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

    func toggleRow(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = boxWidth, height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
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

        let item = NSMenuItem()
        item.view = row
        return item
    }


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
        // Extension-panel session: jump to the CONVERSATION, not just the editor. The Claude
        // Code extension registers a URI handler (read out of its extension.js):
        // <scheme>://anthropic.claude-code/open?session=<id> resumes exactly this session in
        // the panel. The scheme comes from the editor's own Info.plist — Cursor says "cursor",
        // VS Code "vscode" — so no fork catalog; `open -b` pins the receiving app in case two
        // forks claim one scheme. An editor without the handler still comes to the front.
        if entrypoint == "claude-vscode", !termBundle.isEmpty, let scheme = urlScheme(ofBundle: termBundle) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-b", termBundle, "\(scheme)://anthropic.claude-code/open?session=\(id)"]
            try? p.run()
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


    // First CFBundleURLTypes scheme of the app carrying this bundle id; nil when the app is
    // gone or registers no URL scheme at all.
    func urlScheme(ofBundle bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let types = Bundle(url: appURL)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        else { return nil }
        return types.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
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

    @objc func chooseNeedsYouSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        needsYouSound = name
        UserDefaults.standard.set(name, forKey: "needsYouSound")
        playNeedsYou()   // the pick is its own preview
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        evaluate()
    }
}
