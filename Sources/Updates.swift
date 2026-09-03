import Cocoa

// The update channels: the daily GitHub/Homebrew check, the what's-new window, and the
// build-from-source self-update. Lifted out of main.swift; StatusController's stored state
// stays there (an extension cannot hold it).
extension StatusController {
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
    // Homebrew: the cask lags a GitHub release by up to ~a day (autobump), so brew-managed
    // installs gate "update available" on the CASK version, so the copy command always works
    // when offered. Public JSON, nothing sent anywhere (same privacy story as the GitHub check).
    // The trailing `open` matters: brew only copies the app, and the first launch of the new copy
    // is what installs hooks and removes the old-named bundle (0.4.0 rename transition).
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
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            // The release body rides in the same response — the "What's new in X" row shows
            // it before the user decides to update, at no extra request. Written together
            // with latestVersion so the two always describe the same release.
            UserDefaults.standard.set((obj["body"] as? String) ?? "", forKey: "latestReleaseNotes")
            // Once per version, ever: the point is "an update exists, the menu explains it",
            // not a daily drumbeat. The plugin channel gets this too — it will update itself
            // on its own schedule, but a heads-up with readable notes beats a silent swap.
            if let self, Self.versionIsNewer(ver, than: self.currentVersion),
               UserDefaults.standard.string(forKey: "updateNotifiedVersion") != ver {
                UserDefaults.standard.set(ver, forKey: "updateNotifiedVersion")
                self.notify(title: "Claude Control Bar \(ver) is available",
                            body: "The menu has \u{201C}What\u{2019}s new in \(ver)\u{201D} and the update.")
            }
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

    // MARK: what's new

    /// The version whose changelog hasn't been opened yet. UserDefaults, not a transient flag:
    /// the plugin channel updates by replacing the bundle and relaunching, so the row has to
    /// survive exactly that restart to ever be seen.
    var whatsNewUnseen: String? {
        get { UserDefaults.standard.string(forKey: "whatsNewUnseen") }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: "whatsNewUnseen") }
            else { UserDefaults.standard.removeObject(forKey: "whatsNewUnseen") }
        }
    }

    /// Both update channels end the same way — a new version starts running — so this one
    /// launch-time check is what makes either of them visible. The plugin channel in
    /// particular rebuilds and swaps the app with no user action at all; without this the
    /// only trace of an update was the version row quietly reading a different number.
    ///
    /// The first launch ever is silent: there is no previous version to have changed from,
    /// and greeting a fresh install with "updated!" would be noise.
    func announceVersionChange() {
        let d = UserDefaults.standard
        let last = d.string(forKey: "lastRunVersion")
        d.set(currentVersion, forKey: "lastRunVersion")
        // Strictly newer, not merely different: a rollback (a dev branch, an older DMG put
        // back on purpose) announcing "Updated from 0.7.4" would be reporting the opposite
        // of what happened.
        guard let last, Self.versionIsNewer(currentVersion, than: last) else { return }
        whatsNewUnseen = currentVersion
        notify(title: "Claude Control Bar \(currentVersion)",
               body: "Updated from \(last). \u{201C}What\u{2019}s new\u{201D} in the menu has the changes.")
    }

    /// The changes of the copy that is running: the CHANGELOG.md the build shipped alongside
    /// the binary, so the answer matches this exact version and works offline.
    @objc func showWhatsNewCurrent() {
        whatsNewUnseen = nil
        let bundled = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let md = bundled, let text = Changelog.section(for: currentVersion, in: md) {
            showWhatsNewWindow(version: currentVersion, markdown: text,
                               date: Changelog.date(for: currentVersion, in: md))
        } else if let url = URL(string:
            "https://github.com/InfinityScripter/claude-control-bar/releases/tag/v\(currentVersion)") {
            // A bundle built before the changelog shipped as a resource: the release page has it.
            NSWorkspace.shared.open(url)
        }
    }

    /// The changes of the version that is only available yet — the release body the daily
    /// update check already fetched (`releases/latest` carries it; no extra request).
    @objc func showWhatsNewLatest() {
        let d = UserDefaults.standard
        if let latest = d.string(forKey: "latestVersion"),
           let notes = d.string(forKey: "latestReleaseNotes"), !notes.isEmpty {
            showWhatsNewWindow(version: latest, markdown: notes, date: nil)
        } else {
            openLatestRelease()
        }
    }


    func showWhatsNewWindow(version: String, markdown: String, date: String?) {
        let container = WhatsNewPanel.contentView(version: version, markdown: markdown,
                                                  date: date, icon: NSApp.applicationIconImage)
        // One window, reused: a second click brings the same panel forward instead of
        // stacking copies. Closing releases the content, not the app (isReleasedWhenClosed
        // stays false because the controller keeps the reference).
        let win = whatsNewWindow ?? {
            let w = NSWindow(contentRect: container.frame,
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            // The header inside the content is the title; the system bar above it would say
            // the same thing twice. The window name stays set for Mission Control and VoiceOver.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.center()
            whatsNewWindow = w
            return w
        }()
        win.title = "What\u{2019}s new in \(version)"
        win.contentView = container
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
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
        // Appended, not read-and-rewritten: the app runs for days, and a self-update stuck in a
        // retry loop once rewrote the whole file on every failure.
        if !FileManager.default.fileExists(atPath: log) {
            FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = FileHandle(forWritingAtPath: log), let data = (text + "\n").data(using: .utf8) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        }
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
        // Appends serialized on their own queue: the readability handler runs on FileHandle's
        // private queue while this thread reads the tail after waitUntilExit — and nilling the
        // handler does not wait out an in-flight invocation, so the plain shared `var` was an
        // unsynchronized cross-thread mutation on exactly the failure path where the tail
        // matters. The empty-read check also stops the EOF spin (the handler is re-invoked
        // with empty data until removed).
        let stderrQueue = DispatchQueue(
            label: "io.github.infinityscripter.claude-control-bar.update-stderr")
        var stderrData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            stderrQueue.async { stderrData.append(chunk) }
        }
        do { try build.run() } catch { return fail("build launch: \(error)") }
        DispatchQueue.main.async { [weak self] in self?.updateBuild = build }
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) { [weak build] in
            if let build, build.isRunning { build.terminate() }
        }
        build.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async { [weak self] in self?.updateBuild = nil }
        guard build.terminationStatus == 0 else {
            let tail = stderrQueue.sync { String(decoding: stderrData.suffix(2000), as: UTF8.self) }
            return fail("build exited \(build.terminationStatus):\n\(tail)")
        }
        // The bundle at `target` is already the new version (build.sh swaps only a verified
        // staging copy). restartIntoInstalledCopy quits us and opens whatever is on disk.
        DispatchQueue.main.async { [weak self] in self?.restartIntoInstalledCopy() }
    }
}
