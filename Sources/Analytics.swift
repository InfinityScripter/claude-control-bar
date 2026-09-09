import Cocoa

// The anonymous daily ping, wired to the clock, UserDefaults and the network. The decision and
// the payload are AnalyticsPing (Sources/Model); this file is only the plumbing around them.
extension StatusController {
    /// Off by environment beats on by setting: the variable exists so a machine's owner can end
    /// the ping without a UI, and a setting that could override it would defeat that.
    var analyticsAllowed: Bool {
        AnalyticsPing.configured && analytics
            && ProcessInfo.processInfo.environment[AnalyticsPing.optOutVariable] == nil
    }

    /// The Settings switch. Turning it off also forgets the notice timestamp, so a later "on" is
    /// followed by the same one-day grace before anything is sent — switching it on is a choice,
    /// but the grace costs nothing and keeps the rule simple: no ping within a day of being told.
    func applyAnalytics(_ on: Bool) {
        analytics = on
        let d = UserDefaults.standard
        d.set(on, forKey: "analytics")
        if !on {
            d.removeObject(forKey: "analyticsNoticedAt")
        } else if d.object(forKey: "analyticsNoticedAt") == nil {
            d.set(Date().timeIntervalSince1970, forKey: "analyticsNoticedAt")
        }
    }

    /// Called at launch and then hourly. The first call on a machine that has not seen the
    /// notice posts it and starts the clock; nothing is sent on that launch. The notice goes
    /// through the same notify() the update banner uses, so a machine that declined
    /// notifications is still told the other way: the switch and its footer in Settings →
    /// General, and the What's new of the version that introduced the ping.
    func sendAnalyticsPingIfDue() {
        guard analyticsAllowed else { return }
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if d.object(forKey: "analyticsNoticedAt") == nil {
            d.set(now, forKey: "analyticsNoticedAt")
            notify(title: "Anonymous usage ping is on",
                   body: "Once a day: app version, macOS version, chip, install channel. "
                       + "No identifier. Settings \u{2192} General turns it off before the first one is sent.")
            return
        }
        let last = d.object(forKey: "lastAnalyticsPing") == nil ? nil : d.double(forKey: "lastAnalyticsPing")
        let noticed = d.object(forKey: "analyticsNoticedAt") == nil ? nil : d.double(forKey: "analyticsNoticedAt")
        guard AnalyticsPing.due(now: now, lastAttempt: last, noticedAt: noticed) else { return }
        // Stamped before the request, like the update check: an attempt is what the daily
        // throttle counts, so an unreachable receiver costs one request a day, not one an hour.
        d.set(now, forKey: "lastAnalyticsPing")
        sendAnalyticsPing()
    }

    private var installChannel: String {
        let owner = (root as NSString).appendingPathComponent("owner.json")
        let json = (try? Data(contentsOf: URL(fileURLWithPath: owner)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return AnalyticsPing.channel(brewManaged: brewManaged, ownerChannel: json?["channel"] as? String)
    }

    private func sendAnalyticsPing() {
        guard let url = URL(string: AnalyticsPing.endpoint) else { return }
        let payload = AnalyticsPing.payload(
            version: currentVersion,
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            arch: AnalyticsPing.arch,
            channel: installChannel)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ClaudeControlBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        // Ephemeral: no cookie jar, no cache, so nothing the receiver sets can ride along on the
        // next day's ping and turn a stateless count into a session. Redirects are refused for
        // the same reason the limits poll refuses them — the payload goes to the named host or
        // nowhere. The response is ignored; there is nothing the app needs to learn from it.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect.shared, delegateQueue: nil)
        session.dataTask(with: req) { _, _, _ in session.finishTasksAndInvalidate() }.resume()
    }
}

/// A delegate whose only job is to answer every redirect with "no".
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
