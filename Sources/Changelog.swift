import Foundation

/// The app's own "what's new" source: build.sh ships CHANGELOG.md into Contents/Resources,
/// and the menu shows the section for the version that just started running (or the release
/// body GitHub returned, for a version that is only available yet).
///
/// The file is hand-written hard-wrapped markdown, so display needs two passes: cut out one
/// version's section, then reflow it — a wrapped continuation line belongs to the bullet or
/// paragraph above it, not on a ragged line of its own in a window of a different width.
/// Inline `**`/`` ` `` markers survive into blocks and are resolved by `spans`, so the window
/// can render the changelog's bold lead sentences and code mentions instead of flattening
/// them. A real markdown renderer is a dependency these two markers do not justify.
enum Changelog {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    enum Span: Equatable {
        case plain(String)
        case bold(String)
        case code(String)
    }

    /// The body between `## [<version>]` and the next `## [` header (or the end of the file).
    static func section(for version: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## [\(version)]") })
        else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("## [") {
            end = i
            break
        }
        let body = lines[(start + 1)..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// The date half of a `## [<version>] - <date>` header, or nil when the header carries none.
    static func date(for version: String, in markdown: String) -> String? {
        let prefix = "## [\(version)]"
        guard let line = markdown.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let rest = line.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return rest.isEmpty ? nil : rest
    }

    /// Reflow a section into display blocks. `###` opens a heading, `-` opens a bullet, a blank
    /// line closes whatever is open, and any other line is a continuation of the open block.
    /// Lines are trimmed with newlines included: GitHub release bodies arrive CRLF, and a
    /// stray `\r` glued to a line would defeat both the prefix checks and clean reflow.
    static func blocks(from section: String) -> [Block] {
        var out: [Block] = []
        var open: Block?
        func close() {
            if let b = open { out.append(b) }
            open = nil
        }
        func append(_ text: String) {
            switch open {
            case .heading(let s): open = .heading(s + " " + text)
            case .bullet(let s): open = .bullet(s + " " + text)
            case .paragraph(let s): open = .paragraph(s + " " + text)
            case nil: open = .paragraph(text)
            }
        }
        for raw in section.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                close()
            } else if line.hasPrefix("### ") {
                close()
                open = .heading(String(line.dropFirst(4)))
                close()
            } else if line.hasPrefix("- ") {
                close()
                open = .bullet(String(line.dropFirst(2)))
            } else {
                append(line)
            }
        }
        close()
        return out
    }

    /// One block's text resolved into styled runs: `**` toggles bold, backticks toggle code.
    /// An unbalanced marker is left as literal text rather than styling everything after it —
    /// release bodies are hand-written, and a typo should cost one odd character, not the
    /// readability of the rest of the window.
    static func spans(from text: String) -> [Span] {
        func codeSplit(_ s: String, bold: Bool) -> [Span] {
            let parts = s.components(separatedBy: "`")
            let balanced = parts.count % 2 == 1
            return parts.enumerated().compactMap { i, p in
                let inCode = balanced && i % 2 == 1
                let literal = balanced ? p : (i > 0 ? "`" + p : p)
                if literal.isEmpty { return nil }
                if inCode { return .code(p) }
                return bold ? .bold(literal) : .plain(literal)
            }
        }
        let parts = text.components(separatedBy: "**")
        let balanced = parts.count % 2 == 1
        return parts.enumerated().flatMap { i, p -> [Span] in
            let inBold = balanced && i % 2 == 1
            let literal = balanced ? p : (i > 0 ? "**" + p : p)
            if literal.isEmpty { return [] }
            return codeSplit(inBold ? p : literal, bold: inBold)
        }
    }
}
