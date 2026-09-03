import Cocoa

// Renders a full-color crab frame as an adaptive TEMPLATE image for System color mode.
// A template (isTemplate=true) is drawn by macOS in one uniform system color (black on a light
// menu bar, white on a dark one, automatically), so only the alpha channel can carry detail.
// To keep the sprite's depth, brightness is mapped to opacity: the bright body stays solid, the
// darker legs/shading fade to partial (gray) ink, and the darkest pixels (eyes, outlines) drop out
// entirely as transparent holes, the same negative-space eyes as the original. Source coverage
// (anti-aliased edges) is preserved by modulating the original alpha. Run once per frame at load
// and cached by the caller, so it costs nothing during the animation.
func adaptiveCrabFrame(_ src: NSImage) -> NSImage {
    guard let tiff = src.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff),
          let cgSrc = bmp.cgImage else { return src }
    let pw = bmp.pixelsWide, ph = bmp.pixelsHigh
    let cs = CGColorSpaceCreateDeviceRGB()
    let bi = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: pw * 4, space: cs, bitmapInfo: bi) else { return src }
    ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: pw, height: ph))
    guard let raw = ctx.data else { return src }
    let px = raw.bindMemory(to: UInt8.self, capacity: pw * ph * 4)

    // Tuned by eye. Brightness -> opacity: pixels below `darkCut` become transparent holes (eyes);
    // brightness from darkCut up to `bodyLevel` ramps gray -> solid, so the body reads solid and the
    // legs stay gray. `gamma` shapes that ramp (>1 keeps more of it gray, <1 fills toward solid).
    // Measured from the sprite: eyes/outlines lum <= 0.15, darker legs ~0.45, body ~0.57. So darkCut
    // sits above the eyes (they punch through as holes) and below the legs (they stay gray), and
    // bodyLevel sits at the body brightness (it goes solid). gamma deepens the legs' gray.
    let darkCut = 0.30, bodyLevel = 0.54, gamma = 1.3
    for i in 0..<(pw * ph) {
        let off = i * 4
        let rawA = px[off + 3]
        guard rawA > 0 else { continue }                 // background stays transparent
        let af = Double(rawA) / 255
        let r = Double(px[off])     / (255 * af)
        let g = Double(px[off + 1]) / (255 * af)
        let b = Double(px[off + 2]) / (255 * af)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        px[off] = 0; px[off + 1] = 0; px[off + 2] = 0    // template ink is black
        if lum < darkCut {
            px[off + 3] = 0                              // eyes / outlines: transparent holes
        } else {
            let t = min(1, (lum - darkCut) / (bodyLevel - darkCut))
            px[off + 3] = UInt8(max(0, min(255, Double(rawA) * pow(t, gamma))))
        }
    }
    guard let outCG = ctx.makeImage() else { return src }
    let img = NSImage(cgImage: outCG, size: src.size)
    img.isTemplate = true
    return img
}

// Three tones from one. The sprite is flat: one orange, black eyes, and it reads as a sticker at
// 18 pt. A light from the top-left gives it volume without a second palette to maintain: every
// solid pixel whose neighbour above or to the left is empty takes a lighter tone of ITS OWN
// colour, one whose neighbour below or to the right is empty takes a darker one, everything else
// stays. Own colour, so the same pass shades the orange shell, the red overheated one, the smoke
// and the flames alike, and the mood generator keeps drawing in flat colour and never learns
// about tones. Ink (eyes, mouths) is left alone: it is negative space, not a surface. Runs once
// per frame at load; the caller caches the result.
func shadedCrabFrame(_ image: NSImage) -> NSImage {
    guard let src = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
            ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return image }
    let w = src.pixelsWide, h = src.pixelsHigh
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return image }
    // Anti-aliased edge pixels (the walk's leg edges sit at 20–50% alpha) count as empty: the
    // solid pixel beside them is the edge, and they keep their own softness.
    func solid(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < w, y < h, let c = src.colorAt(x: x, y: y) else { return false }
        return c.alphaComponent >= 0.5
    }
    let highlight: CGFloat = 1.14, shadow: CGFloat = 0.72
    for y in 0..<h {
        for x in 0..<w {
            guard let c = src.colorAt(x: x, y: y) else { continue }
            var tone = c
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            if c.alphaComponent >= 0.9, lum >= 0.15 {
                var k: CGFloat = 1
                if !solid(x, y + 1) || !solid(x + 1, y) { k = shadow }        // underside, right edge
                else if !solid(x, y - 1) || !solid(x - 1, y) { k = highlight } // crown, left edge
                if k != 1 {
                    tone = NSColor(deviceRed: min(1, c.redComponent * k), green: min(1, c.greenComponent * k),
                                   blue: min(1, c.blueComponent * k), alpha: c.alphaComponent)
                }
            }
            out.setColor(tone, atX: x, y: y)
        }
    }
    let result = NSImage(size: image.size)
    result.addRepresentation(out)
    return result
}
