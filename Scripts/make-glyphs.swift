// Builds the menu bar and notification images from Resources/Glyph-source.png.
// Usage: swift Scripts/make-glyphs.swift   (run from the repository root)
//
// The glyph is cropped to its opaque bounding box, centred on a transparent square and scaled to:
//   MenuBarIcon.png / @2x / @3x   18 pt  (the height macOS gives menu bar items)
//   NotificationIcon.png          256 px (attached to notifications)
//   Glyph.png / @2x               64 pt  (in-app header)
import AppKit
import CoreGraphics

let source = "Resources/Glyph-source.png"
guard let image = NSImage(contentsOfFile: source),
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot read \(source)") }

let width = cg.width, height = cg.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
pixels.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: info)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// A background that is opaque white instead of transparent is keyed out by luminance.
let cornerAlpha = pixels[3]
if cornerAlpha > 200 {
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
        let whiteness = min(r, g, b) / 255
        let alpha = whiteness > 0.93 ? 0 : min(1, (1 - whiteness) * 3)
        pixels[i] = UInt8(r * alpha); pixels[i + 1] = UInt8(g * alpha); pixels[i + 2] = UInt8(b * alpha)
        pixels[i + 3] = UInt8(255 * alpha)
    }
}

var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let keyed = pixels.withUnsafeMutableBytes { buffer -> CGImage in
    CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: info)!.makeImage()!
}
let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let cropped = keyed.cropping(to: box)!

func write(_ name: String, side: Int, inset: Double) {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    let usable = Double(side) * (1 - 2 * inset)
    let scale = usable / Double(max(cropped.width, cropped.height))
    let w = Double(cropped.width) * scale, h = Double(cropped.height) * scale
    ctx.draw(cropped, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/\(name)"))
    print("Resources/\(name)  \(side)x\(side)")
}

write("MenuBarIcon.png", side: 18, inset: 0)
write("MenuBarIcon@2x.png", side: 36, inset: 0)
write("MenuBarIcon@3x.png", side: 54, inset: 0)
write("NotificationIcon.png", side: 256, inset: 0.06)
write("Glyph.png", side: 64, inset: 0.04)
write("Glyph@2x.png", side: 128, inset: 0.04)
