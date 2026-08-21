import Cocoa

enum CrabMood: String, CaseIterable {
    case sleeping, waitingPermission, cigar, walking, overheated, onFire

    static func forEffectiveStates(_ states: [String]) -> CrabMood {
        let working = states.reduce(0) { count, state in
            count + ((state == "thinking" || state == "tool") ? 1 : 0)
        }
        switch working {
        case 0: return .sleeping
        case 1: return .cigar
        case 2...3: return .walking
        case 4...5: return .overheated
        default: return .onFire
        }
    }

    static func display(forEffectiveStates states: [String], leadState: String?) -> CrabMood {
        leadState == "permission" ? .waitingPermission : forEffectiveStates(states)
    }

    var framesPerSecond: Double {
        switch self {
        case .sleeping: return 2
        case .waitingPermission: return 3
        case .cigar: return 4
        case .walking: return 12.5
        case .overheated: return 8
        case .onFire: return 10
        }
    }

    var keepsColorInSystem: Bool { self == .overheated || self == .onFire }
}

func attentionBadgeIcon(_ icon: NSImage, color: NSColor) -> NSImage {
    let gutter: CGFloat = 2, diameter: CGFloat = 5
    let size = NSSize(width: icon.size.width + gutter, height: icon.size.height)
    let image = NSImage(size: size, flipped: false) { _ in
        let iconRect = NSRect(origin: .zero, size: icon.size)
        if icon.isTemplate {
            NSColor.labelColor.setFill()
            iconRect.fill()
            icon.draw(in: iconRect, from: .zero, operation: .destinationIn, fraction: 1)
        } else {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width - diameter, y: size.height - diameter,
                                    width: diameter, height: diameter)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

struct CrabFrameSet {
    private static let width = 51, height = 36
    private static let body = NSColor(deviceRed: 226 / 255, green: 139 / 255, blue: 106 / 255, alpha: 1)
    private static let hotBody = NSColor(deviceRed: 232 / 255, green: 47 / 255, blue: 39 / 255, alpha: 1)
    private static let ink = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
    private static let smoke = NSColor(deviceRed: 0.76, green: 0.78, blue: 0.80, alpha: 1)
    private static let sweat = NSColor(deviceRed: 0.48, green: 0.82, blue: 0.94, alpha: 1)
    private static let cigarBrown = NSColor(deviceRed: 0.54, green: 0.36, blue: 0.18, alpha: 1)
    private static let ember = NSColor(deviceRed: 1, green: 0.34, blue: 0.02, alpha: 1)
    private static let flameOrange = NSColor(deviceRed: 1, green: 0.48, blue: 0.02, alpha: 1)
    private static let flameYellow = NSColor(deviceRed: 1, green: 0.82, blue: 0.16, alpha: 1)
    private static let watchFace = NSColor(deviceRed: 0.88, green: 0.88, blue: 0.86, alpha: 1)

    private let sleeping: [NSImage]
    private let waitingPermission: [NSImage]
    private let cigar: [NSImage]
    private let walking: [NSImage]
    private let overheated: [NSImage]
    private let onFire: [NSImage]

    init(walking: [NSImage]) {
        self.walking = walking
        guard let base = walking.first, let bitmap = Self.bitmap(base) else {
            sleeping = []; waitingPermission = []; cigar = []; overheated = []; onFire = []
            return
        }
        sleeping = Self.sleepingFrames(bitmap)
        waitingPermission = Self.waitingPermissionFrames(bitmap)
        cigar = Self.cigarFrames(bitmap)
        overheated = Self.overheatedFrames(bitmap)
        onFire = Self.fireFrames(bitmap)
    }

    func frames(for mood: CrabMood) -> [NSImage] {
        switch mood {
        case .sleeping: return sleeping
        case .waitingPermission: return waitingPermission
        case .cigar: return cigar
        case .walking: return walking
        case .overheated: return overheated
        case .onFire: return onFire
        }
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.pixelsWide == width, rep.pixelsHigh == height { return rep }
        return image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    }

    private static func blank() -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: 0, bitsPerPixel: 0)!
    }

    private static func baseFrame(_ source: NSBitmapImageRep, xOffset: Int = 0,
                                  yOffset: Int = 0, hot: Bool = false) -> NSBitmapImageRep {
        let out = blank()
        for y in 0..<height {
            for x in 0..<width {
                guard let color = source.colorAt(x: x, y: y),
                      color.alphaComponent > 0 else { continue }
                let tx = x + xOffset, ty = y + yOffset
                guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                if hot {
                    let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent
                        + 0.114 * color.blueComponent
                    if luminance < 0.2 {
                        out.setColor(NSColor(deviceRed: 0.04, green: 0.04, blue: 0.04,
                                             alpha: color.alphaComponent), atX: tx, y: ty)
                    } else {
                        let shade = min(1, max(0, (luminance - 0.35) / 0.35))
                        out.setColor(NSColor(deviceRed: 0.80 + 0.11 * shade,
                                             green: 0.08 + 0.10 * shade,
                                             blue: 0.05 + 0.04 * shade,
                                             alpha: color.alphaComponent), atX: tx, y: ty)
                    }
                } else {
                    out.setColor(color, atX: tx, y: ty)
                }
            }
        }
        return out
    }

    private static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private static func fill(_ rep: NSBitmapImageRep, x: Int, y: Int,
                             width: Int, height: Int, color: NSColor) {
        for py in max(0, y)..<min(Self.height, y + height) {
            for px in max(0, x)..<min(Self.width, x + width) {
                rep.setColor(color, atX: px, y: py)
            }
        }
    }

    private static func redrawEyes(_ rep: NSBitmapImageRep, xOffset: Int = 0,
                                   yOffset: Int = 0, hot: Bool = false, squeezed: Bool = false) {
        let bodyColor = hot ? hotBody : body
        fill(rep, x: 13 + xOffset, y: 6 + yOffset, width: 4, height: 5, color: bodyColor)
        fill(rep, x: 34 + xOffset, y: 6 + yOffset, width: 4, height: 5, color: bodyColor)
        if squeezed {
            fill(rep, x: 13 + xOffset, y: 8 + yOffset, width: 3, height: 1, color: ink)
            fill(rep, x: 14 + xOffset, y: 9 + yOffset, width: 3, height: 1, color: ink)
            fill(rep, x: 35 + xOffset, y: 8 + yOffset, width: 3, height: 1, color: ink)
            fill(rep, x: 34 + xOffset, y: 9 + yOffset, width: 3, height: 1, color: ink)
        } else {
            fill(rep, x: 13 + xOffset, y: 9 + yOffset, width: 4, height: 1, color: ink)
            fill(rep, x: 34 + xOffset, y: 9 + yOffset, width: 4, height: 1, color: ink)
        }
    }

    private static func drawZ(_ rep: NSBitmapImageRep, x: Int, y: Int, faded: Bool = false) {
        let color = NSColor(deviceRed: 0.95, green: 0.63, blue: 0.49, alpha: faded ? 0.55 : 1)
        fill(rep, x: x, y: y, width: 4, height: 1, color: color)
        fill(rep, x: x + 2, y: y + 1, width: 1, height: 1, color: color)
        fill(rep, x: x + 1, y: y + 2, width: 1, height: 1, color: color)
        fill(rep, x: x, y: y + 3, width: 4, height: 1, color: color)
    }

    private static func sleepingFrames(_ source: NSBitmapImageRep) -> [NSImage] {
        let shifts = [4, 4, 2, 1, 1, 3]
        return shifts.enumerated().map { index, yOffset in
            let rep = baseFrame(source, yOffset: yOffset)
            redrawEyes(rep, yOffset: yOffset)
            if index == 2 { drawZ(rep, x: 43, y: 0) }
            if index == 3 { drawZ(rep, x: 39, y: 0) }
            if index == 4 { drawZ(rep, x: 34, y: 0) }
            if index == 5 { drawZ(rep, x: 30, y: 0, faded: true) }
            return image(rep)
        }
    }

    private static func drawWaitingEyes(_ rep: NSBitmapImageRep, xOffset: Int,
                                        yOffset: Int, direction: Int) {
        fill(rep, x: 13 + xOffset, y: 6 + yOffset, width: 4, height: 5, color: body)
        fill(rep, x: 34 + xOffset, y: 6 + yOffset, width: 4, height: 5, color: body)
        if direction == 2 {
            fill(rep, x: 13 + xOffset, y: 9 + yOffset, width: 4, height: 1, color: ink)
            fill(rep, x: 34 + xOffset, y: 9 + yOffset, width: 4, height: 1, color: ink)
        } else {
            let gazeX = direction == 1 ? -1 : 0
            let gazeY = direction == 1 ? 1 : 0
            fill(rep, x: 14 + xOffset + gazeX, y: 8 + yOffset + gazeY,
                 width: 3, height: 3, color: ink)
            fill(rep, x: 35 + xOffset + gazeX, y: 8 + yOffset + gazeY,
                 width: 3, height: 3, color: ink)
        }
    }

    private static func drawWatch(_ rep: NSBitmapImageRep, xOffset: Int,
                                  yOffset: Int, handPhase: Int) {
        fill(rep, x: 2 + xOffset, y: 12 + yOffset, width: 6, height: 6, color: smoke)
        fill(rep, x: 3 + xOffset, y: 13 + yOffset, width: 4, height: 4, color: watchFace)
        let centerX = 5 + xOffset, centerY = 15 + yOffset
        fill(rep, x: centerX, y: centerY, width: 1, height: 1, color: ink)
        if handPhase == 0 {
            fill(rep, x: centerX, y: centerY - 2, width: 1, height: 2, color: ink)
            fill(rep, x: centerX + 1, y: centerY, width: 2, height: 1, color: ink)
        } else {
            fill(rep, x: centerX - 2, y: centerY, width: 2, height: 1, color: ink)
            fill(rep, x: centerX, y: centerY + 1, width: 1, height: 2, color: ink)
        }
    }

    private static func waitingPermissionFrames(_ source: NSBitmapImageRep) -> [NSImage] {
        let xOffsets = [0, 0, -1, -2, -2, 0, 0, 0]
        let yOffsets = [0, 0, 0, 1, 1, 0, 0, 0]
        let eyeDirections = [0, 0, 1, 1, 1, 0, 2, 0]
        let handPhases = [0, 0, 0, 0, 1, 1, 1, 0]
        return (0..<8).map { index in
            let x = xOffsets[index], y = yOffsets[index]
            let rep = baseFrame(source, xOffset: x, yOffset: y)
            drawWaitingEyes(rep, xOffset: x, yOffset: y, direction: eyeDirections[index])
            drawWatch(rep, xOffset: x, yOffset: y, handPhase: handPhases[index])
            return image(rep)
        }
    }

    private static func drawSmoke(_ rep: NSBitmapImageRep, phase: Int,
                                  xOffset: Int, yOffset: Int) {
        let points: [[(Int, Int)]] = [
            [], [], [], [(48, 12), (48, 11)],
            [(47, 10), (46, 9), (46, 8)],
            [(46, 7), (45, 6), (45, 5), (46, 4)],
            [(44, 4), (43, 3), (44, 2)],
            [(42, 2), (41, 1), (42, 0)]
        ]
        for (x, y) in points[phase] {
            fill(rep, x: x + xOffset, y: y + yOffset, width: 2, height: 2, color: smoke)
        }
    }

    private static func cigarFrames(_ source: NSBitmapImageRep) -> [NSImage] {
        let xOffsets = [0, 0, 1, 2, 2, 1, 0, 0]
        let yOffsets = [0, 0, 0, -1, -1, 0, 0, 0]
        return (0..<8).map { index in
            let x = xOffsets[index], y = yOffsets[index]
            let rep = baseFrame(source, xOffset: x, yOffset: y)
            redrawEyes(rep, xOffset: x, yOffset: y)
            fill(rep, x: 38 + x, y: 14 + y, width: 9, height: 3, color: cigarBrown)
            fill(rep, x: 47 + x, y: 14 + y, width: 2, height: 3, color: ember)
            if index == 2 || index == 3 {
                fill(rep, x: 47 + x, y: 14 + y, width: 1, height: 1, color: flameYellow)
            }
            drawSmoke(rep, phase: index, xOffset: x, yOffset: y)
            return image(rep)
        }
    }

    private static func drawSweat(_ rep: NSBitmapImageRep, phase: Int, xOffset: Int, yOffset: Int) {
        let positions: [(Int, Int)?] = [nil, (45, 2), (45, 5), (46, 9), (46, 13), nil,
                                             (5, 2), (4, 5), (4, 9), (4, 13), nil, nil]
        guard let (x, y) = positions[phase] else { return }
        fill(rep, x: x + xOffset, y: y + yOffset, width: 2, height: 3, color: sweat)
        fill(rep, x: x + 1 + xOffset, y: y + 3 + yOffset, width: 1, height: 1, color: sweat)
    }

    private static func overheatedFrames(_ source: NSBitmapImageRep) -> [NSImage] {
        let xOffsets = [0, -1, -2, -2, -1, 0, 1, 2, 2, 1, 0, 0]
        let yOffsets = [1, 0, -1, -1, 0, 1, 2, 2, 1, 0, 1, 1]
        return (0..<12).map { index in
            let x = xOffsets[index], y = yOffsets[index]
            let rep = baseFrame(source, xOffset: x, yOffset: y, hot: true)
            redrawEyes(rep, xOffset: x, yOffset: y, hot: true, squeezed: true)
            drawSweat(rep, phase: index, xOffset: x, yOffset: y)
            return image(rep)
        }
    }

    private static func drawFlames(_ rep: NSBitmapImageRep, phase: Int) {
        let heights = [
            [1, 1, 1], [2, 3, 2], [3, 5, 3], [2, 4, 1],
            [5, 2, 4], [3, 5, 2], [1, 3, 5], [4, 2, 3],
            [2, 5, 4], [5, 3, 1], [3, 4, 5], [1, 1, 1],
        ][phase]
        for (column, x) in [12, 23, 35].enumerated() {
            let height = heights[column]
            fill(rep, x: x, y: 5 - height, width: 5, height: height, color: flameOrange)
            fill(rep, x: x, y: 5, width: 5, height: 1, color: flameOrange)
            fill(rep, x: x + 2, y: max(0, 5 - height), width: 2,
                 height: max(1, height - 2), color: flameYellow)
        }
        if phase == 2 || phase == 5 || phase == 8 {
            fill(rep, x: phase == 5 ? 7 : 43, y: phase == 2 ? 0 : 1,
                 width: 2, height: 2, color: flameOrange)
        }
    }

    private static func fireFrames(_ source: NSBitmapImageRep) -> [NSImage] {
        let xOffsets = [0, -2, 2, -2, 2, 0, -2, 2, -2, 2, 0, 0]
        return (0..<12).map { index in
            let x = xOffsets[index], y = 3
            let rep = baseFrame(source, xOffset: x, yOffset: y, hot: true)
            redrawEyes(rep, xOffset: x, yOffset: y, hot: true, squeezed: true)
            if index < 4 { drawSweat(rep, phase: index + 2, xOffset: x, yOffset: y) }
            drawFlames(rep, phase: index)
            return image(rep)
        }
    }
}
