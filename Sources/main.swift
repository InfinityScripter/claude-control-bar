import Cocoa
import UserNotifications

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

    let engine = SessionEngine()  // the state machine lives in Sessions.swift, testable
    var sessions: [String: Session] = [:]  // id -> latest parsed per-session state
    var fileMTimes: [String: Date] = [:]   // "<id>.json" -> last-parsed mtime (re-parse only on change)
    var gitHeadCache: [String: String] = [:]  // cwd -> resolved HEAD path ("" = confirmed non-git)
    var uiConfigCache: (mtime: Date?, values: [String: Double])?
    // Stored state used by the extensions in Updates.swift, SessionRows.swift and
    // IconRender.swift — an extension cannot declare stored properties, so they live here.
    let releaseAPIURL = "https://api.github.com/repos/InfinityScripter/claude-control-bar/releases/latest"
    let releasePageURL = "https://github.com/InfinityScripter/claude-control-bar/releases/latest"
    let brewCaskAPIURL = "https://formulae.brew.sh/api/cask/claude-control-bar.json"
    let brewUpgradeCommand = "brew upgrade --cask claude-control-bar"
    let brewInstallCommand = "brew install --cask claude-control-bar && open -a \"Claude Control Bar\""
    var whatsNewWindow: NSWindow?
    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
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
    var prevState: [String: String] = [:]  // id -> previous raw state per session
    var menuIsOpen = false                  // refresh the dropdown's per-session timers only while open
    var sessionMenuItems: [(item: NSMenuItem, id: String)] = []
    var activeBase = ""        // label without the elapsed clock
    var renderedTitle: String? // what the status item is actually showing, to skip identical redraws
    var lastLifecycleCheck: Double = 0  // the quit decision is sampled far slower than the UI
    var notificationsDenied = false     // the one macOS permission this app has; see notify()
    var lastNotifiedChangeAt: Date?     // dedupe: notifyMCPChange runs on every reload, the change lives 45 s
    var limitsMTime: Date?              // limits.json parse gate; nil forces a re-read (see loadLimits)
    var selfUpdating = false            // one build-from-source update at a time; also the menu text
    var updateBuild: Process?           // the in-flight update's build; Quit terminates it (see quit())
    // Never `xcrun --find`: querying xcrun with no developer tools installed pops the system's
    // "install the command line developer tools?" dialog — from a menu bar app, out of nowhere.
    // A missing toolchain must read as "not available", never as a prompt. The fixed paths cover
    // the stock installs; `xcode-select -p` (prompt-free) covers one moved with --switch.
    //
    // Warmed ONCE on a background queue at launch. This used to be a lazy var, and its first
    // touch — inside menuNeedsUpdate, on the main thread — spawned xcode-select synchronously
    // while the user was opening the menu. Until the warm-up lands (sub-second) the update row
    // takes its no-toolchain shape, which is merely the release-page fallback.
    var canBuildFromSource = false
    func warmCanBuildFromSource() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let answer = Self.probeToolchain()
            DispatchQueue.main.async { self?.canBuildFromSource = answer }
        }
    }
    static func probeToolchain() -> Bool {
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
    }
    var iconCache: [Int: NSImage] = [:]  // composed menu bar frames, rebuilt only when the look changes
    var iconCacheKey = ""
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil
    var activeBadge = false

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "Needs you" badge
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    enum AnimStyle: String { case web, code, crab }
    var animStyle: AnimStyle = .crab
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
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    lazy var crabFrameSet = CrabFrameSet(walking: crabFrames)
    // Template frames: bright pixels (white eyes) become transparent holes so they're
    // visible as negative space against the menu bar in System color mode.
    lazy var crabTemplateFrames: [CrabMood: [NSImage]] = Dictionary(uniqueKeysWithValues:
        CrabMood.allCases.map { mood in
            (mood, crabFrameSet.frames(for: mood).map(adaptiveCrabFrame))
        })
    var crabMood: CrabMood = .sleeping
    var fps: Double {
        switch animStyle {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab: return crabMood.framesPerSecond
        }
    }
    var frameCount: Int {
        switch animStyle {
        case .web: return max(1, frames.count)
        case .code: return codeGlyphs.count * codeSub
        case .crab: return max(1, crabFrameSet.frames(for: crabMood).count)
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
        observeDesktopApp()
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
        announceVersionChange()
        warmCanBuildFromSource()
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
        // A stat per tick, not a parse: this runs from tick() at 2.5 Hz for the app's whole
        // lifetime, and the file changes every few minutes at most. Writes are atomic renames,
        // so a changed mtime always means a whole new file. The oauth toggle nils limitsMTime
        // so its source-drop decision below re-runs without waiting for a rewrite.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        if let stamp, stamp == limitsMTime { return }
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        limitsMTime = stamp
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
        // Keyed on the change's own timestamp: freshChange() keeps answering with the same
        // change for its whole 45 s window, and this runs from every runBackend completion AND
        // the mtime tick — without the key, a toggle seconds after "server went down" posted
        // the same banner a second time.
        guard let change = mcp.freshChange(), change.deservesNotification,
              change.at != lastNotifiedChangeAt else { return }
        lastNotifiedChangeAt = change.at
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

    // MARK: state polling

    func tick() {
        // Whether to quit is not a four-times-a-second question — the decision behind it is
        // debounced by idleQuitDelay anyway, so checking at this rate only bought the app a
        // steady CPU cost for an answer that cannot change meaningfully between looks.
        let now = Date().timeIntervalSince1970
        reloadSessions()
        if now - lastLifecycleCheck >= 2 {
            lastLifecycleCheck = now
            checkLifecycle()   // after the reload: sessionCount() reads the listing it just made
        }
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
            let id = (key as NSString).deletingPathExtension
            // Symmetric with the pid-death reap in evaluate(): a SessionEnd deletes the file,
            // and the engine's transcript cache plus the per-session bookkeeping must go with
            // it — or one small entry per session ever seen stays for the app's lifetime.
            if let gone = sessions[id], !gone.transcript.isEmpty {
                engine.dropCache(forTranscript: gone.transcript)
            }
            sessions[id] = nil
            prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil
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
        if isWorkingState(s.state), s.startedAt > 0 { turnStart[s.id] = s.startedAt }
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
            s.eff = engine.effectiveState(s, now: now)   // compute once per tick; the menu + tooltip reuse it
            // Reap on PROCESS death, not idle time: a session leaves only when its `claude` process is
            // gone (closed/crashed terminal, quit app), so an idle-but-open session stays and the icon
            // holds. Pre-upgrade files have no pid (0) — fall back to the old idle+age prune so they
            // can't linger forever. This is also what keeps state.d self-cleaning (no growing cache).
            let dead = s.pid > 0 ? !pidAlive(s.pid)
                                 : (s.eff == "idle" && stalePruneAge > 0 && now - s.ts > stalePruneAge)
            if dead {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                sessions[id] = nil; fileMTimes[id + ".json"] = nil; prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil
                if !s.transcript.isEmpty { engine.dropCache(forTranscript: s.transcript) }
                continue
            }
            sessions[id] = s
            updateThinkingWord(s)
            if completionEdge(s, now: now) { chime = true }
            prevState[s.id] = s.state
        }
        for id in Array(prevState.keys) where sessions[id] == nil { prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil }
        // Keyed by cwd, so it outlived the sessions above: an entry per directory ever seen, for
        // the app's lifetime. Kept only for directories a live session still points at.
        let liveCwds = Set(sessions.values.map(\.cwd))
        gitHeadCache = gitHeadCache.filter { liveCwds.contains($0.key) }
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
        setCrabMood(CrabMood.display(forEffectiveStates: sessions.values.map(\.eff),
                                     leadState: lead?.eff))
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // repo · branch [· elapsed] on hover

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: statusText(lead, eff: lead.eff), color: crabRenderColor,
                   animate: animStyle == .crab || crabMood != .sleeping, startedAt: 0, badge: true)
        case "thinking", "tool":
            render(label: statusText(lead, eff: lead.eff), color: crabRenderColor, animate: true, startedAt: lead.startedAt)
        default:
            renderResting()
        }
    }

    var crabRenderColor: NSColor? {
        animStyle == .crab && crabMood.keepsColorInSystem ? brand : iconColor
    }

    func setCrabMood(_ mood: CrabMood) {
        guard mood != crabMood else { return }
        crabMood = mood
        guard animStyle == .crab else { return }
        animTimer?.invalidate(); animTimer = nil
        frameIdx = 0
        iconCacheKey = ""
        iconCache.removeAll()
        statusItem.button?.image = nil
    }

    func renderResting() {
        render(label: "", color: crabRenderColor, animate: animStyle == .crab, startedAt: 0)
    }



    // MARK: self-quit lifecycle

    // Asking LaunchServices about the desktop app on a timer is a synchronous XPC round-trip;
    // workspace launch/terminate notifications keep this flag instead. The authoritative query
    // runs only at the quit decision, so a missed notification can delay a quit by one debounce
    // but can never quit under a live app.
    var desktopRunning = false

    func claudeDesktopRunningLive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID).isEmpty
    }

    func observeDesktopApp() {
        desktopRunning = claudeDesktopRunningLive()
        let nc = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == self.claudeDesktopBundleID else { return }
                self.desktopRunning = running
            }
        }
    }

    // The listing reloadSessions() just made, not a second contentsOfDirectory for the same answer.
    func sessionCount() -> Int { fileMTimes.count }

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
        if sessionCount() > 0 || desktopRunning {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            // The process table gets the last word. A session whose hooks never fired — no node
            // on the PATH, hooks switched off, settings sources that skip the user's file —
            // leaves no state file, and quitting on that evidence killed the app ten seconds
            // after launch with Claude Code running in a terminal the whole time.
            guard now.timeIntervalSince(since) >= idleQuitDelay, !claudeCodeRunning() else { return }
            // Notification-fed flag could have missed a launch (e.g. delivered while the run loop
            // was blocked); confirm with LaunchServices before the irreversible step.
            if claudeDesktopRunningLive() { desktopRunning = true; notNeededSince = nil; return }
            NSApp.terminate(nil)
        } else {
            notNeededSince = now
        }
    }


}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
