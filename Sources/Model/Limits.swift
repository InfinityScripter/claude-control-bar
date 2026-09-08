import Cocoa

/// One rate-limit window as limits.json carries it: a rounded percentage and, when the
/// writer knew it, the epoch second the window resets at.
struct LimitWindow: Equatable {
    let used: Int
    let resets: Double?

    init?(json: Any?) {
        // as? Int, deliberately: the statusLine payload reports fractional percentages and
        // hooks/statusline.py rounds them on the way in. If a writer ever forgets, the limits
        // vanish from the menu while limits.json still looks perfectly healthy — so the
        // rounding lives in one place and is covered by a test.
        guard let o = json as? [String: Any], let used = o["used_percentage"] as? Int else { return nil }
        self.used = used
        self.resets = o["resets_at"] as? Double
    }

    /// Fraction for the gauges; the percentage stays an Int on disk so the file is diffable.
    var fraction: Double { Double(used) / 100 }
}

/// The account's limits as read from limits.json. Two windows every subscriber has, plus the
/// weekly Fable window that only shows up for plans with that model — so it is optional
/// rather than defaulted, and the menu omits its row instead of drawing an empty bar.
struct Limits {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let fable: LimitWindow?
    let source: String
    let ts: Double

    /// Anthropic names the per-model weekly windows `seven_day_<model>` (seven_day_opus,
    /// seven_day_sonnet, ...) and both writers copy the key through untouched. The exact
    /// spelling for Fable is not pinned anywhere we can read, so the canonical name wins and
    /// any other key carrying the model's name is the fallback — a renamed window should
    /// keep the row rather than silently drop it.
    static func fableKey(in keys: [String]) -> String? {
        if keys.contains("seven_day_fable") { return "seven_day_fable" }
        return keys.filter { $0 != "ts" && $0 != "source" && $0.lowercased().contains("fable") }
            .sorted().first
    }

    init?(json root: [String: Any]) {
        let five = LimitWindow(json: root["five_hour"])
        let seven = LimitWindow(json: root["seven_day"])
        let fable = Limits.fableKey(in: Array(root.keys)).flatMap { LimitWindow(json: root[$0]) }
        guard five != nil || seven != nil || fable != nil else { return nil }
        self.fiveHour = five
        self.sevenDay = seven
        self.fable = fable
        self.source = root["source"] as? String ?? ""
        self.ts = root["ts"] as? Double ?? 0
    }

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil && fable == nil }
}
