import Foundation

/// Turning a row's CLI session id into something Claude for Desktop will act on.
///
/// A menu row is keyed by the id in state.d/, which is the `claude` process's session id. The
/// desktop app knows conversations by an id of its own, and clicking a row could do nothing
/// better than focus the app itself — so every desktop row did the same nothing, which is
/// exactly how "switching sessions doesn't work" looked.
///
/// The bridge is on disk. The app files every conversation as
/// ~/Library/Application Support/Claude/claude-code-sessions/<account>/<workspace>/local_<uuid>.json,
/// and each of those records the cliSessionId of the process behind it. Its file name is the id
/// the app answers to.
enum DesktopSessions {
    static let defaultRoot = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    /// The desktop app's own id for the conversation running under `cliSession`, or nil when
    /// this machine has no record of it (a session that was never opened in the app).
    ///
    /// Newest file wins: importing a CLI session can leave more than one record pointing at the
    /// same conversation, and the most recent is the one the app is actually showing.
    static func sessionID(forCLI cliSession: String, root: String = defaultRoot) -> String? {
        guard !cliSession.isEmpty else { return nil }
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                       includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        // Matched as text rather than parsed: the app writes these with JSON.stringify, so the
        // pair is always spelled exactly this way. A miss costs nothing — the caller falls back
        // to merely focusing the app, which is what every click did before.
        //
        // Only the head of each file is read. cliSessionId is the second key the app writes,
        // within the first hundred bytes; the rest of the record is the enabled-tool map, one
        // key per MCP tool, and an account with a few hundred tools pushes the file past
        // 200 KB. The previous whole-file read with a 200 KB size cap skipped exactly those —
        // 150 of 718 records on one machine — so every click on a busy session merely opened
        // the app. Reading 4 KB per file also makes the walk over hundreds of records cheap.
        let needle = "\"cliSessionId\":\"\(cliSession)\""
        var best: (name: String, at: Date)?
        for case let url as URL in walk
        where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { continue }
            let head = handle.readData(ofLength: 4096)
            handle.closeFile()
            // Lossy decoding on purpose: the 4 KB cut can land inside a multibyte character in
            // a title, and a strict decode would drop the whole record for it.
            guard String(decoding: head, as: UTF8.self).contains(needle) else { continue }
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || at > best!.at { best = (url.deletingPathExtension().lastPathComponent, at) }
        }
        return best?.name
    }

    /// The deep link that switches the app to a conversation.
    ///
    /// This route and no other: claude://code/<id> wants a BRIDGE session id, which a local
    /// conversation does not have (measured on a real install: 0 of 441 session files carry
    /// one, and the app logs "unrecognized code path" for every local id handed to it).
    /// claude://resume?session=<id> is an import verb — it calls importCliSession() and spawns a
    /// duplicate "ungrouped" record on every click.
    static func focusURL(sessionID: String) -> URL? {
        URL(string: "claude://claude.ai/epitaxy/\(sessionID)")
    }
}
