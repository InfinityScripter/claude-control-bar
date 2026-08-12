import Foundation

/// The app's own "what's new" source: build.sh ships CHANGELOG.md into Contents/Resources,
/// and the menu shows the section for the version that just started running (or the release
/// body GitHub returned, for a version that is only available yet).
///
/// The file is hand-written hard-wrapped markdown, so display needs two passes: cut out one
/// version's section, then reflow it — a wrapped continuation line belongs to the bullet or
/// paragraph above it, not on a ragged line of its own in a window of a different width.
/// Inline `**`/`` ` `` markers are stripped rather than rendered: the text reads fine without
/// them, and a real markdown renderer is a dependency this one window does not justify.
enum Changelog {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
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

    /// Reflow a section into display blocks. `###` opens a heading, `-` opens a bullet, a blank
    /// line closes whatever is open, and any other line is a continuation of the open block.
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
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
            } else if line.hasPrefix("### ") {
                close()
                open = .heading(stripInline(String(line.dropFirst(4))))
                close()
            } else if line.hasPrefix("- ") {
                close()
                open = .bullet(stripInline(String(line.dropFirst(2))))
            } else {
                append(stripInline(line))
            }
        }
        close()
        return out
    }

    /// Drops `**` and backticks. Blind global removal, not pair matching: the changelog uses
    /// them only as markers, and a stray unpaired one reads better gone too.
    static func stripInline(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}
