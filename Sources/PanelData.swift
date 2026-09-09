import Cocoa

// Turning the app's live state into the plain values the panel draws.
//
// Every rule here was in the menu builder before it was here, and the comments that explain the
// non-obvious ones came with them: which sessions are allowed to show, why a skipped limit window
// is skipped rather than zeroed, what a server's right-hand column says when it did not answer.
// The rules are the product of a lot of reported bugs; the presentation is what changed.
extension StatusController {

    // MARK: sessions

    /// The sessions a user should see, in the order they should see them.
    func panelSessions(now: Double) -> [PanelSession] {
        // Gate ONLY the desktop app: opening a conversation there seeds an idle session without
        // real activity, so a desktop session stays out until a prompt or tool fires. CLI, terminal
        // and editor sessions are launched deliberately and surface the moment they start.
        let ordered = sessions.values.sorted { $0.ts > $1.ts }.filter { s in
            let gated = s.entrypoint == "claude-desktop"
            return !gated || s.started || isActiveState(effState(s, now: now))
        }
        // Hiding is render-only — the file, and thus liveness, is untouched. The most recent
        // session is always kept, so the panel never goes empty while one is alive.
        var visible = ordered.filter { s in
            let resting = !isActiveState(effState(s, now: now))
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }
        return visible.map { panelSession($0, now: now) }
    }

    private func panelSession(_ s: Session, now: Double) -> PanelSession {
        let eff = effState(s, now: now)
        let working = isWorkingState(eff) && s.startedAt > 0
        return PanelSession(
            id: s.id,
            name: sessionName(s),
            branch: s.branch,
            status: panelStatus(s, eff: eff),
            eff: eff,
            elapsed: working ? elapsed(max(0, (now - s.startedAt).clampedInt)) : nil,
            pct: s.pct,
            assumed: s.assumed,
            tag: surfaceTag(s),
            entrypoint: s.entrypoint,
            termProgram: s.termProgram,
            termBundle: s.termBundle,
            detail: PanelSessionDetail(
                model: s.model, dirty: s.dirty, tokens: s.tokens, window: s.window,
                cost: s.cost, duration: s.duration,
                linesAdded: s.linesAdded, linesRemoved: s.linesRemoved, cwd: s.cwd))
    }

    /// The row's own word for what the session is doing. Unlike the menu bar label, a row always
    /// says something: with thinking words switched off the bar shows no text because the icon and
    /// the timer already carry the state, but a row reading "main ·  · 14s" reads as broken.
    private func panelStatus(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission": return "Needs you"
        case "thinking", "tool":
            let word = workingLabel(s).trimmingCharacters(in: CharacterSet(charactersIn: "… "))
            return word.isEmpty ? (eff == "tool" ? "Working" : "Thinking") : word
        default: return "Idle"
        }
    }

    // MARK: limits

    /// The account's windows and one line saying how old they are — or, when there are none, why.
    func panelLimits(now: Double) -> ([PanelLimit], String) {
        guard let limits, !limits.isEmpty else {
            // Empty means the poll has not succeeded yet: switched off in Settings, or Claude Code
            // is not signed in through the browser OAuth flow (a `setup-token` login lacks the
            // profile scope the endpoint wants). Saying so beats an empty strip, and beats
            // inventing a number.
            return ([], oauthLimits ? "No data yet — is Claude Code signed in?"
                                    : "Limits are switched off in Settings")
        }
        // Account windows first, the model's own window last: 5h and 7d are what every plan has,
        // Fable is a slice of the week only some plans carry. A window the endpoint does not
        // report is skipped, not zeroed — an empty bar would read as "you have not used Fable",
        // which is not what "no such window" means.
        let rows: [(String, String?, LimitWindow?)] = [
            ("5 hours", nil, limits.fiveHour),
            ("7 days", nil, limits.sevenDay),
            ("Fable", "7d", limits.fable),
        ]
        let out = rows.compactMap { title, badge, window -> PanelLimit? in
            guard let window else { return nil }
            return PanelLimit(
                title: title, badge: badge, used: window.used,
                resets: window.resets.flatMap { $0 > now ? Self.until($0) : nil })
        }
        // Short: it shares the footer with two buttons across 300pt, and "measured 4 min ago"
        // truncated to "Limits measured 2…", which says nothing at all.
        let age = (now - limits.ts).clampedInt / 60
        return (out, age < 1 ? "just now" : "\(age) min ago")
    }

    /// How long until a window resets. A weekly window is days away, and "76h 12m" is arithmetic
    /// the reader has to do, so past a day the minutes go.
    static func until(_ stamp: Double) -> String {
        let left = (stamp - Date().timeIntervalSince1970).clampedInt
        let hours = left / 3600
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        // Below a day this is exactly SessionFormat.elapsed, which the session card already uses:
        // the same "1h 3m" / "36m" shape, spelled once.
        return SessionFormat.elapsed(left)
    }

    /// How tall the panel's scrolling half may get, measured rather than guessed: the screen the
    /// status item is on, minus the menu bar it hangs from and the fixed chrome around the list.
    /// A constant here would be a guess about someone else's display, and when it ran long the
    /// panel's top edge got pushed up off the icon to make room.
    var panelContentCap: CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 600) - Self.panelChromeHeight
        return max(PanelTheme.minContentHeight, available)
    }

    /// The banner, the limits strip, the tabs and the footer, plus the gap under the menu bar.
    /// Deliberately generous: over-reserving costs a little scrolling, under-reserving costs the
    /// panel its anchor.
    static let panelChromeHeight: CGFloat = 260

    // MARK: MCP

    func panelServer(_ server: MCPServer) -> PanelServer {
        PanelServer(
            id: server.name,
            name: mcpShortName(server.name),
            state: server.state,
            tail: serverTail(server),
            enabled: !server.disabled,
            checking: mcp.isChecking(server.name, backendBusy: mcpChecking),
            prefix: server.toolPrefix,
            tip: serverTip(server),
            tools: server.tools.map { tool in
                PanelTool(name: tool.name,
                          help: Self.toolHelp(tool, prefix: server.toolPrefix),
                          enabled: tool.enabled)
            })
    }

    /// Everything the old hover card said, as one string. Composed here, once per rebuild of the
    /// MCP picture, rather than in the row: a row rebuilds its body on every publish, and an
    /// expanded server with a hundred tools was re-concatenating a hundred of these a second.
    ///
    /// The identifier line carries the REAL full tool name, which is what a permissions.deny rule
    /// has to match — for a plugin or a claude.ai connector that is not the display name.
    private static func toolHelp(_ tool: MCPTool, prefix: String) -> String {
        var text = MCPServer.fullToolName(prefix: prefix, tool: tool.name)
        if !tool.doc.isEmpty { text += "\n\n" + tool.doc }
        if !tool.params.isEmpty {
            text += "\n\nParameters\n" + tool.params.map { p in
                p.name + (p.required ? "*" : "") + (p.type.isEmpty ? "" : " (\(p.type))")
                    + (p.doc.isEmpty ? "" : ": " + p.doc)
            }.joined(separator: "\n")
        }
        return text
    }

    /// What the right-hand column says for a server. A server that did not answer says so in
    /// words — a bare "!" next to a plainly-ON switch reads as a contradiction rather than an
    /// explanation, especially since "pending" here means "switched on, waiting for a new session".
    private func serverTail(_ server: MCPServer) -> String {
        let count = server.tools.isEmpty
            ? (server.reportedTools.map(String.init) ?? "—")
            : "\(server.enabledTools)/\(server.tools.count)"
        switch server.state {
        case "ok", "off": return count
        // A server from a repo's .mcp.json that Claude Code has not been told to trust yet: it is
        // not switched on and waiting, it is waiting to be allowed at all, and only the user can
        // answer that — in Claude Code, not here.
        case "pending" where server.needsApproval: return "approve in Claude Code"
        // Empty while the check runs: the spinner in this same slot is the answer, and a word
        // beside a turning arc reads as two competing statuses.
        case "pending":
            return mcp.isChecking(server.name, backendBusy: mcpChecking) ? "" : "next session"
        // A remote (http/sse) project server: there is no probe for it, and claiming either green
        // or red would be inventing.
        case "unknown": return "not checked"
        default: return "failed"
        }
    }

    private func serverTip(_ server: MCPServer) -> String {
        let name = server.name
        switch server.state {
        case "ok": return server.project.map { "\(name) — project \($0)" } ?? name
        case "pending" where server.needsApproval:
            return name + "\nConfigured in this project's .mcp.json, which came with the"
                + " repository. Claude Code asks once before trusting a server from there, and"
                + " this app does not start it — or read its tools — until you have said yes."
                + "\nRun /mcp in that project to decide."
        case "pending":
            return name + "\nSwitched on. Claude Code builds a session's list of servers when the"
                + " session starts, so one that is already open keeps what it had."
                + "\nThe tool count returns here once the check finishes."
        // The project belongs here most of all. One name is one row (settings.json addresses a
        // server by serverName alone), so when two open projects both configure a `db`, the row
        // takes the worse of the two states — and "failed" without a project name leaves the user
        // checking the wrong repository.
        default:
            return name + " · " + server.status + (server.project.map { "\nproject \($0)" } ?? "")
        }
    }

    /// The command that resets the network-volume permission, offered beside an EPERM error.
    var networkVolumeResetCommand: String {
        "tccutil reset SystemPolicyNetworkVolumes "
            + (Bundle.main.bundleIdentifier ?? "io.github.infinityscripter.claude-control-bar")
    }

    // MARK: update

    /// The banner across the top of the panel, or nil when this copy is current.
    ///
    /// The order matters and is not arbitrary: a newer copy already sitting on disk is checked
    /// before the download line and instead of it, because there is nothing left to fetch and
    /// offering "Update to 0.5.1" next to a 0.5.1 bundle sends the user to download what they
    /// installed an hour ago.
    func panelUpdate() -> PanelUpdate? {
        guard let latest = UserDefaults.standard.string(forKey: "latestVersion"),
              Self.versionIsNewer(latest, than: currentVersion) else { return nil }
        if let onDisk = installedVersion, Self.versionIsNewer(onDisk, than: currentVersion) {
            return PanelUpdate(kind: .restart, version: onDisk, stage: nil, command: nil)
        }
        if brewManaged {
            // Silent until the cask catches up (autobump lag): never offer a command that would
            // report "already up to date".
            guard let cask = UserDefaults.standard.string(forKey: "brewCaskVersion"),
                  Self.versionIsNewer(cask, than: currentVersion) else { return nil }
            return PanelUpdate(kind: .brew, version: cask, stage: nil,
                               command: brewUpgradeCommand)
        }
        return PanelUpdate(kind: .available, version: latest, stage: updateStage, command: nil)
    }
}
