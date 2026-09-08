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

    /// The usage endpoint carries the Fable window inside its `limits[]` array (a weekly_scoped
    /// entry for the model), and scripts/mcpbar.py lifts it out under `seven_day_fable`, the
    /// name the per-model windows follow (seven_day_opus, seven_day_sonnet). Any other key
    /// carrying the model's name is the fallback, so a renamed window keeps the row rather
    /// than silently dropping it. Nothing else qualifies: the endpoint also reports windows
    /// under codenames, and a row that guesses one of those is Fable would be a lie.
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
