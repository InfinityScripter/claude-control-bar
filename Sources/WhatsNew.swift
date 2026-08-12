import Cocoa

/// The "What's new" panel content — everything about it except the window that hosts it.
///
/// A separate type, not a corner of StatusController, for one practical reason: main.swift is
/// not linked into any test or harness, so a view built there can only be judged by running
/// the whole app. This file compiles into a bare preview harness too, which renders the panel
/// to an image — the design was reviewed that way before it ever shipped.
enum WhatsNewPanel {
    /// The color convention Keep-a-Changelog section names carry everywhere else too:
    /// additions read green, fixes blue, changes amber. An unknown name stays neutral
    /// rather than guessing.
    static func sectionColor(_ name: String) -> NSColor {
        switch name.lowercased() {
        case "added": return .systemGreen
        case "fixed": return .systemBlue
        case "changed": return .systemOrange
        case "removed", "deprecated": return .systemRed
        case "security": return .systemPurple
        default: return .secondaryLabelColor
        }
    }

    static func body(_ markdown: String) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let plainPara = NSMutableParagraphStyle()
        plainPara.paragraphSpacing = 10
        plainPara.lineSpacing = 2.5
        let bulletPara = NSMutableParagraphStyle()
        bulletPara.paragraphSpacing = 10
        bulletPara.lineSpacing = 2.5
        bulletPara.headIndent = 15
        let headPara = NSMutableParagraphStyle()
        headPara.paragraphSpacingBefore = 14
        headPara.paragraphSpacing = 6
        // The lead sentences the changelog bolds carry the full label color; the prose around
        // them steps back to secondary. That contrast is the whole layout: the eye scans the
        // bold leads like a list of titles, the detail is there when wanted.
        func appendSpans(_ s: String, para: NSParagraphStyle) {
            for span in Changelog.spans(from: s) {
                switch span {
                case .plain(let t):
                    text.append(NSAttributedString(string: t, attributes: [
                        .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: para]))
                case .bold(let t):
                    text.append(NSAttributedString(string: t, attributes: [
                        .font: boldFont, .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: para]))
                case .code(let t):
                    text.append(NSAttributedString(string: t, attributes: [
                        .font: codeFont, .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: para]))
                }
            }
            text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: para]))
        }
        for block in Changelog.blocks(from: markdown) {
            switch block {
            case .heading(let s):
                text.append(NSAttributedString(string: s.uppercased() + "\n", attributes: [
                    .font: headFont, .foregroundColor: sectionColor(s),
                    .kern: 1.2, .paragraphStyle: headPara]))
            case .bullet(let s):
                text.append(NSAttributedString(string: "\u{2022}  ", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: bulletPara]))
                appendSpans(s, para: bulletPara)
            case .paragraph(let s):
                appendSpans(s, para: plainPara)
            }
        }
        return text
    }

    /// "Version 0.7.4 · August 12, 2026" — or just the version when no date is known
    /// (a GitHub release body carries none).
    static func subtitle(version: String, date: String?) -> String {
        var sub = "Version \(version)"
        guard let date else { return sub }
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        if let day = iso.date(from: date) {
            let out = DateFormatter()
            out.dateStyle = .long
            out.timeStyle = .none
            sub += "  \u{00B7}  " + out.string(from: day)
        } else {
            sub += "  \u{00B7}  " + date
        }
        return sub
    }

    static func contentView(version: String, markdown: String, date: String?,
                            icon iconImage: NSImage?) -> NSView {
        let width: CGFloat = 560, height: CGFloat = 540, headerH: CGFloat = 76
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Header: the app's own face, a large title, and the version pinned under it. This is
        // the identity the plain text canvas lacked — the window reads as the app speaking.
        let header = NSView(frame: NSRect(x: 0, y: height - headerH, width: width, height: headerH))
        header.autoresizingMask = [.width, .minYMargin]
        let icon = NSImageView(frame: NSRect(x: 24, y: (headerH - 44) / 2 - 2, width: 44, height: 44))
        icon.image = iconImage
        header.addSubview(icon)
        let title = NSTextField(labelWithString: "What\u{2019}s new")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.frame = NSRect(x: 82, y: headerH - 40, width: width - 106, height: 26)
        title.autoresizingMask = [.width]
        header.addSubview(title)
        let sub = NSTextField(labelWithString: subtitle(version: version, date: date))
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 82, y: headerH - 58, width: width - 106, height: 16)
        sub.autoresizingMask = [.width]
        header.addSubview(sub)
        container.addSubview(header)
        let rule = NSBox(frame: NSRect(x: 0, y: height - headerH, width: width, height: 1))
        rule.boxType = .separator
        rule.autoresizingMask = [.width, .minYMargin]
        container.addSubview(rule)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height - headerH))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 24, height: 18)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(body(markdown))
        scroll.documentView = tv
        container.addSubview(scroll)
        return container
    }
}
