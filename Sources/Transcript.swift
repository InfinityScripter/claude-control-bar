import Foundation

/// Reading what Claude Code writes into `~/.claude/projects/**/*.jsonl`.
///
/// Its own file so the checks in `tests/model` can compile it. main.swift carries the top-level
/// `app.run()` and cannot be linked into a test binary, which is how the one piece of transcript
/// parsing the whole session state hangs on went uncovered — and stayed wrong.
enum Transcript {
    /// What Claude Code writes when a turn is cut short with Esc or a denied permission. Neither
    /// fires a hook, so the session's state file freezes mid-turn and this marker is the only
    /// thing that says the turn is over.
    static let interruptMarkers: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    /// Whether a transcript line IS the interrupt marker — parsed, not searched.
    ///
    /// The raw JSONL used to be scanned for "interrupted by user" anywhere in the line, and a tool
    /// result is itself a `"type":"user"` record carrying whatever the tool returned. So reading
    /// any file that contains the phrase — this repository's own sources do, in three places —
    /// froze a session that was plainly working: mid-turn the animation and the timer stopped, and
    /// one waiting on permission lost its amber alert. Measured across this machine's transcripts:
    /// 27 lines carry the phrase without being an interrupt, against 2 that are one.
    static func wasInterrupted(_ line: String) -> Bool {
        guard line.contains("interrupted by user"),   // cheap gate before paying for the parse
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "user",
              let message = root["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return interruptMarkers.contains(text) }
        return (message["content"] as? [[String: Any]] ?? []).contains {
            ($0["text"] as? String).map(interruptMarkers.contains) ?? false
        }
    }
}
