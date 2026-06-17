// blendrender.swift — for the bitmap (sbix) blend.
// Reads a jobs file (one line per emoji: "<emoji>\t<sourceFontPath>"), and for
// each emoji: (1) shapes it through the BASE font to find its glyph id, and
// (2) renders it from its SOURCE font into a uniform, baseline-aligned cell PNG.
// Writes <outDir>/g<gid>.png so the Python side can drop each PNG into the base
// font's sbix table at that glyph.
//
// usage: blendrender <baseFont> <jobsFile> <outDir>
import CoreText
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let baseFontPath = CommandLine.arguments[1]
let jobsPath = CommandLine.arguments[2]
let outDir = CommandLine.arguments[3]

let baseDescs = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: baseFontPath) as CFURL) as! [CTFontDescriptor]
let baseFont = CTFontCreateWithFontDescriptor(baseDescs[0], 128, nil)
let basePS = CTFontCopyPostScriptName(baseFont) as String

var fontCache: [String: CTFont] = [:]
func sourceFont(_ path: String) -> CTFont? {
    if let f = fontCache[path] { return f }
    guard let d = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor],
          let d0 = d.first else { return nil }
    let f = CTFontCreateWithFontDescriptor(d0, 160, nil)
    fontCache[path] = f
    return f
}

// glyph id this emoji resolves to in the base font (single combined glyph), or nil
func baseGlyph(_ s: String) -> Int? {
    let attr = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: baseFont] as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else { return nil }
    let run = runs[0]
    if CTRunGetGlyphCount(run) != 1 { return nil }
    let a = CTRunGetAttributes(run) as NSDictionary
    if let f = a[kCTFontAttributeName as String] {
        if (CTFontCopyPostScriptName(f as! CTFont) as String) != basePS { return nil }  // substituted → base lacks it
    }
    var g: CGGlyph = 0
    CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &g)
    return g == 0 ? nil : Int(g)
}

// render emoji from a source font into a uniform CELL px PNG, art scaled to fill
// ~TARGET, centered horizontally, bottom on the baseline (origin row).
let CELL = 160, TARGET = 150.0
func renderCell(_ s: String, _ font: CTFont) -> Data? {
    let big = 360
    guard let m = CGContext(data: nil, width: big, height: big, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    m.clear(CGRect(x: 0, y: 0, width: big, height: big))
    let attr = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: font] as CFDictionary)!
    m.textPosition = CGPoint(x: 100, y: 140)
    CTLineDraw(CTLineCreateWithAttributedString(attr), m)
    guard let img = m.makeImage() else { return nil }
    // opaque bbox
    let stride = m.bytesPerRow, px = m.data!.bindMemory(to: UInt8.self, capacity: stride * big)
    var minX = big, minY = big, maxX = -1, maxY = -1
    for r in 0..<big { for c in 0..<big where px[r*stride + c*4 + 3] > 16 {
        if c < minX { minX = c }; if c > maxX { maxX = c }; if r < minY { minY = r }; if r > maxY { maxY = r }
    } }
    if maxX < 0 { return nil }
    let bw = maxX - minX + 1, bh = maxY - minY + 1
    let scale = TARGET / Double(max(bw, bh))
    let dw = Double(bw) * scale, dh = Double(bh) * scale
    guard let cropped = img.cropping(to: CGRect(x: minX, y: minY, width: bw, height: bh)) else { return nil }
    // paste into cell: centered x, bottom margin small (sit near baseline)
    guard let cell = CGContext(data: nil, width: CELL, height: CELL, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    cell.clear(CGRect(x: 0, y: 0, width: CELL, height: CELL))
    let x = (Double(CELL) - dw) / 2     // centered horizontally
    let y = Double(CELL) * 0.05         // small bottom margin → sits ~on the baseline
    cell.draw(cropped, in: CGRect(x: x, y: y, width: dw, height: dh))
    guard let out = cell.makeImage() else { return nil }
    let data = NSMutableData()
    let dst = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, out, nil); CGImageDestinationFinalize(dst)
    return data as Data
}

var done = 0, skipped = 0
for raw in (try! String(contentsOfFile: jobsPath, encoding: .utf8)).split(separator: "\n") {
    let parts = raw.split(separator: "\t", maxSplits: 1)
    if parts.count != 2 { continue }
    let emoji = String(parts[0]), srcPath = String(parts[1])
    guard let gid = baseGlyph(emoji), let sf = sourceFont(srcPath), let png = renderCell(emoji, sf) else { skipped += 1; continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/g\(gid).png"))
    done += 1
}
print("rendered=\(done) skipped=\(skipped)")
