// Usage: swiftc -O make-icon.swift -o /tmp/make-icon && /tmp/make-icon source.png AppIcon-1024.png
// then build Configuration/AppIcon.icns from it with sips and iconutil (see docs/HANDOFF.md).
import AppKit
import CoreGraphics
import CoreImage

// Builds a 1024px macOS icon from a small photo of white lettering on red:
// the lettering becomes a mask that is enlarged and re-sharpened, the red
// background is filled in under it and enlarged smoothly, then both go in
// the rounded body of Apple's icon grid with its drop shadow.
let src = CommandLine.arguments[1], out = CommandLine.arguments[2]
let image = NSImage(contentsOfFile: src)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = image.width, h = image.height
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func grayContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
}
let source = rgbaContext(w, h)
source.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = source.data!.assumingMemoryBound(to: UInt8.self)

// Lettering coverage: the red has low green and blue, the lettering is white.
var cover = [Double](repeating: 0, count: w * h)
for i in 0..<(w * h) {
    let v = Double(min(px[i*4], px[i*4+1], px[i*4+2]))
    cover[i] = max(0, min(1, (v - 100) / 120))
}

// Background with the lettering filled in from the surrounding red.
let bg = rgbaContext(w, h)
let b = bg.data!.assumingMemoryBound(to: UInt8.self)
var known = cover.map { $0 < 0.02 }
for i in 0..<(w * h * 4) { b[i] = px[i] }
// Grow the lettering mask by 2px so its antialiased fringe is replaced too.
for _ in 0..<2 {
    let k = known
    for y in 0..<h { for x in 0..<w where k[y*w+x] {
        for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
            let nx = x+dx, ny = y+dy
            if nx >= 0, ny >= 0, nx < w, ny < h, !k[ny*w+nx] { known[y*w+x] = false }
        }
    }}
}
var remaining = known.filter { !$0 }.count
while remaining > 0 {
    let k = known
    for y in 0..<h { for x in 0..<w where !k[y*w+x] {
        var s = (0, 0, 0), n = 0
        for dy in -1...1 { for dx in -1...1 {
            let nx = x+dx, ny = y+dy
            if nx >= 0, ny >= 0, nx < w, ny < h, k[ny*w+nx] {
                let j = (ny*w+nx)*4; s.0 += Int(b[j]); s.1 += Int(b[j+1]); s.2 += Int(b[j+2]); n += 1
            }
        }}
        if n > 0 { let j = (y*w+x)*4; b[j] = UInt8(s.0/n); b[j+1] = UInt8(s.1/n); b[j+2] = UInt8(s.2/n); b[j+3] = 255; known[y*w+x] = true; remaining -= 1 }
    }}
}
let background = bg.makeImage()!

let S = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185.4
let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Lettering mask: enlarge smoothly, then steepen the edge so it is crisp again.
let small = grayContext(w, h)
let sm = small.data!.assumingMemoryBound(to: UInt8.self)
for i in 0..<(w*h) { sm[i] = UInt8(cover[i] * 255) }
let side = Int(body.width)
let big = grayContext(side, side)
big.interpolationQuality = .high
big.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: side, height: side))
// Smooth the stair-steps of the small source before steepening the edge.
let blurred = CIImage(cgImage: big.makeImage()!).clampedToExtent()
    .applyingGaussianBlur(sigma: Double(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "1.8")!)
    .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
CIContext(options: [.workingColorSpace: NSNull()]).render(blurred, toBitmap: big.data!, rowBytes: side, bounds: blurred.extent, format: .L8, colorSpace: nil)
let bm = big.data!.assumingMemoryBound(to: UInt8.self)
for i in 0..<(side*side) {
    let a = Double(bm[i]) / 255
    let t = max(0, min(1, (a - 0.38) / 0.24))     // edge about 1px wide at this size
    bm[i] = UInt8(t * t * (3 - 2 * t) * 255)
}
let mask = big.makeImage()!

let canvas = rgbaContext(S, S)
canvas.interpolationQuality = .high
// Apple's grid: a soft shadow under the body.
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.30))
canvas.addPath(bodyPath); canvas.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.05, alpha: 1)); canvas.fillPath()
canvas.restoreGState()
canvas.saveGState()
canvas.addPath(bodyPath); canvas.clip()
canvas.draw(background, in: body)
canvas.clip(to: body, mask: mask)
canvas.setFillColor(.white); canvas.fill(body)
canvas.restoreGState()
let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
