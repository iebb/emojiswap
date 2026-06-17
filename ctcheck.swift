// ctcheck.swift — ask Core Text what "Apple Color Emoji" resolves to right now,
// render 😀, and report whether it draws in color. Output is key=value lines so
// emojiswap.py can parse it. Optional arg: path to write a PNG sample.
import CoreText
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 128
let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)

print("family=\(CTFontCopyFamilyName(font) as String)")
print("postscript=\(CTFontCopyPostScriptName(font) as String)")
if let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL {
    print("file=\(url.path)")
} else {
    print("file=unknown")
}

// Map U+1F600 (😀) to a glyph in the resolved font.
let scalar: UnicodeScalar = UnicodeScalar(0x1F600)!
var utf16 = Array(String(scalar).utf16)
var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
let found = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
print("glyphFound=\(found && glyphs[0] != 0)")

// Render via CTLine — this is the path real apps use, and it composites every
// color format (sbix bitmaps AND COLR/CPAL/COLRv1 layers). CTFontDrawGlyphs
// alone draws only base outlines and misses COLR layers entirely.
let w = Int(size), h = Int(size)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("coloredPixels=0"); exit(0)
}
ctx.setAllowsAntialiasing(true)
let attr = CFAttributedStringCreate(nil, String(scalar) as CFString,
            [kCTFontAttributeName: font] as CFDictionary)!
let line = CTLineCreateWithAttributedString(attr)
ctx.textPosition = CGPoint(x: 8, y: 28)
CTLineDraw(line, ctx)

var colored = 0, opaque = 0
if let data = ctx.data {
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in stride(from: 0, to: w * h * 4, by: 4) {
        let r = px[i], gg = px[i+1], b = px[i+2], a = px[i+3]
        if a > 16 {
            opaque += 1
            let mx = max(r, max(gg, b)), mn = min(r, min(gg, b))
            if Int(mx) - Int(mn) > 24 { colored += 1 }   // chromatic, not greyscale
        }
    }
}
print("opaquePixels=\(opaque)")
print("coloredPixels=\(colored)")

if CommandLine.arguments.count > 1, let img = ctx.makeImage() {
    let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
    if let dst = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }
}
