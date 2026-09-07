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

    /// The glyph a section's bullets carry, the way the section color already speaks for them:
    /// a plus for additions, a check for fixes, sliders for changes. Unknown sections keep a dot.
    static func sectionSymbol(_ name: String) -> String {
        switch name.lowercased() {
        case "added": return "plus.circle.fill"
        case "fixed": return "checkmark.circle.fill"
        case "changed": return "slider.horizontal.3"
        case "removed", "deprecated": return "minus.circle.fill"
        case "security": return "lock.fill"
        default: return "circle.fill"
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
        // The section's glyph in its color, built once per heading and reused by its bullets.
        // Hierarchical, not a flat palette: a flat color paints the disc and the glyph inside
        // it alike, and every two-layer symbol came out a plain disc.
        var glyph: NSImage?
        for block in Changelog.blocks(from: markdown) {
            switch block {
            case .heading(let s):
                glyph = NSImage(systemSymbolName: sectionSymbol(s), accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: sectionColor(s)))
                text.append(NSAttributedString(string: s.uppercased() + "\n", attributes: [
                    .font: headFont, .foregroundColor: sectionColor(s),
                    .kern: 1.2, .paragraphStyle: headPara]))
            case .bullet(let s):
                // The paragraph style rides on the first run: the marker, not the text after
                // it. A plain dot when the symbol is missing (an older macOS), never a blank.
                if let glyph {
                    let attachment = NSTextAttachment()
                    attachment.image = glyph
                    attachment.bounds = CGRect(x: 0, y: -3, width: 15, height: 15)
                    let marker = NSMutableAttributedString(attachment: attachment)
                    marker.addAttribute(.paragraphStyle, value: bulletPara, range: NSRange(location: 0, length: 1))
                    text.append(marker)
                } else {
                    text.append(NSAttributedString(string: "\u{2022}", attributes: [
                        .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: bulletPara]))
                }
                text.append(NSAttributedString(string: "  ", attributes: [.font: bodyFont, .paragraphStyle: bulletPara]))
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

    /// `install` adds the bottom bar — "Later" and the default "Download and install" button
    /// wired to the given target/action — when the notes belong to a release newer than the
    /// running one. The button is returned so its title can follow the download's progress.
    static func contentView(version: String, markdown: String, date: String?,
                            icon iconImage: NSImage?,
                            install: (target: AnyObject, action: Selector)? = nil)
        -> (view: NSView, installButton: NSButton?) {
        let width: CGFloat = 560, height: CGFloat = 540, headerH: CGFloat = 76
        let barH: CGFloat = install == nil ? 0 : 60
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var installButton: NSButton?
        if let install {
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barH))
            bar.autoresizingMask = [.width, .maxYMargin]
            let rule = NSBox(frame: NSRect(x: 0, y: barH - 1, width: width, height: 1))
            rule.boxType = .separator
            rule.autoresizingMask = [.width, .minYMargin]
            bar.addSubview(rule)
            // No target: performClose walks the responder chain to the window, which closes.
            let later = NSButton(title: "Later", target: nil, action: #selector(NSWindow.performClose(_:)))
            later.bezelStyle = .rounded
            later.keyEquivalent = "\u{1B}"
            later.sizeToFit()
            later.setFrameOrigin(NSPoint(x: 20, y: (barH - later.frame.height) / 2))
            bar.addSubview(later)
            let go = NSButton(title: "Download and install", target: install.target, action: install.action)
            go.bezelStyle = .rounded
            go.keyEquivalent = "\r"
            go.sizeToFit()
            go.frame.size.width = max(go.frame.width, 190)
            go.setFrameOrigin(NSPoint(x: width - 20 - go.frame.width, y: (barH - go.frame.height) / 2))
            go.autoresizingMask = [.minXMargin]
            bar.addSubview(go)
            container.addSubview(bar)
            installButton = go
        }

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

        let scroll = NSScrollView(frame: NSRect(x: 0, y: barH, width: width, height: height - headerH - barH))
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
        return (container, installButton)
    }
}
