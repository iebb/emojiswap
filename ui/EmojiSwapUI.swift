// EmojiSwapUI — a small SwiftUI front-end for emojiswap.
//
// It drives the already-tested CLI/scripts:
//   • System-wide route (SIP off): builds the drop-in .ttc, then runs
//     system-font/install.sh via `osascript ... with administrator privileges`,
//     so macOS shows its own password dialog — the app never sees the password.
//   • App-level route (user font): runs `emojiswap set/revert` (no admin needed).
//
// Build:  ./ui/build.sh   then open ui/EmojiSwap.app
import SwiftUI
import AppKit
import CoreText

// Absolute path to the emojiswap project (this is a personal tool for one machine).
// Repo root: $EMOJISWAP_DIR if set, else two levels up from the .app bundle — it
// ships at <repo>/ui/EmojiSwap.app, so the binary finds the CLI, fonts cache and
// system-font scripts in any clone. (Falls back to CWD for a raw, un-bundled run.)
let PROJECT_DIR: String = {
    if let env = ProcessInfo.processInfo.environment["EMOJISWAP_DIR"], !env.isEmpty { return env }
    let bundle = Bundle.main.bundlePath
    if bundle.hasSuffix(".app") {
        return ((bundle as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }
    return FileManager.default.currentDirectoryPath
}()

// ---- emoji sets -------------------------------------------------------------
struct EmojiSet: Identifiable {
    let id: String          // emojiswap set key
    let name: String
    let note: String
    let previewFont: String // path to a renderable build, for the live preview
}

// Standalone, no Python: everything downloads to a user cache; backups + the
// bundled installer scripts live in the app's own directories. Nothing needs the
// repo (except blend, which still wants the dev CLI — see applyBlend).
let RELEASE_BASE = "https://github.com/iebb/emojifonts/releases/download/latest"
let SYSTEM_EMOJI = "/System/Library/Fonts/Apple Color Emoji.ttc"
@discardableResult func mkdirp(_ p: String) -> String {
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); return p
}
let CACHE = mkdirp("\(NSHomeDirectory())/Library/Caches/EmojiSwap")
let APP_SUPPORT = mkdirp("\(NSHomeDirectory())/Library/Application Support/EmojiSwap")
let APPLE_BACKUP = "\(APP_SUPPORT)/Apple Color Emoji.ttc.orig"   // where the installer backs up
let USER_FONTS = "\(NSHomeDirectory())/Library/Fonts"

func fontCache(_ key: String) -> String { "\(CACHE)/\(key).ttf" }
func userFontPath(_ key: String) -> String { "\(USER_FONTS)/EmojiSwap-\(key).ttf" }
func appleFontPath() -> String { FileManager.default.fileExists(atPath: APPLE_BACKUP) ? APPLE_BACKUP : SYSTEM_EMOJI }

// Resolve a bundled helper script (install.sh / restore.sh), else fall back to the repo.
func bundledScript(_ name: String) -> String {
    if let res = Bundle.main.resourcePath {
        let p = "\(res)/scripts/\(name)"
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return "\(PROJECT_DIR)/system-font/\(name)"
}

// Fetch a set's font from the emojifonts release into the cache — native curl,
// no Python. No-op if already cached.
@discardableResult
func ensureFont(_ key: String) -> Bool {
    let dst = fontCache(key)
    if FileManager.default.fileExists(atPath: dst) { return true }
    _ = run("/usr/bin/curl", ["-fL", "--retry", "2", "-m", "120", "--create-dirs",
                              "-o", dst, "\(RELEASE_BASE)/\(key).ttf"])
    return FileManager.default.fileExists(atPath: dst)
}

// Install a set as an ordinary user font under its own name (native; no SIP/admin).
@discardableResult
func installAsFont(_ key: String) -> Bool {
    guard ensureFont(key) else { return false }
    _ = mkdirp(USER_FONTS)
    let dst = userFontPath(key)
    try? FileManager.default.removeItem(atPath: dst)
    do { try FileManager.default.copyItem(atPath: fontCache(key), toPath: dst) } catch { return false }
    _ = run("/usr/bin/killall", ["fontd"])
    return true
}

// Remove every EmojiSwap-installed user font.
func uninstallUserFonts() {
    if let files = try? FileManager.default.contentsOfDirectory(atPath: USER_FONTS) {
        for f in files where f.hasPrefix("EmojiSwap-") && f.hasSuffix(".ttf") {
            try? FileManager.default.removeItem(atPath: "\(USER_FONTS)/\(f)")
        }
    }
    _ = run("/usr/bin/killall", ["fontd"])
}

// One per emojifonts release font (+ Apple). Names/notes are fallbacks — the live
// manifest overrides notes with each font's license + Emoji version.
let SETS: [EmojiSet] = [
    EmojiSet(id: "apple",     name: "Apple (original)", note: "macOS default", previewFont: appleFontPath()),
    EmojiSet(id: "noto",      name: "Google Noto",          note: "Apache-2.0 / OFL", previewFont: fontCache("noto")),
    EmojiSet(id: "twemoji",   name: "Twemoji",              note: "jdecked · CC BY 4.0", previewFont: fontCache("twemoji")),
    EmojiSet(id: "openmoji",  name: "OpenMoji",             note: "CC BY-SA 4.0",     previewFont: fontCache("openmoji")),
    EmojiSet(id: "emojitwo",  name: "EmojiTwo",             note: "CC BY 4.0",        previewFont: fontCache("emojitwo")),
    EmojiSet(id: "blobmoji",  name: "Blobmoji",             note: "OFL 1.1",          previewFont: fontCache("blobmoji")),
    EmojiSet(id: "tossface",  name: "Toss Face",            note: "free",             previewFont: fontCache("tossface")),
    EmojiSet(id: "fluent",            name: "Fluent 3D",     note: "MIT", previewFont: fontCache("fluent")),
    EmojiSet(id: "fluent-flat",       name: "Fluent Flat",   note: "MIT", previewFont: fontCache("fluent-flat")),
    EmojiSet(id: "noto-mono",         name: "Noto (mono)",   note: "OFL-1.1", previewFont: fontCache("noto-mono")),
    EmojiSet(id: "fluent-mono",       name: "Fluent Mono",   note: "MIT", previewFont: fontCache("fluent-mono")),
]

// Default preview: one emoji per category (flag = San Marino 🇸🇲). These exact
// glyphs are pre-rendered per set and bundled with the app, so the default preview
// needs no font download — only custom text outside this set is fetched on demand.
// One emoji per category; heart is bare U+2764 (no FE0F) so sets that map only the
// unqualified heart — e.g. Microsoft Fluent — render their OWN heart instead of falling
// back to Apple's. The flag stays as-is; sets without flags (Fluent) leave it blank.
let DEFAULT_PREVIEW = "😀👋🐖🍕🚗⚽💡\u{2764}🇸🇲"
let PREVIEW_MAX = 9
let PREVIEW_CELL = 36     // render cell width (the image is scaled to fit PREVIEW_ROW_W)
let PREVIEW_ROW_W: CGFloat = 306   // on-screen preview width; each emoji occupies 1/9 of it

// Blend-by-category keys (labels localized via L("cat_<key>")).
let BLEND_CATS = ["smileys", "people", "animals", "food", "travel", "activities", "objects", "symbols", "flags"]
// Any set can be a blend source — including Apple (its own emoji, the default).
let BLEND_SETS: [EmojiSet] = SETS

// 3 representative emoji per category, shown as a live preview in each blend row
// and in its source dropdown. "_default" is the catch-all row.
let BLEND_SAMPLES: [String: String] = [
    "_default": "😀🐶🍕",
    "smileys": "😀😂🥰", "people": "👋💪🙏", "animals": "🐖🐢🐱",
    "food": "🍕🍔🍎", "travel": "🚗✈️🏠", "activities": "⚽🎉🎮",
    "objects": "💡📱🔑", "symbols": "❤️✅⚠️", "flags": "🏁🇰🇷🎌",
]

// ---- localization -----------------------------------------------------------
let LANG_NAMES: [(code: String, name: String)] = [
    ("en", "English"), ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어"),
    ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
]
let LANGS: [String: [String: String]] = [
    "en": [
        "subtitle": "Swap macOS emoji for Noto, Twemoji, OpenMoji & more",
        "off": "off", "on": "on", "system": "System-wide", "user": "Apps only",
        "desc_system": "Replaces the sealed system font (reboot required) — changes every app.",
        "desc_user": "Installs to ~/Library/Fonts. ⚠︎ On macOS 26 this only affects apps that request the font by name.",
        "emoji_set": "Emoji set", "single": "Single set", "blend": "Blend by category",
        "apply_system": "Apply system-wide", "apply_user": "Apply to apps",
        "revert": "Revert to Apple", "no_backup": "No Apple backup found", "log": "Log",
        "default_row": "Default (everything else)", "default_opt": "— default —",
        "downloading": "downloading…", "preview_ph": "preview",
        "blend_note": "Each category is rendered from its set into one uniform sbix font.",
        "cat_smileys": "Smileys & Emotion", "cat_people": "People & Body", "cat_animals": "Animals & Nature",
        "cat_food": "Food & Drink", "cat_travel": "Travel & Places", "cat_activities": "Activities",
        "cat_objects": "Objects", "cat_symbols": "Symbols", "cat_flags": "Flags",
    ],
    "zh": [
        "subtitle": "将 macOS 表情替换为 Noto、Twemoji、OpenMoji 等",
        "off": "关", "on": "开", "system": "全系统", "user": "仅应用",
        "desc_system": "替换系统字体（需重启）——影响所有应用。",
        "desc_user": "安装到 ~/Library/Fonts。⚠︎ 在 macOS 26 上仅影响按名称请求该字体的应用。",
        "emoji_set": "表情集", "single": "单一集", "blend": "按类别混合",
        "apply_system": "全系统应用", "apply_user": "应用到 App",
        "revert": "还原为 Apple", "no_backup": "未找到 Apple 备份", "log": "日志",
        "default_row": "默认（其余全部）", "default_opt": "— 默认 —",
        "downloading": "下载中…", "preview_ph": "预览",
        "blend_note": "每个类别用所选集渲染，合成为一个统一的 sbix 字体。",
        "cat_smileys": "笑脸与情感", "cat_people": "人物与身体", "cat_animals": "动物与自然",
        "cat_food": "食物与饮料", "cat_travel": "旅行与地点", "cat_activities": "活动",
        "cat_objects": "物品", "cat_symbols": "符号", "cat_flags": "旗帜",
    ],
    "ja": [
        "subtitle": "macOSの絵文字をNoto・Twemoji・OpenMojiなどに置き換え",
        "off": "オフ", "on": "オン", "system": "システム全体", "user": "アプリのみ",
        "desc_system": "システムフォントを置き換え（再起動が必要）— すべてのアプリに反映。",
        "desc_user": "~/Library/Fonts にインストール。⚠︎ macOS 26 では名前で指定するアプリのみに反映。",
        "emoji_set": "絵文字セット", "single": "単一セット", "blend": "カテゴリ別に混合",
        "apply_system": "システム全体に適用", "apply_user": "アプリに適用",
        "revert": "Appleに戻す", "no_backup": "Appleのバックアップがありません", "log": "ログ",
        "default_row": "デフォルト（その他すべて）", "default_opt": "— デフォルト —",
        "downloading": "ダウンロード中…", "preview_ph": "プレビュー",
        "blend_note": "各カテゴリを選択したセットで描画し、1つのsbixフォントに統合します。",
        "cat_smileys": "スマイリーと感情", "cat_people": "人と体", "cat_animals": "動物と自然",
        "cat_food": "食べ物と飲み物", "cat_travel": "旅行と場所", "cat_activities": "アクティビティ",
        "cat_objects": "物", "cat_symbols": "記号", "cat_flags": "旗",
    ],
    "ko": [
        "subtitle": "macOS 이모지를 Noto, Twemoji, OpenMoji 등으로 교체",
        "off": "꺼짐", "on": "켜짐", "system": "시스템 전체", "user": "앱만",
        "desc_system": "시스템 글꼴 교체(재부팅 필요) — 모든 앱에 적용.",
        "desc_user": "~/Library/Fonts에 설치. ⚠︎ macOS 26에서는 글꼴을 이름으로 요청하는 앱에만 적용.",
        "emoji_set": "이모지 세트", "single": "단일 세트", "blend": "카테고리별 혼합",
        "apply_system": "시스템 전체 적용", "apply_user": "앱에 적용",
        "revert": "Apple로 복원", "no_backup": "Apple 백업 없음", "log": "로그",
        "default_row": "기본 (나머지 전체)", "default_opt": "— 기본 —",
        "downloading": "다운로드 중…", "preview_ph": "미리보기",
        "blend_note": "각 카테고리를 선택한 세트로 렌더링해 하나의 sbix 글꼴로 합칩니다.",
        "cat_smileys": "스마일리 및 감정", "cat_people": "사람과 신체", "cat_animals": "동물과 자연",
        "cat_food": "음식과 음료", "cat_travel": "여행과 장소", "cat_activities": "활동",
        "cat_objects": "사물", "cat_symbols": "기호", "cat_flags": "깃발",
    ],
    "es": [
        "subtitle": "Cambia los emoji de macOS por Noto, Twemoji, OpenMoji y más",
        "off": "off", "on": "on", "system": "Todo el sistema", "user": "Solo apps",
        "desc_system": "Reemplaza la fuente del sistema (requiere reinicio) — afecta a todas las apps.",
        "desc_user": "Se instala en ~/Library/Fonts. ⚠︎ En macOS 26 solo afecta a apps que piden la fuente por nombre.",
        "emoji_set": "Conjunto de emoji", "single": "Un conjunto", "blend": "Mezclar por categoría",
        "apply_system": "Aplicar a todo el sistema", "apply_user": "Aplicar a las apps",
        "revert": "Restaurar Apple", "no_backup": "Sin copia de Apple", "log": "Registro",
        "default_row": "Predeterminado (todo lo demás)", "default_opt": "— predeterminado —",
        "downloading": "descargando…", "preview_ph": "vista previa",
        "blend_note": "Cada categoría se renderiza con su conjunto en una sola fuente sbix.",
        "cat_smileys": "Caras y emociones", "cat_people": "Personas y cuerpo", "cat_animals": "Animales y naturaleza",
        "cat_food": "Comida y bebida", "cat_travel": "Viajes y lugares", "cat_activities": "Actividades",
        "cat_objects": "Objetos", "cat_symbols": "Símbolos", "cat_flags": "Banderas",
    ],
    "fr": [
        "subtitle": "Remplacez les emoji de macOS par Noto, Twemoji, OpenMoji et plus",
        "off": "off", "on": "on", "system": "Tout le système", "user": "Apps seulement",
        "desc_system": "Remplace la police système (redémarrage requis) — affecte toutes les apps.",
        "desc_user": "Installé dans ~/Library/Fonts. ⚠︎ Sur macOS 26, n'affecte que les apps qui demandent la police par nom.",
        "emoji_set": "Jeu d'emoji", "single": "Un seul jeu", "blend": "Mélanger par catégorie",
        "apply_system": "Appliquer au système", "apply_user": "Appliquer aux apps",
        "revert": "Revenir à Apple", "no_backup": "Aucune sauvegarde Apple", "log": "Journal",
        "default_row": "Par défaut (tout le reste)", "default_opt": "— défaut —",
        "downloading": "téléchargement…", "preview_ph": "aperçu",
        "blend_note": "Chaque catégorie est rendue avec son jeu dans une seule police sbix.",
        "cat_smileys": "Émoticônes et émotions", "cat_people": "Personnes et corps", "cat_animals": "Animaux et nature",
        "cat_food": "Nourriture et boissons", "cat_travel": "Voyages et lieux", "cat_activities": "Activités",
        "cat_objects": "Objets", "cat_symbols": "Symboles", "cat_flags": "Drapeaux",
    ],
    "de": [
        "subtitle": "macOS-Emojis durch Noto, Twemoji, OpenMoji u. a. ersetzen",
        "off": "aus", "on": "an", "system": "Systemweit", "user": "Nur Apps",
        "desc_system": "Ersetzt die System-Schrift (Neustart nötig) — betrifft alle Apps.",
        "desc_user": "Installiert in ~/Library/Fonts. ⚠︎ Unter macOS 26 nur für Apps, die die Schrift per Name anfordern.",
        "emoji_set": "Emoji-Satz", "single": "Ein Satz", "blend": "Nach Kategorie mischen",
        "apply_system": "Systemweit anwenden", "apply_user": "Auf Apps anwenden",
        "revert": "Zu Apple zurück", "no_backup": "Kein Apple-Backup", "log": "Protokoll",
        "default_row": "Standard (alles andere)", "default_opt": "— Standard —",
        "downloading": "lädt…", "preview_ph": "Vorschau",
        "blend_note": "Jede Kategorie wird mit ihrem Satz in eine einzige sbix-Schrift gerendert.",
        "cat_smileys": "Smileys & Emotionen", "cat_people": "Menschen & Körper", "cat_animals": "Tiere & Natur",
        "cat_food": "Essen & Trinken", "cat_travel": "Reisen & Orte", "cat_activities": "Aktivitäten",
        "cat_objects": "Objekte", "cat_symbols": "Symbole", "cat_flags": "Flaggen",
    ],
]
func defaultLang() -> String {
    let code = String((Locale.preferredLanguages.first ?? "en").prefix(2))
    return LANGS[code] != nil ? code : "en"
}
func appleBackupExists() -> Bool { FileManager.default.fileExists(atPath: APPLE_BACKUP) }

// ---- shell helpers ----------------------------------------------------------
@discardableResult
func run(_ launch: String, _ args: [String], cwd: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "failed to launch \(launch): \(error)\n") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// Run a shell command with admin rights via the native macOS auth dialog.
func runAdmin(_ shellCommand: String) -> (code: Int32, out: String) {
    let esc = shellCommand
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(esc)\" with administrator privileges"
    return run("/usr/bin/osascript", ["-e", script])
}

func sipDisabled() -> Bool {
    run("/usr/bin/csrutil", ["status"]).out.lowercased().contains("disabled")
}

// True iff `line` is rendered entirely with `font`'s own glyphs (no Core Text fallback to
// another font). Lets the preview show only what a set actually contains — e.g. Fluent has
// no national flags, so its flag cell stays blank instead of silently borrowing Apple's.
func lineUsesOnly(_ font: CTFont, _ line: CTLine) -> Bool {
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
    let want = CTFontCopyPostScriptName(font) as String
    for run in runs {
        guard let used = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { return false }
        if (CTFontCopyPostScriptName(used as! CTFont) as String) != want { return false }
    }
    return true
}

// Draw `line` into column x0 of `ctx`, centered by its OPAQUE pixels rather than
// CTLineGetImageBounds — which, for a bitmap (sbix) font, returns the full bitmap rect
// including transparent padding, so a set whose art sits low in a padded cell (OpenMoji)
// ends up off-centre. Render once to a scratch buffer to find the real ink, then center that.
func drawCenteredGlyph(_ ctx: CGContext, _ line: CTLine, _ x0: CGFloat, _ cs: CGFloat) {
    let n = Int(cs)
    guard n > 0, let sc = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    sc.interpolationQuality = .high
    sc.textPosition = .zero
    let ib = CTLineGetImageBounds(line, sc)
    guard ib.width > 1, ib.height > 1 else {                 // no measurable ink → em-center
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let lw = CTLineGetTypographicBounds(line, &asc, &desc, &lead)
        ctx.textPosition = CGPoint(x: x0 + (cs - CGFloat(lw)) / 2, y: (cs - (asc + desc)) / 2 + desc)
        CTLineDraw(line, ctx); return
    }
    let scale = min(1, cs * 0.96 / max(ib.width, ib.height)) // shrink only if it would overflow
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
    let bcx = CGFloat(minX + maxX) / 2, bcy = CGFloat(minY + maxY) / 2  // opaque centre (buffer coords)
    ctx.saveGState()
    ctx.translateBy(x: x0 + cs - bcx, y: bcy); ctx.scaleBy(x: scale, y: scale)
    ctx.textPosition = CGPoint(x: -ib.midX, y: -ib.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// codepoint-hex key for a grapheme, e.g. "2764_fe0f" — matches the bundled file name.
func glyphKey(_ grapheme: String) -> String {
    grapheme.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
}

// A pre-rendered default-preview glyph for (set, grapheme) shipped in the app bundle.
func bundledGlyph(_ setId: String, _ grapheme: String) -> CGImage? {
    guard let dir = Bundle.main.resourcePath else { return nil }
    let path = "\(dir)/preview/\(setId)__\(glyphKey(grapheme)).png"
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

// Render `text` for a set, one grapheme per fixed-width cell (tabular, so the same
// character lines up across every set). Each cell uses, in order: the downloaded
// font (best), else a bundled pre-rendered glyph, else a loading placeholder — and
// reports whether any cell still needs the font downloaded.
func previewRow(setId: String, fontPath: String, text: String,
                maxWidth: Int = 320, maxCell: Int = PREVIEW_CELL) -> (img: NSImage?, needsDownload: Bool) {
    let cells = Array(text.map { String($0) }.prefix(PREVIEW_MAX))   // grapheme clusters, capped
    guard !cells.isEmpty else { return (nil, false) }
    let cell = min(maxCell, max(16, maxWidth / cells.count))
    let s = 3                                     // render at 3× device pixels → sharp on Retina
    let w = cells.count * cell, h = cell
    let cs = CGFloat(cell * s)
    guard let ctx = CGContext(data: nil, width: w * s, height: h * s, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return (nil, false) }
    ctx.interpolationQuality = .high
    // a downloaded font renders every cell at full quality
    var ctFont: CTFont?
    if FileManager.default.fileExists(atPath: fontPath),
       let descs = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL) as? [CTFontDescriptor],
       let d = descs.first {
        ctFont = CTFontCreateWithFontDescriptor(d, cs * 0.82, nil)   // uniform size for every glyph
    }
    var needsDownload = false
    for (i, ch) in cells.enumerated() {
        let x0 = CGFloat(i) * cs
        if let font = ctFont {
            let attr = CFAttributedStringCreate(nil, ch as CFString,
                                                [kCTFontAttributeName: font] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            // Only draw cells this font renders ITSELF; if Core Text fell back to another
            // font (e.g. Fluent lacks national flags), leave the cell blank rather than
            // borrow Apple's glyph — the preview then honestly shows what the set has.
            if lineUsesOnly(font, line) {
                drawCenteredGlyph(ctx, line, x0, cs)        // center by opaque pixels
            }
            // else: font is present but lacks this glyph → blank cell (no fallback)
        } else if let cg = bundledGlyph(setId, ch) {
            ctx.draw(cg, in: CGRect(x: x0, y: 0, width: cs, height: cs))   // bundled glyph already em-centered
        } else {
            needsDownload = true                       // loading placeholder
            let pad = cs * 0.22
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.18))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x0 + pad, y: pad, width: cs - 2*pad, height: cs - 2*pad),
                               cornerWidth: cs * 0.08, cornerHeight: cs * 0.08, transform: nil))
            ctx.fillPath()
        }
    }
    guard let cg = ctx.makeImage() else { return (nil, needsDownload) }
    return (NSImage(cgImage: cg, size: NSSize(width: w, height: h)), needsDownload)
}

// ---- views ------------------------------------------------------------------
enum Mode: String, CaseIterable { case system = "System-wide", user = "Apps only (user font)" }

struct ContentView: View {
    @State private var sipOff = sipDisabled()
    @State private var selected = "noto"
    @State private var mode: Mode = sipDisabled() ? .system : .user
    @State private var busy = false
    @State private var log = "Ready.\n"
    @State private var previews: [String: NSImage] = [:]
    @State private var previewText = DEFAULT_PREVIEW
    @State private var currentLang = defaultLang()
    // blend-by-category state
    @State private var blendMode = false
    @State private var blendDefault = appleBackupExists() ? "apple" : "noto"
    @State private var blendCats: [String: String] = [:]   // category → set id ("" = use default)
    @State private var blendPreviews: [String: NSImage] = [:]   // "sampleKey|setId" → image
    @State private var openPopover: String?                // which row's source dropdown is open
    @State private var hovered: String?
    // emojifonts manifest (live metadata: emoji version + license per set)
    @State private var manifest: [String: (version: String, license: String)] = [:]

    private func L(_ key: String) -> String {
        LANGS[currentLang]?[key] ?? LANGS["en"]?[key] ?? key
    }
    private var hasBackup: Bool { appleBackupExists() }
    // Apple needs its backup to render/revert; hide it everywhere when there's none.
    private var visibleSets: [EmojiSet] { hasBackup ? SETS : SETS.filter { $0.id != "apple" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            methodSection
            setSection
            footer
            logSection
        }
        .padding(18)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadPreviews(); loadManifest() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "face.smiling")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("EmojiSwap").font(.system(size: 20, weight: .bold))
                Text(L("subtitle")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) { langMenu; sipBadge }
        }
    }

    private var langMenu: some View {
        Menu {
            ForEach(LANG_NAMES, id: \.code) { item in
                Button { currentLang = item.code } label: {
                    if item.code == currentLang { Label(item.name, systemImage: "checkmark") }
                    else { Text(item.name) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe").font(.caption2)
                Text(LANG_NAMES.first { $0.code == currentLang }?.name ?? "English").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var sipBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: sipOff ? "lock.open.fill" : "lock.fill").font(.system(size: 10))
            Text("SIP " + (sipOff ? L("off") : L("on"))).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(sipOff ? Color.green : Color.orange)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((sipOff ? Color.green : Color.orange).opacity(0.16)))
        .help(sipOff ? L("system") : L("user"))
    }

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mode) {
                Text(L("system")).tag(Mode.system)
                Text(L("user")).tag(Mode.user)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(busy)
            .onChange(of: mode) { _, new in if new == .system && !sipOff { mode = .user } }
            Text(mode == .system ? L("desc_system") : L("desc_user"))
                .font(.caption).foregroundStyle(mode == .system ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("emoji_set")).font(.headline)
                Spacer()
                Image(systemName: "textformat.abc").foregroundStyle(.secondary).font(.caption)
                TextField(L("preview_ph"), text: $previewText)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .onChange(of: previewText) { _, _ in loadPreviews() }
            }
            Picker("", selection: $blendMode) {
                Text(L("single")).tag(false)
                Text(L("blend")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(busy)

            ScrollView {
                if blendMode {
                    blendConfig
                } else {
                    VStack(spacing: 5) { ForEach(visibleSets) { setRow($0) } }
                }
            }
            .frame(height: 298)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: apply) {
                Label(mode == .system ? L("apply_system") : L("apply_user"), systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || (mode == .system && !sipOff))
            Button(action: revert) { Text(L("revert")) }
                .controlSize(.large).disabled(busy || !hasBackup)
                .help(hasBackup ? "" : L("no_backup"))
            if busy { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption2)
                Text(L("log")).font(.caption.weight(.semibold))
            }.foregroundStyle(.secondary)
            ScrollView {
                Text(log).font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).padding(7)
            }
            .frame(height: 84)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private func setRow(_ set: EmojiSet) -> some View {
        let sel = selected == set.id
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(set.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(note(for: set)).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 116, alignment: .leading)
            Spacer(minLength: 6)
            // fixed-size, resizable: the 9-glyph row always fits — each emoji = 1/9 of the width
            Group {
                if let img = previews[set.id] {
                    Image(nsImage: img).resizable().interpolation(.high)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .frame(width: PREVIEW_ROW_W, height: PREVIEW_ROW_W / CGFloat(PREVIEW_MAX))
            Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(sel ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(sel ? Color.accentColor.opacity(0.13)
                      : Color.primary.opacity(hovered == set.id ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(sel ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? set.id : (hovered == set.id ? nil : hovered) }
        .onTapGesture { if !busy { selected = set.id } }
    }

    // Per-category source picker — each row previews 3 emoji of that category in its
    // effective set, and its dropdown previews every set the same way.
    private var blendConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            blendCatRow(sample: "_default", label: L("default_row"),
                        binding: $blendDefault, includeDefault: false)
            Divider()
            ForEach(BLEND_CATS, id: \.self) { cat in
                blendCatRow(sample: cat, label: L("cat_" + cat),
                            binding: Binding(get: { blendCats[cat] ?? "" },
                                             set: { blendCats[cat] = $0 }),
                            includeDefault: true)
            }
            Text(L("blend_note"))
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(8)
    }

    private func blendCatRow(sample: String, label: String,
                             binding: Binding<String>, includeDefault: Bool) -> some View {
        let eff = binding.wrappedValue.isEmpty ? blendDefault : binding.wrappedValue
        return HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 150, alignment: .leading)
            blendPreviewView(sample, eff).frame(width: 100, alignment: .leading)
            Spacer(minLength: 4)
            Button { openPopover = (openPopover == sample ? nil : sample) } label: {
                HStack(spacing: 5) {
                    Text(setName(binding.wrappedValue.isEmpty ? "" : binding.wrappedValue))
                        .font(.caption).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }.frame(width: 150)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .popover(isPresented: Binding(get: { openPopover == sample },
                                          set: { if !$0 && openPopover == sample { openPopover = nil } })) {
                blendOptions(sample: sample, includeDefault: includeDefault, binding: binding)
            }
        }
    }

    private func blendOptions(sample: String, includeDefault: Bool, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if includeDefault {
                blendOption(sample, "", L("default_opt"), binding); Divider()
            }
            ForEach(visibleSets) { blendOption(sample, $0.id, $0.name, binding) }
        }
        .padding(8).frame(width: 250)
    }

    private func blendOption(_ sample: String, _ id: String, _ display: String, _ binding: Binding<String>) -> some View {
        let chosen = binding.wrappedValue == id
        return Button {
            binding.wrappedValue = id; openPopover = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary.opacity(0.3))
                Text(display).font(.caption).frame(width: 95, alignment: .leading)
                Spacer()
                blendPreviewView(sample, id.isEmpty ? blendDefault : id)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // a cached 3-emoji preview for (sample category, set), rendered/downloaded lazily
    private func blendPreviewView(_ sample: String, _ setId: String) -> some View {
        Group {
            if let img = blendPreview(sample, setId) {
                Image(nsImage: img).interpolation(.high)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.55)
            }
        }
    }

    // ---- actions ----
    private func loadPreviews() {
        let text = previewText.isEmpty ? DEFAULT_PREVIEW : previewText
        // Render from bundled glyphs first (instant, no network). Only if a cell needs
        // a glyph we didn't ship — i.e. custom text — do we download that set's font.
        for s in visibleSets {
            DispatchQueue.global().async {
                let r = previewRow(setId: s.id, fontPath: s.previewFont, text: text)
                if let img = r.img { DispatchQueue.main.async { previews[s.id] = img } }
                if r.needsDownload && s.id != "apple" {
                    _ = ensureFont(s.id)
                    let r2 = previewRow(setId: s.id, fontPath: s.previewFont, text: text)
                    if let img2 = r2.img { DispatchQueue.main.async { previews[s.id] = img2 } }
                }
            }
        }
    }

    private func appendLog(_ s: String) {
        DispatchQueue.main.async { log += s.hasSuffix("\n") ? s : s + "\n" }
    }

    // ---- set metadata + blend previews ----
    private func note(for set: EmojiSet) -> String {
        if let m = manifest[set.id] { return "\(m.license) · Emoji \(m.version)" }
        return set.note
    }

    private func setName(_ id: String) -> String {
        id.isEmpty ? L("default_opt") : (SETS.first { $0.id == id }?.name ?? id)
    }

    private func setPreviewFont(_ id: String) -> String {
        SETS.first { $0.id == id }?.previewFont ?? ""
    }

    // cached 3-emoji preview for (category sample, set); a cache miss kicks off a
    // background download + CoreText render and SwiftUI refreshes when it lands.
    private func blendPreview(_ sample: String, _ setId: String) -> NSImage? {
        let key = "\(sample)|\(setId)"
        if let img = blendPreviews[key] { return img }
        DispatchQueue.global().async {
            let fp = setPreviewFont(setId)
            if setId != "apple" && !FileManager.default.fileExists(atPath: fp) {
                _ = ensureFont(setId)
            }
            let r = previewRow(setId: setId, fontPath: fp, text: BLEND_SAMPLES[sample] ?? "🐷🐢🐱",
                               maxWidth: 96, maxCell: 30)
            if let img = r.img { DispatchQueue.main.async { blendPreviews[key] = img } }
        }
        return nil
    }

    // pull the emojifonts release manifest for live per-set emoji version + license
    private func loadManifest() {
        DispatchQueue.global().async {
            let url = "\(RELEASE_BASE)/manifest.json"
            let r = run("/usr/bin/curl", ["-fsSL", "-m", "20", url])
            guard r.code == 0, let data = r.out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fonts = obj["fonts"] as? [[String: Any]] else { return }
            var m: [String: (version: String, license: String)] = [:]
            for f in fonts {
                if let k = f["key"] as? String {
                    m[k] = (version: f["emoji_version"] as? String ?? "?",
                            license: f["license"] as? String ?? "")
                }
            }
            DispatchQueue.main.async { manifest = m }
        }
    }

    private func apply() {
        if blendMode { applyBlend(); return }
        if selected == "apple" { revert(); return }   // Apple = the default → revert
        busy = true
        let set = selected, m = mode
        appendLog("\n▶ Applying \(set) [\(m.rawValue)] …")
        DispatchQueue.global().async {
            if m == .system {
                // Download the prebuilt drop-in `<set>.ttc` from the emojifonts release,
                // then install it system-wide via the bundled bash helper (no Python).
                let dst = "\(CACHE)/\(set).ttc"
                appendLog("downloading \(set).ttc from the emojifonts release …")
                let dl = run("/usr/bin/curl", ["-fL", "--retry", "3", "-m", "180", "--create-dirs",
                    "-o", dst, "\(RELEASE_BASE)/\(set).ttc"])
                if dl.code != 0 {
                    appendLog("✗ couldn't download \(set).ttc (code \(dl.code)). It may not be published yet.")
                } else {
                    let i = runAdmin("BACKUP_DIR='\(APP_SUPPORT)' /bin/bash '\(bundledScript("install.sh"))' --yes '\(dst)'")
                    appendLog(i.out)
                    appendLog(i.code == 0
                        ? "✅ Installed system-wide. REBOOT to see it (this app can't reboot for you)."
                        : "✗ install failed (code \(i.code)).")
                }
            } else {
                // Install the set as a user font under its own name (native copy).
                appendLog("installing \(set) as a user font …")
                let ok = installAsFont(set)
                appendLog(ok
                    ? "✅ Installed “\(set)” as a font — pick it in an app's Font menu (give fontd a few seconds). Doesn't change typed emoji."
                    : "✗ couldn't download/install \(set).")
            }
            DispatchQueue.main.async { busy = false }
        }
    }

    // Blend by category needs the font-building toolchain (the Python CLI), so it's
    // only available in a dev checkout — not in the standalone app.
    private func applyBlend() {
        let cli = "\(PROJECT_DIR)/emojiswap"
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            appendLog("\n✗ Blend builds a custom font and needs the emojiswap CLI (dev install). Run the app from a clone of the repo, or set EMOJISWAP_DIR.")
            return
        }
        busy = true
        let m = mode
        var args = ["blend", "default=\(blendDefault)"]
        for cat in BLEND_CATS {
            if let s = blendCats[cat], !s.isEmpty, s != blendDefault { args.append("\(cat)=\(s)") }
        }
        if m == .user { args.append("--user") }
        appendLog("\n▶ Blending [\(m.rawValue)] " + args.dropFirst().joined(separator: " ") + " …")
        DispatchQueue.global().async {
            let b = run(cli, args, cwd: PROJECT_DIR)
            appendLog(b.out)
            if b.code != 0 {
                appendLog("✗ blend failed (code \(b.code)).")
            } else if m == .system {
                let i = runAdmin("BACKUP_DIR='\(APP_SUPPORT)' /bin/bash '\(bundledScript("install.sh"))' --yes '\(PROJECT_DIR)/system-font/Apple Color Emoji.ttc'")
                appendLog(i.out)
                appendLog(i.code == 0
                    ? "✅ Installed system-wide. REBOOT to see it (this app can't reboot for you)."
                    : "✗ install failed (code \(i.code)).")
            }
            DispatchQueue.main.async { busy = false }
        }
    }

    private func revert() {
        busy = true
        let m = mode
        appendLog("\n▶ Reverting [\(m.rawValue)] …")
        DispatchQueue.global().async {
            if m == .system {
                let r = runAdmin("BACKUP_DIR='\(APP_SUPPORT)' /bin/bash '\(bundledScript("restore.sh"))'")
                appendLog(r.out)
                appendLog(r.code == 0 ? "✅ Restored. REBOOT to apply." : "✗ restore failed (code \(r.code)). (Nothing to restore if you never did a system swap.)")
            } else {
                uninstallUserFonts()
                appendLog("✅ Removed EmojiSwap user fonts.")
            }
            DispatchQueue.main.async { busy = false }
        }
    }
}

@main
struct EmojiSwapApp: App {
    var body: some Scene {
        WindowGroup("EmojiSwap") { ContentView() }
            .windowResizability(.contentSize)
    }
}
