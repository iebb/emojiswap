// artsize.swift — measure how big a font's emoji art is, in ems, by rendering a
// reference glyph and finding its opaque bounding box. Prints `artEm=<n>` where
// 1.0 means the art fills one em (Apple Color Emoji's design). Used to rescale
// third-party emoji to Apple's size.
import CoreText
import CoreGraphics
import Foundation

let path = CommandLine.arguments[1]
let member = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 0
guard let descs = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor] else {
    print("artEm=0"); exit(1)
}
let pt: CGFloat = 100
let font = CTFontCreateWithFontDescriptor(descs[member], pt, nil)

func opaqueMax(_ scalar: UInt32) -> CGFloat {
    let W = 400, H = 400
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
    let s = String(UnicodeScalar(scalar)!)
    let attr = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: font] as CFDictionary)!
    ctx.textPosition = CGPoint(x: 150, y: 200)
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
    var minX = W, minY = H, maxX = -1, maxY = -1
    for y in 0..<H { for x in 0..<W where px[(y * W + x) * 4 + 3] > 20 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    if maxX < 0 { return 0 }
    return max(CGFloat(maxX - minX + 1), CGFloat(maxY - minY + 1))
}

// reference glyphs that tend to fill the cell; take the median to be robust
let samples: [UInt32] = [0x1F600, 0x1F601, 0x1F642, 0x1F60A]
let sizes = samples.map { opaqueMax($0) }.filter { $0 > 0 }.sorted()
let med = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
print("artEm=\(Double(med) / Double(pt))")
