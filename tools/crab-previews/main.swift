import Cocoa
import ImageIO
import UniformTypeIdentifiers

// Regenerates assets/crab-moods/*.gif from the runtime frames, at the runtime tempo, 4x:
//   swiftc -O Sources/Model/*.swift tools/crab-previews/main.swift -o /tmp/previews -framework Cocoa && /tmp/previews
// Run from the repository root. The README's mood table embeds these files; the frames and the
// timing are the app's own, so the previews cannot drift from what the menu bar shows.

let scale = 4
let outDir = FileManager.default.currentDirectoryPath + "/assets/crab-moods"
let set = CrabFrameSet(walking: clawdCrabFramePNGs.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) })
let files: [(CrabMood, String, Int)] = [   // mood, file, working sessions the tempo is shown at
    (.sleeping, "sleeping", 0), (.cigar, "cigar", 1), (.walking, "walking", 3),
    (.overheated, "overheated", 5), (.onFire, "on-fire", 6), (.waitingPermission, "permission", 0),
]
for (mood, name, working) in files {
    let frames = set.frames(for: mood)
    guard let first = frames.first?.representations.first as? NSBitmapImageRep else { continue }
    let w = first.pixelsWide * scale, h = first.pixelsHigh * scale
    let url = URL(fileURLWithPath: "\(outDir)/\(name).gif")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { continue }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = 1.0 / mood.framesPerSecond(working: working)
    for frame in frames {
        guard let rep = frame.representations.first as? NSBitmapImageRep,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: out)!
        NSGraphicsContext.current = ctx
        ctx.cgContext.interpolationQuality = .none
        // The README renders on white and on dark; a light neutral card reads on both.
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = out.cgImage else { continue }
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    print(CGImageDestinationFinalize(dest) ? "wrote" : "FAILED", url.lastPathComponent, frames.count, "frames at", 1 / delay, "fps")
}
