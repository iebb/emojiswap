// Build-time tool: pre-renders the default-preview glyphs (one per category) for
// every emoji set into PNGs that ship in the app bundle. The app then shows the
// default preview with NO font download — only custom text outside these glyphs is
// fetched on demand. Usage: swift genpreviews.swift <output-dir>
import AppKit
import CoreText

// Repo root for source fonts: arg[2] (passed by build.sh), else the current dir.
let PROJECT = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : FileManager.default.currentDirectoryPath
let DEFAULT = "😀👋🐖🍕🚗⚽💡\u{2764}🇸🇲"   // must match DEFAULT_PREVIEW in EmojiSwapUI.swift (bare U+2764 heart)
let PX = 180

// (setId, font path) — mirrors SETS; Apple uses its backup, the rest the download cache.
let SETS: [(String, String)] = [
    ("apple", "\(PROJECT)/system-font/backup/Apple Color Emoji.ttc.orig"),
    ("noto", "\(PROJECT)/fonts/noto.ttf"),
    ("noto-mono", "\(PROJECT)/fonts/noto-mono.ttf"),
    ("twemoji", "\(PROJECT)/fonts/twemoji.ttf"),
    ("openmoji", "\(PROJECT)/fonts/openmoji.ttf"),
    ("emojitwo", "\(PROJECT)/fonts/emojitwo.ttf"),
    ("blobmoji", "\(PROJECT)/fonts/blobmoji.ttf"),
    ("tossface", "\(PROJECT)/fonts/tossface.ttf"),
    ("fluent", "\(PROJECT)/fonts/fluent.ttf"),
    ("fluent-flat", "\(PROJECT)/fonts/fluent-flat.ttf"),
    ("fluent-mono", "\(PROJECT)/fonts/fluent-mono.ttf"),
]

func glyphKey(_ g: String) -> String {
    g.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
}

// True iff `line` renders entirely with `font`'s own glyphs (no Core Text fallback) — so we
// don't bundle, say, an Apple flag for a set (Fluent) that has none.
func lineUsesOnly(_ font: CTFont, _ line: CTLine) -> Bool {
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
    let want = CTFontCopyPostScriptName(font) as String
    for run in runs {
        guard let used = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { return false }
        if (CTFontCopyPostScriptName(used as! CTFont) as String) != want { return false }
    }
    return true
}

// Center `line` in `ctx` by its OPAQUE pixels (not CTLineGetImageBounds, which counts a
// bitmap font's transparent padding) — keeps every set's art vertically centered. Mirrors
// drawCenteredGlyph in EmojiSwapUI.swift so bundled glyphs match the live render.
func drawCenteredGlyph(_ ctx: CGContext, _ line: CTLine, _ x0: CGFloat, _ cs: CGFloat) {
    let n = Int(cs)
    guard n > 0, let sc = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    sc.interpolationQuality = .high
    sc.textPosition = .zero
    let ib = CTLineGetImageBounds(line, sc)
    guard ib.width > 1, ib.height > 1 else {
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let lw = CTLineGetTypographicBounds(line, &asc, &desc, &lead)
        ctx.textPosition = CGPoint(x: x0 + (cs - CGFloat(lw)) / 2, y: (cs - (asc + desc)) / 2 + desc)
        CTLineDraw(line, ctx); return
    }
    let scale = min(1, cs * 0.96 / max(ib.width, ib.height))
    sc.translateBy(x: cs / 2, y: cs / 2); sc.scaleBy(x: scale, y: scale)
    sc.textPosition = CGPoint(x: -ib.midX, y: -ib.midY)
    CTLineDraw(line, sc)
    guard let dp = sc.data else { return }
    let px = dp.bindMemory(to: UInt8.self, capacity: n * n * 4)
    var minX = n, minY = n, maxX = -1, maxY = -1
    for y in 0..<n { for x in 0..<n where px[(y * n + x) * 4 + 3] > 16 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    } }
    guard maxX >= 0 else { return }
    let bcx = CGFloat(minX + maxX) / 2, bcy = CGFloat(minY + maxY) / 2
    ctx.saveGState()
    ctx.translateBy(x: x0 + cs - bcx, y: bcy); ctx.scaleBy(x: scale, y: scale)
    ctx.textPosition = CGPoint(x: -ib.midX, y: -ib.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./preview"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

var made = 0, skipped = 0, absent = 0
for (id, fontPath) in SETS {
    guard FileManager.default.fileExists(atPath: fontPath),
          let descs = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL) as? [CTFontDescriptor],
          let d = descs.first else { skipped += 1; continue }
    let font = CTFontCreateWithFontDescriptor(d, CGFloat(Double(PX) * 0.82), nil)   // uniform size
    let P = CGFloat(PX)
    for ch in DEFAULT.map({ String($0) }) {
        guard let ctx = CGContext(data: nil, width: PX, height: PX, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        let attr = CFAttributedStringCreate(nil, ch as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        if !lineUsesOnly(font, line) { absent += 1; continue }   // set lacks it → don't bundle a fallback glyph
        drawCenteredGlyph(ctx, line, 0, P)              // center by opaque pixels (matches the app)
        guard let cg = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
        try? data.write(to: URL(fileURLWithPath: "\(out)/\(id)__\(glyphKey(ch)).png"))
        made += 1
    }
}
print("genpreviews: wrote \(made) glyphs, \(absent) absent (set lacks them), skipped \(skipped) missing fonts → \(out)")
