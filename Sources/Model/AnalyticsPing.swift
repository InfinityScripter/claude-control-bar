import Foundation

/// The anonymous daily ping: what it carries, when it is due, and nothing else.
///
/// The purpose is one number — how many installs were alive on a given day — and the shape is
/// chosen so that number is all the ping can ever yield. There is no install identifier: a
/// random UUID would let the receiving side line pings up into a history of one machine, which
/// is exactly the point where "anonymous" stops being true in the GDPR sense, and it is not
/// needed for a count. Each ping is one install seen today; the day's total is the figure.
///
/// Everything here is pure so the model check can exercise it: the decision to send and the
/// bytes that go are separated from the network, the clock and UserDefaults, which live in
/// Sources/Analytics.swift.
enum AnalyticsPing {
    /// Where the ping goes: the Cloudflare Worker in tools/analytics. An empty string switches
    /// the whole feature off (no ping, no Settings row, no notice), which is how a fork or a
    /// build without a receiver ships. The host named here is the one PRIVACY.md promises;
    /// change both together.
    static let endpoint = "https://ccb-ping.infinityscripter.workers.dev/v1/ping"

    /// The environment variable that disables the ping regardless of the setting, the way
    /// HOMEBREW_NO_ANALYTICS does for brew: a fleet or a CI runner can switch it off without
    /// touching each machine's defaults. Any value counts, including an empty one.
    static let optOutVariable = "CONTROL_BAR_NO_ANALYTICS"

    /// Schema version, so a future field can be told apart from a missing one on the receiver.
    static let schema = 1

    static let interval: TimeInterval = 24 * 3600

    /// True when a receiver is configured at all.
    static var configured: Bool { URL(string: endpoint).map { $0.scheme == "https" } ?? false }

    /// Which way this copy arrived, coarse on purpose. Three values, from two facts the app
    /// already has: Homebrew's Caskroom directory, and the `channel` field of the owner.json the
    /// installer writes. Neither is a property of the person.
    static func channel(brewManaged: Bool, ownerChannel: String?) -> String {
        if brewManaged { return "brew" }
        if ownerChannel == "plugin" { return "plugin" }
        return "dmg"
    }

    /// The complete payload. Every field is a small enumeration shared by thousands of Macs:
    /// the app version, the macOS major version, the CPU architecture and the install channel.
    /// Not the minor OS version, not the model, not the locale or the time zone — each of those
    /// narrows the crowd a ping is lost in, and none of them changes the count.
    static func payload(version: String, osMajor: Int, arch: String, channel: String) -> [String: Any] {
        ["v": schema, "app": version, "os": String(osMajor), "arch": arch, "channel": channel]
    }

    /// Whether to send now. `noticedAt` is when the user was told the ping exists; the first ping
    /// waits a full day after that so there is time to turn it off before anything is sent —
    /// the notice is a notice, not a receipt. After that, one per day at most, measured from
    /// the last attempt rather than the last success so a dead receiver does not turn a daily
    /// ping into a retry loop.
    static func due(now: TimeInterval, lastAttempt: TimeInterval?, noticedAt: TimeInterval?) -> Bool {
        guard let noticedAt else { return false }
        if now - noticedAt < interval { return false }
        if let lastAttempt, now - lastAttempt < interval { return false }
        return true
    }

    /// The architecture this process runs as. Reported as-is: a Rosetta-translated build says
    /// x86_64, which is the truth about the binary and the only one the app can observe.
    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }
}
