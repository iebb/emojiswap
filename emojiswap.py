#!/usr/bin/env python3
"""
emojiswap — swap macOS's system emoji for Google Noto, Twemoji, or Toss Face,
and switch back to Apple's, without touching the (SIP-protected) system font.

How it works
------------
macOS resolves the emoji font by the name "Apple Color Emoji" / PostScript name
"AppleColorEmoji". Fonts installed in ~/Library/Fonts take priority over the
sealed system fonts in /System/Library/Fonts when they share that name. So we:

  1. download a color emoji font in a format macOS can render
       - Toss Face : sbix   (Apple's native color table)
       - Twemoji   : COLR/CPAL
       - Noto      : COLRv1
  2. rewrite its internal name records to "Apple Color Emoji"
  3. drop it in ~/Library/Fonts as a single managed override file

Reverting just deletes that one override file — the untouched system font wins
again. Nothing in /System is modified; SIP stays on.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
FONTS_DIR = APP_DIR / "fonts"          # cache of downloaded source fonts
DATA_DIR = APP_DIR / "data"            # emoji-test.txt + cloned SVG sources
BUILT_DIR = FONTS_DIR / "built"        # renamed override fonts we produce
STATE_FILE = APP_DIR / "state.json"
CTCHECK = APP_DIR / "ctcheck.swift"
USER_FONTS = Path.home() / "Library" / "Fonts"
# the single file we manage in ~/Library/Fonts; reverting deletes exactly this
OVERRIDE_NAME = "EmojiSwap-AppleColorEmoji.ttf"
OVERRIDE_PATH = USER_FONTS / OVERRIDE_NAME

SYSTEM_EMOJI = "/System/Library/Fonts/Apple Color Emoji.ttc"

# Canonical name records the real Apple Color Emoji font uses. Matching these
# (PostScript name in particular) is what lets the user font win font lookup.
CANON_NAMES = {
    1: "Apple Color Emoji",   # family
    2: "Regular",             # subfamily
    4: "Apple Color Emoji",   # full name
    6: "AppleColorEmoji",     # PostScript name
    16: "Apple Color Emoji",  # typographic family
    17: "Regular",            # typographic subfamily
}

# Prebuilt, macOS-renderable fonts are published by the companion emojifonts repo
# (sbix for every set, already transcoded/normalized). The swapper just downloads
# the one it needs on demand — no local transcoding.
# tag-based URL (the rolling release is a *prerelease* tagged "latest"; the
# /releases/latest/download/ form only resolves to full releases, so use the tag).
RELEASE_BASE = "https://github.com/iebb/emojifonts/releases/download/latest"

SETS = {
    "apple":    {"label": "Apple Color Emoji (macOS default)", "key": None},
    "noto":     {"label": "Google Noto Color",                 "key": "noto"},
    "twemoji":  {"label": "Twemoji (jdecked)",                 "key": "twemoji"},
    "openmoji": {"label": "OpenMoji",                          "key": "openmoji"},
    "emojitwo": {"label": "EmojiTwo (open EmojiOne)",          "key": "emojitwo"},
    "blobmoji": {"label": "Blobmoji (Android blobs)",          "key": "blobmoji"},
    "tossface": {"label": "Toss Face",                         "key": "tossface"},
    "fluent":            {"label": "Microsoft Fluent 3D",              "key": "fluent"},
    "fluent-flat":       {"label": "Microsoft Fluent Flat",            "key": "fluent-flat"},
    "noto-mono":{"label": "Noto Emoji (monochrome)",           "key": "noto-mono"},
    "fluent-mono":       {"label": "Microsoft Fluent (monochrome)",    "key": "fluent-mono"},
}

# ---- pretty output ----------------------------------------------------------
def c(code, s):
    return f"\033[{code}m{s}\033[0m" if sys.stdout.isatty() else s

def ok(s):   print(c("32", "✓ ") + s)
def warn(s): print(c("33", "! ") + s)
def err(s):  print(c("31", "✗ ") + s)
def head(s): print(c("1", s))


# ---- state ------------------------------------------------------------------
def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"active": "apple"}

def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


# ---- font sourcing ----------------------------------------------------------
def font_url(name, variant=""):
    """Release URL for set `name`'s font (variant '' = sbix, '-colrv0', '-svginot')."""
    key = SETS[name].get("key")
    return f"{RELEASE_BASE}/{key}{variant}.ttf" if key else None

def download(name, variant=""):
    """Download set `name`'s prebuilt macOS font from the emojifonts release on demand,
    cached in FONTS_DIR. emojifonts already transcodes/normalizes every set to a
    macOS-renderable sbix, so there's nothing to convert locally."""
    key = SETS[name].get("key")
    if not key:
        return None                       # apple = the system default
    FONTS_DIR.mkdir(parents=True, exist_ok=True)
    dest = FONTS_DIR / f"{key}{variant}.ttf"
    if dest.exists() and dest.stat().st_size > 1000 and is_sfnt(dest):
        return dest
    url = font_url(name, variant)
    print(f"  downloading {SETS[name]['label']} …")
    tmp = dest.with_suffix(".part")
    rc = subprocess.run(["curl", "-fL", "--retry", "3", "-m", "300", "-o", str(tmp), url]).returncode
    if rc == 0 and tmp.exists() and tmp.stat().st_size > 1000 and is_sfnt(tmp):
        tmp.replace(dest)
        ok(f"  fetched {dest.name} ({dest.stat().st_size // 1024} KB)")
        return dest
    tmp.unlink(missing_ok=True)
    raise SystemExit(f"could not download '{name}' from {url}")


def is_sfnt(path):
    with open(path, "rb") as fh:
        magic = fh.read(4)
    return magic in (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf", b"wOFF", b"wOF2")


# ---- CBDT -> sbix transcode (for Noto) --------------------------------------
def cbdt_to_sbix(src, out):
    """Transcode a CBDT/CBLC color-bitmap font (Noto) into Apple's sbix format.

    Both formats store one PNG per glyph; macOS only renders sbix. We lift the
    PNGs + their offsets out of CBDT, synthesize the empty glyf/loca tables sbix
    requires, and pack everything into a single sbix strike at the source ppem.
    """
    from fontTools.ttLib import TTFont, newTable
    from fontTools.ttLib.tables._g_l_y_f import Glyph as GlyfGlyph
    from fontTools.ttLib.tables.sbixStrike import Strike
    from fontTools.ttLib.tables.sbixGlyph import Glyph as SbixGlyph

    print("  transcoding CBDT → sbix (one-time) …")
    # lazy: some sources (Fluent) are ~88 MB with heavy COLRv1/SVG tables we
    # only want to drop — no need to decompile them.
    f = TTFont(src, lazy=True)
    ppem = f["CBLC"].strikes[0].bitmapSizeTable.ppemX

    bitmaps = {}  # glyphName -> (pngBytes, originOffsetX, originOffsetY)
    for sd in f["CBDT"].strikeData:
        for gname, gd in sd.items():
            data = getattr(gd, "imageData", None)
            if not data:
                continue
            m = gd.metrics
            # sbix originOffset is in pixels at the strike ppem. Baseline-align
            # like Apple (bitmap bottom on the baseline, offY=0) so our emoji sit
            # where Apple's do instead of dipping below the baseline.
            off_x = int(getattr(m, "BearingX", 0))
            off_y = 0
            bitmaps[gname] = (data, off_x, off_y)

    order = f.getGlyphOrder()

    # sbix is a glyf-based color format; start with empty outlines, then
    # _sbix_outline_boxes() (called at the end) gives each bitmap glyph a box
    # outline matching its bitmap — needed so Skia/HarfBuzz (Chrome) renders it.
    glyf = newTable("glyf")
    glyf.glyphOrder = order
    glyf.glyphs = {}
    for gname in order:
        g = GlyfGlyph()
        g.numberOfContours = 0
        glyf.glyphs[gname] = g
    f["glyf"] = glyf
    if "loca" not in f:
        f["loca"] = newTable("loca")   # rebuilt from glyf on compile
    f["maxp"].tableVersion = 0x00010000

    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1
    sbix.numStrikes = 1
    sbix.strikes = {}
    strike = Strike(ppem=ppem, resolution=72)
    placed = 0
    for gname in order:
        if gname in bitmaps:
            data, off_x, off_y = bitmaps[gname]
            strike.glyphs[gname] = SbixGlyph(
                glyphName=gname, graphicType="png ", imageData=data,
                originOffsetX=off_x, originOffsetY=off_y)
            placed += 1
        else:
            strike.glyphs[gname] = SbixGlyph(glyphName=gname)
    sbix.strikes[ppem] = strike
    f["sbix"] = sbix

    # drop every non-sbix color table so macOS renders our sbix (Fluent ships
    # COLRv1 + SVG too, neither of which macOS Core Text renders).
    for tag in ("CBDT", "CBLC", "COLR", "CPAL", "SVG "):
        if tag in f:
            del f[tag]

    _sbix_outline_boxes(f)   # box outlines so Chrome/Skia renders the bitmaps
    f.save(out)
    f.close()
    ok(f"  transcoded {placed} emoji into sbix → {out.name}")


def _sbix_outline_boxes(font):
    """Give each sbix bitmap glyph a glyf box outline matching the bitmap's exact
    extent (position + size at the strike's ppem).

    Core Text draws the bitmap regardless of the outline, but Skia/HarfBuzz
    (Chrome) (a) skips glyphs with an empty outline and (b) clips the bitmap to
    the outline's bounding box. A box that matches the bitmap means Chrome both
    renders it and doesn't crop it.
    """
    import struct
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    if "sbix" not in font or "glyf" not in font:
        return
    glyf = font["glyf"]
    upm = font["head"].unitsPerEm
    margin = round(upm * 0.04)   # small safety margin so antialiased edges aren't clipped
    for st in font["sbix"].strikes.values():
        scale = upm / max(1, st.ppem)   # font units per bitmap pixel
        for gname, sg in st.glyphs.items():
            data = getattr(sg, "imageData", None)
            if not data or getattr(sg, "graphicType", None) != "png " or data[:4] != b"\x89PNG":
                continue
            bw, bh = struct.unpack(">II", data[16:24])
            # originOffset is in PIXELS at the strike ppem → convert to font units
            ox, oy = int(sg.originOffsetX or 0) * scale, int(sg.originOffsetY or 0) * scale
            x0, y0 = round(ox) - margin, round(oy) - margin
            x1, y1 = round(ox + bw * scale) + margin, round(oy + bh * scale) + margin
            pen = TTGlyphPen(None)
            pen.moveTo((x0, y0)); pen.lineTo((x0, y1))
            pen.lineTo((x1, y1)); pen.lineTo((x1, y0)); pen.closePath()
            glyf[gname] = pen.glyph()


# ---- font renaming ----------------------------------------------------------
def get_render_font(name):
    """Path to a macOS-renderable build of set `name`, downloaded on demand from the
    emojifonts release (already sbix — no local transcoding needed)."""
    return download(name)


def measure_art_em(path, member=0):
    """How big the font's emoji art is, in ems (1.0 = fills the em, like Apple).
    Renders reference glyphs via artsize.swift. Returns ~1.0 if unavailable."""
    swift = shutil.which("swift")
    if not swift or not (APP_DIR / "artsize.swift").exists():
        return 1.0
    res = subprocess.run([swift, str(APP_DIR / "artsize.swift"), str(path), str(member)],
                         capture_output=True, text=True)
    for line in res.stdout.splitlines():
        if line.startswith("artEm="):
            try:
                v = float(line.split("=", 1)[1])
                return v if v > 0.1 else 1.0
            except ValueError:
                pass
    return 1.0


def normalize_to_apple_metrics(font, art_em):
    """Resize emoji to Apple Color Emoji's geometry: art = advance = 1 em.

    Third-party emoji render oversized as the *system* font (their art is ~1.1–1.25
    em and advance 1.245 em vs Apple's 1.0), and the odd metrics can break Chrome.
    `art_em` is the measured current art size (from measure_art_em); we rescale so
    the art becomes exactly 1 em:
      - sbix:     multiply each strike's ppem by art_em (bitmap → 1 em).
      - COLR/glyf: multiply UPM by art_em (outline art → 1 em).
    Then set every advance = UPM (uniform 1 em, like Apple) and flatten the vertical
    metrics to 1 em so a line containing an emoji isn't inflated.
    """
    order = font.getGlyphOrder()
    hmtx = font["hmtx"]
    art_em = max(0.5, min(2.0, art_em))   # sanity clamp

    if "sbix" in font:
        import struct
        for st in font["sbix"].strikes.values():
            st.ppem = max(1, round(st.ppem * art_em))
            # Re-centre each bitmap on the em at the NEW ppem. Origin offsets are pixels at
            # the strike ppem, so scaling ppem alone drifts the art off-centre; recentring
            # keeps art-centre at UPM/2 (like Apple) for any source bitmap size.
            for sg in st.glyphs.values():
                data = getattr(sg, "imageData", None)
                if data and getattr(sg, "graphicType", None) == "png " and data[:4] == b"\x89PNG":
                    bw, bh = struct.unpack(">II", data[16:24])
                    sg.originOffsetX = round((st.ppem - bw) / 2)
                    sg.originOffsetY = round((st.ppem - bh) / 2)
        upm = font["head"].unitsPerEm
        _sbix_outline_boxes(font)          # re-fit box outlines to the new ppem + offsets
    else:
        upm = max(16, round(font["head"].unitsPerEm * art_em))
        font["head"].unitsPerEm = upm

    for g in order:
        hmtx[g] = (upm, 0)              # uniform 1 em advance, like Apple
    font["hhea"].ascent = upm
    font["hhea"].descent = 0
    font["hhea"].lineGap = 0
    if "OS/2" in font:
        os2 = font["OS/2"]
        os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap = upm, 0, 0
        os2.usWinAscent, os2.usWinDescent = upm, 0


def set_font_names(nm, mapping):
    """Set name-table records (Mac + Windows platforms) from {nameID: value}."""
    for rec in list(nm.names):
        if rec.nameID in mapping:
            rec.string = mapping[rec.nameID]
    for nid, val in mapping.items():
        nm.setName(val, nid, 1, 0, 0)       # Macintosh / Roman / English
        nm.setName(val, nid, 3, 1, 0x409)   # Windows / Unicode BMP / en-US


def build_override(name, src_path=None):
    """Produce a copy of the source font renamed to 'Apple Color Emoji', from set
    `name` or from an already-built font at `src_path` (used by the blend)."""
    from fontTools.ttLib import TTFont

    src = str(src_path) if src_path else get_render_font(name)
    BUILT_DIR.mkdir(parents=True, exist_ok=True)
    out = BUILT_DIR / f"{name}-AppleColorEmoji.ttf"

    # lazy=True keeps big color tables (sbix/glyf) as raw bytes -> fast, lossless
    font = TTFont(src, lazy=True, fontNumber=0)
    color_tables = [t for t in ("sbix", "COLR", "CBDT", "SVG ") if t in font]
    if not color_tables:
        warn(f"  {name}: no color table found — emoji may render monochrome")

    normalize_to_apple_metrics(font, measure_art_em(src))
    set_font_names(font["name"], CANON_NAMES)
    font.save(out)
    font.close()
    return out, color_tables


# ---- system font (.ttc) builder — for the SIP-off replacement route ----------
# The real /System/Library/Fonts/Apple Color Emoji.ttc is a 2-font collection:
# the text font and a UI variant. A drop-in replacement must provide both, named
# exactly, so that font *substitution* (what apps actually use) resolves to ours.
SYSTEM_TTC_MEMBERS = [
    {1: "Apple Color Emoji",      2: "Regular", 4: "Apple Color Emoji",
     6: "AppleColorEmoji",        16: "Apple Color Emoji",      17: "Regular"},
    {1: ".Apple Color Emoji UI",  2: "Regular", 4: ".Apple Color Emoji UI",
     6: ".AppleColorEmojiUI",     16: ".Apple Color Emoji UI",  17: "Regular"},
]

def build_system_ttc(name, src_path=None):
    """Build a drop-in 'Apple Color Emoji.ttc' (two named members) from set `name`,
    or from an already-built font at `src_path` (used by the blend)."""
    from fontTools.ttLib import TTFont, TTCollection

    src = src_path if src_path else get_render_font(name)
    out_dir = APP_DIR / "system-font"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "Apple Color Emoji.ttc"

    art_em = measure_art_em(src)
    print(f"  matching Apple's emoji size (source art = {art_em:.2f} em → rescaling to 1.0)")
    members = []
    for namemap in SYSTEM_TTC_MEMBERS:
        f = TTFont(src, lazy=True, fontNumber=0)
        normalize_to_apple_metrics(f, art_em)
        set_font_names(f["name"], namemap)
        members.append(f)

    ttc = TTCollection()
    ttc.fonts = members
    ttc.save(str(out))
    for f in members:
        f.close()
    return out


# ---- keep Apple's emoji available under an alternate name -------------------
APPLE_ALT_NAMES = {1: "Apple Color Emoji Original", 2: "Regular",
                   4: "Apple Color Emoji Original", 6: "AppleColorEmojiOriginal",
                   16: "Apple Color Emoji Original", 17: "Regular"}
APPLE_ALT_FILE = USER_FONTS / "AppleColorEmojiOriginal.ttf"

def apple_source():
    """Path to a copy of Apple's original emoji font (the backup, or the live
    system font if it hasn't been replaced yet)."""
    backup = APP_DIR / "system-font" / "backup" / "Apple Color Emoji.ttc.orig"
    if backup.exists():
        return backup
    if os.path.exists(SYSTEM_EMOJI):
        return Path(SYSTEM_EMOJI)
    return None

def cmd_keep_apple(_args):
    """Install Apple's original emoji under the name 'Apple Color Emoji Original',
    so it stays usable (and comparable) after the system font is replaced."""
    from fontTools.ttLib import TTFont
    src = apple_source()
    if not src:
        raise SystemExit("can't find Apple's original emoji (no backup, system already replaced)")
    print(f"Keeping Apple's emoji as '{APPLE_ALT_NAMES[1]}' …")
    f = TTFont(str(src), lazy=True, fontNumber=0)   # member 0 = Apple Color Emoji
    set_font_names(f["name"], APPLE_ALT_NAMES)
    USER_FONTS.mkdir(parents=True, exist_ok=True)
    f.save(str(APPLE_ALT_FILE))
    f.close()
    restart_fontd()
    ok(f"installed → {APPLE_ALT_FILE}  ({APPLE_ALT_FILE.stat().st_size // (1024*1024)} MB)")
    print("  Apple's emoji are now available to apps as \"Apple Color Emoji Original\",")
    print("  and remain renderable for side-by-side comparison after a system swap.")


# ---- blend: mix sets by category (bitmap/sbix) ------------------------------
EMOJI_TEST_URL = "https://unicode.org/Public/emoji/16.0/emoji-test.txt"
# short category keys → emoji-test.txt group name(s)
BLEND_GROUPS = {
    "smileys": ["Smileys & Emotion"], "people": ["People & Body"],
    "faces":   ["Smileys & Emotion", "People & Body"],
    "animals": ["Animals & Nature"],  "food": ["Food & Drink"],
    "travel":  ["Travel & Places"],   "activities": ["Activities"],
    "objects": ["Objects"], "symbols": ["Symbols"], "flags": ["Flags"],
}

def ensure_emoji_test():
    """Download Unicode's emoji-test.txt (codepoints + categories) if missing."""
    p = DATA_DIR / "emoji-test.txt"
    if not p.exists():
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        print("  downloading Unicode emoji-test.txt …")
        subprocess.run(["curl", "-fsSL", "-o", str(p), EMOJI_TEST_URL], check=True)
    return p

def parse_emoji_test():
    """[(codepoints[], group)] for every fully-qualified emoji."""
    out, group = [], None
    for line in open(ensure_emoji_test(), encoding="utf-8"):
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
        elif "; fully-qualified" in line:
            cps = [c.lower() for c in line.split(";")[0].split()]
            out.append((cps, group))
    return out

def blend_render_font(name):
    """Render-ready font path for a blend source. 'apple' uses Apple's own emoji
    (the backup, or the live system font); everything else is the on-demand download."""
    if name == "apple":
        src = apple_source()
        if not src:
            raise SystemExit("Apple's emoji not found — run 'emojiswap keep-apple' (or restore) first")
        return str(src)
    return str(get_render_font(name))

def cmd_blend(args):
    """Mix sets by category into one font (bitmap/sbix), e.g.:
       emojiswap blend default=noto flags=twemoji smileys=openmoji

    Each emoji is rendered from its category's source font into a uniform cell
    and assembled into one sbix font over Noto's cmap+GSUB. Works with ANY set
    and has no glyph-count limit, and renders everywhere incl. Chrome. (For true
    VECTOR COLRv0 builds of flat sets, see the standalone ./colrv0-build repo.)"""
    from collections import Counter
    from fontTools.ttLib import TTFont, newTable
    from fontTools.ttLib.tables.sbixStrike import Strike
    from fontTools.ttLib.tables.sbixGlyph import Glyph as SbixGlyph

    cfg = {}
    user_route = False
    install_named = False
    for a in args:
        if a in ("--user", "-u"):
            user_route = True
        elif a in ("--install", "--as-font"):
            install_named = True
        elif "=" in a:
            k, v = a.split("=", 1)
            cfg[k.strip().lower()] = v.strip().lower()
    default = cfg.pop("default", "apple")               # Apple's emoji for everything uncategorized
    if not cfg:
        raise SystemExit("usage: emojiswap blend [default=<set>] <category>=<set> …\n"
                         f"  categories: {', '.join(BLEND_GROUPS)}\n"
                         f"  sets: {', '.join(SETS)}")
    group_set = {}
    for key, setname in cfg.items():
        if key not in BLEND_GROUPS:
            raise SystemExit(f"unknown category '{key}'. choose: {', '.join(BLEND_GROUPS)}")
        for g in BLEND_GROUPS[key]:
            group_set[g] = setname
    used = {default} | set(group_set.values())
    for s in used:
        if s not in SETS:
            raise SystemExit(f"unknown set '{s}'. choose: {', '.join(SETS)}")

    head(f"Blending (bitmap/sbix): default={default}, " +
         ", ".join(f"{k}={v}" for k, v in cfg.items()))
    fonts = {s: blend_render_font(s) for s in used}      # render-ready font per set (Apple = its backup)
    base_path = str(get_render_font("noto"))             # cmap + GSUB structure

    jobs, counts = [], Counter()
    for cps, group in parse_emoji_test():
        setname = group_set.get(group, default)
        emoji = "".join(chr(int(c, 16)) for c in cps)
        jobs.append(f"{emoji}\t{fonts[setname]}")
        counts[setname] += 1
    for s in sorted(counts):
        print(f"  {counts[s]:5d}  from {s}")

    work = DATA_DIR / "blend-work"
    shutil.rmtree(work, ignore_errors=True)
    (work / "png").mkdir(parents=True)
    (work / "jobs.txt").write_text("\n".join(jobs), encoding="utf-8")
    print("  rendering emoji from each source font …")
    res = subprocess.run(["swift", str(APP_DIR / "blendrender.swift"), base_path,
                          str(work / "jobs.txt"), str(work / "png")], capture_output=True, text=True)
    print("  " + res.stdout.strip() + (("\n  " + res.stderr.strip()) if res.returncode else ""))
    pngs = list((work / "png").glob("g*.png"))
    if not pngs:
        raise SystemExit("rendering produced no glyphs")

    # Noto structure + a fresh sbix strike of the rendered cells
    f = TTFont(base_path)
    PPEM = 160   # cell size used by blendrender
    sbix = newTable("sbix"); sbix.version = 1; sbix.flags = 1
    sbix.numStrikes = 1; sbix.strikes = {}
    strike = Strike(ppem=PPEM, resolution=72)
    by_gid = {int(p.stem[1:]): p for p in pngs}
    placed = 0
    for i, gname in enumerate(f.getGlyphOrder()):
        png = by_gid.get(i)
        if png:
            strike.glyphs[gname] = SbixGlyph(glyphName=gname, graphicType="png ",
                                             imageData=png.read_bytes(), originOffsetX=0, originOffsetY=0)
            placed += 1
        else:
            strike.glyphs[gname] = SbixGlyph(glyphName=gname)
    sbix.strikes[PPEM] = strike
    f["sbix"] = sbix
    _sbix_outline_boxes(f)
    blend_font = work / "blend.ttf"
    f.save(str(blend_font)); f.close()
    ok(f"  assembled {placed} emoji into a blended sbix font")

    save_state({**load_state(), "blend": {**cfg, "default": default}})
    if install_named:
        # install the assembled blend as an ordinary user font under its own name
        # (no SIP, no admin) — selectable in any font menu, like a single set.
        from fontTools.ttLib import TTFont
        bf = TTFont(str(blend_font))
        set_font_names(bf["name"], {1: "EmojiSwap Blend", 2: "Regular", 4: "EmojiSwap Blend",
                                    6: "EmojiSwapBlend", 16: "EmojiSwap Blend", 17: "Regular"})
        USER_FONTS.mkdir(parents=True, exist_ok=True)
        dest = USER_FONTS / "EmojiSwap-Blend.ttf"
        bf.save(str(dest)); bf.close()
        restart_fontd()
        ok(f"installed blended font as {c('1','EmojiSwap Blend')} → {dest}")
        print("  Pick 'EmojiSwap Blend' in any app's font menu (no SIP, no reboot).")
        print("  (Doesn't change typed emoji — add --user for the by-name override,")
        print("   or drop --install for the SIP-off system build.)")
    elif user_route:
        # install as a user-font override (no admin / reboot), like `emojiswap set`
        out, _ = build_override("blend", src_path=blend_font)
        USER_FONTS.mkdir(parents=True, exist_ok=True)
        shutil.copy2(out, OVERRIDE_PATH)
        restart_fontd()
        ok(f"installed blended override → {OVERRIDE_PATH}")
        print("  Quit and reopen apps (or log out/in) to see the blend.")
    else:
        out = build_system_ttc("blend", src_path=blend_font)
        ok(f"system font built → {out}")
        head("Install it (SIP off):")
        print(f"  sudo ./system-font/install.sh --yes \"{out}\"   then reboot")


# ---- font daemon refresh ----------------------------------------------------
def restart_fontd():
    """Force the font daemon to rebuild its registration from disk.

    fontd caches font registrations in memory and won't promptly notice a file
    added to / removed from ~/Library/Fonts on its own. Killing it (it relaunches
    on demand, no sudo) makes it re-scan disk, which is the source of truth.
    Newly launched apps then pick up the change; running apps need a relaunch.
    """
    subprocess.run(["killall", "fontd"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_for_resolution(want_override, timeout=20):
    """Poll Core Text until 'Apple Color Emoji' resolves the way we expect.

    want_override=True  -> wait until it resolves to our override file
    want_override=False -> wait until it resolves back to the system font
    Returns the final info dict (or None if swift is unavailable).
    """
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        info = ct_resolve()
        if not info:
            return None
        last = info
        resolved = info.get("file", "")
        on_override = (OVERRIDE_PATH.exists()
                       and os.path.exists(resolved)
                       and OVERRIDE_PATH.samefile(resolved))
        if want_override and on_override:
            return info
        if not want_override and SYSTEM_EMOJI in resolved:
            return info
        print("  …waiting for the font system to catch up", end="\r", flush=True)
        time.sleep(1.5)
    print(" " * 50, end="\r")
    return last


# ---- Core Text verification -------------------------------------------------
def ct_resolve(render_png=None):
    """Ask Core Text which file 'Apple Color Emoji' resolves to right now, and
    (optionally) render an emoji to check it draws in color. Returns dict."""
    if not CTCHECK.exists():
        return None
    args = ["swift", str(CTCHECK)]
    if render_png:
        args.append(str(render_png))
    res = subprocess.run(args, capture_output=True, text=True)
    out = {}
    for line in res.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out or None


# ---- commands ---------------------------------------------------------------
def cmd_list(_args):
    state = load_state()
    active = state.get("active", "apple")
    head("Available emoji sets:")
    for key, spec in SETS.items():
        mark = c("32", "● active") if key == active else "        "
        cached = ""
        if spec.get("key"):
            have = (FONTS_DIR / f"{spec['key']}.ttf").exists()
            cached = "  (downloaded)" if have else "  (downloads on demand)"
        print(f"  {mark}  {c('1', key):<22} {spec['label']}{cached}")
    print()
    print(f"Use: {c('36','emojiswap set <name>')}   ·   build a system font: "
          f"{c('36','emojiswap build-system <name>')}")


def cmd_status(_args):
    state = load_state()
    head("emojiswap status")
    print(f"  recorded active set : {c('1', state.get('active','apple'))}")
    installed = OVERRIDE_PATH.exists()
    print(f"  override installed  : {('yes  ' + str(OVERRIDE_PATH)) if installed else 'no (Apple default)'}")
    info = ct_resolve()
    if info:
        resolved = info.get("file", "?")
        is_override = OVERRIDE_PATH.samefile(resolved) if (installed and os.path.exists(resolved)) else False
        print(f"  Core Text resolves  : {resolved}")
        if installed and is_override:
            ok("  the swapped emoji font is live for newly launched apps")
        elif installed and not is_override:
            warn("  override file present but system font still wins — try: emojiswap doctor")
        else:
            print("  → Apple's built-in emoji are active")


def cmd_set(args):
    if not args:
        raise SystemExit("usage: emojiswap set <noto|twemoji|tossface|apple>")
    name = args[0].lower()
    if name not in SETS:
        raise SystemExit(f"unknown set '{name}'. choose: {', '.join(SETS)}")

    state = load_state()

    if name == "apple":
        return cmd_revert(_args=None)

    print(f"Switching system emoji to {c('1', SETS[name]['label'])} …")
    out, color_tables = build_override(name)
    USER_FONTS.mkdir(parents=True, exist_ok=True)
    shutil.copy2(out, OVERRIDE_PATH)
    ok(f"installed override → {OVERRIDE_PATH}")
    restart_fontd()

    state["active"] = name
    state["override_source"] = SETS[name]["key"]
    save_state(state)

    # wait for the font daemon to register it, then verify with a render
    wait_for_resolution(want_override=True)
    png = APP_DIR / "verify.png"
    info = ct_resolve(render_png=png) or {}
    resolved = info.get("file", "")
    print()
    if resolved and OVERRIDE_PATH.exists() and os.path.exists(resolved) and OVERRIDE_PATH.samefile(resolved):
        ok(f"verified: Core Text now resolves 'Apple Color Emoji' → {OVERRIDE_NAME}")
        colored = info.get("coloredPixels", "?")
        if colored not in ("?", "0"):
            ok(f"verified: emoji renders in color ({colored} colored px, sample → {png.name})")
        else:
            warn(f"emoji may not render in color on this macOS; sample → {png.name}")
    else:
        warn(f"override installed but Core Text still resolves: {resolved or 'unknown'}")
        warn("run 'emojiswap doctor', then log out/in if it persists")
    print()
    head("Last step:")
    print("  Quit and reopen any app to see the new emoji (or log out / back in for")
    print("  everything at once). The menu-bar emoji picker and a few system")
    print("  surfaces may keep Apple's glyphs — that's expected with a user-font override.")


def cmd_revert(_args):
    state = load_state()
    if OVERRIDE_PATH.exists():
        OVERRIDE_PATH.unlink()
        ok(f"removed {OVERRIDE_PATH}")
    else:
        print("  no override installed — already on Apple's emoji")
    restart_fontd()
    state["active"] = "apple"
    state.pop("override_source", None)
    save_state(state)
    info = wait_for_resolution(want_override=False) or {}
    resolved = info.get("file", "")
    if SYSTEM_EMOJI in resolved:
        ok("verified: Apple Color Emoji restored as the active font")
    else:
        warn(f"still resolving to {resolved or 'unknown'} — log out/in to fully refresh")
    print("Reverted to Apple's emoji. Relaunch apps (or log out/in) to refresh running ones.")


def cmd_download(args):
    targets = [a.lower() for a in args] or ["all"]
    if "all" in targets:
        targets = [k for k in SETS if SETS[k].get("key")]
    for name in targets:
        if name not in SETS or not SETS[name].get("key"):
            warn(f"skip '{name}' (nothing to download)")
            continue
        download(name)


def cmd_build_system(args):
    """Build a drop-in system font for the SIP-off replacement route."""
    name = (args[0].lower() if args else "noto")
    if name not in SETS or name == "apple":
        raise SystemExit(f"usage: emojiswap build-system <noto|twemoji|tossface>")
    print(f"Building drop-in system font from {c('1', SETS[name]['label'])} …")
    out = build_system_ttc(name)
    size_mb = out.stat().st_size / (1024 * 1024)
    ok(f"built {out}  ({size_mb:.1f} MB)")
    # sanity-check the built collection
    from fontTools.ttLib import TTCollection
    ttc = TTCollection(str(out), lazy=True)
    print(f"  members: {len(ttc.fonts)}")
    for i, f in enumerate(ttc.fonts):
        nm = f["name"]
        color = [t for t in ("sbix", "COLR") if t in f]
        print(f"    [{i}] {nm.getDebugName(6)!r}  color={color}")
    print()
    head("Next: install it system-wide (requires SIP disabled):")
    print(f"  {c('36', f'./emojiswap apply {name}')}     # builds + installs in one step")
    print(f"  or, manually:  sudo ./system-font/install.sh \"{out}\"")


def _security_state():
    """Best-effort (sip_disabled, authroot_disabled, sip_text, authroot_text).

    `authenticated-root` only exists on macOS 11+ (the sealed/Signed System
    Volume). On older macOS the subcommand is absent — then it isn't a gate and
    we report it disabled (not-applicable) so SIP-off alone is enough."""
    def q(*a):
        try:
            r = subprocess.run(["csrutil", *a], capture_output=True, text=True)
            return (r.stdout + r.stderr).strip()
        except Exception:
            return ""
    sip = q("status")
    aroot = q("authenticated-root", "status")
    low = aroot.lower()
    if "disabled" in low:
        aroot_off = True
    elif "enabled" in low:
        aroot_off = False
    else:
        aroot_off = True   # subcommand not recognized (pre-11) → not a gate
    return "disabled" in sip.lower(), aroot_off, sip, aroot


def cmd_apply(args):
    """Replace the *system* emoji font with a set, system-wide. This is the only
    thing that changes typed emoji in apps on macOS 10.15+ (substitution ignores
    user fonts). One command: build the drop-in font, then — if SIP (and, on
    macOS 11+, authenticated-root) is disabled — install it. Re-run after a macOS
    update, which restores the stock system volume."""
    name = (args[0].lower() if args else "noto")
    if name == "apple":
        return cmd_unapply(args)
    if name not in SETS:
        raise SystemExit("usage: emojiswap apply <noto|twemoji|tossface>   (apple = undo)")

    sip_off, aroot_off, sip_raw, aroot_raw = _security_state()
    head(f"emojiswap apply — replace system emoji with {SETS[name]['label']}")
    print(f"  {sip_raw or 'System Integrity Protection status: unknown'}")
    if "disabled" in aroot_raw.lower() or "enabled" in aroot_raw.lower():
        print(f"  {aroot_raw}")   # only on macOS 11+ where the seal exists

    if not (sip_off and aroot_off):
        warn("System security is still on — the sealed system volume can't be modified yet.")
        head("Do this once, in Recovery:")
        print("  1. Shut down. Hold the power button → 'Loading startup options' → Options → Continue.")
        print("  2. Utilities → Terminal, then run:")
        print(f"       {c('36','csrutil disable')}")
        print(f"       {c('36','csrutil authenticated-root disable')}   {c('2','# macOS 11+ only')}")
        print(f"  3. Reboot to macOS and run this again:  {c('36', f'./emojiswap apply {name}')}")
        return

    print(f"\nBuilding drop-in system font from {c('1', SETS[name]['label'])} …")
    out = build_system_ttc(name)
    ok(f"built {out}  ({out.stat().st_size / (1024 * 1024):.1f} MB)")

    installer = APP_DIR / "system-font" / "install.sh"
    print()
    head("Installing — you'll be asked for your password, then to confirm:")
    rc = subprocess.run(["sudo", "bash", str(installer), str(out)]).returncode
    if rc != 0:
        err(f"install did not complete (install.sh exit {rc}); nothing was changed.")
        raise SystemExit(rc)
    save_state({**load_state(), "active": name, "system": name})
    print()
    ok(f"system emoji replaced with {SETS[name]['label']}.")
    print(f"  Reboot to apply everywhere:  {c('36','sudo reboot')}")
    print(f"  Undo anytime:                {c('36','./emojiswap unapply')}")


def cmd_unapply(_args):
    """Undo `apply`: restore Apple's original system emoji font from the backup."""
    restorer = APP_DIR / "system-font" / "restore.sh"
    if not restorer.exists():
        raise SystemExit("nothing to undo: system-font/restore.sh not found")
    head("Restoring Apple's original system emoji font …")
    rc = subprocess.run(["sudo", "bash", str(restorer)]).returncode
    if rc != 0:
        err(f"restore did not complete (restore.sh exit {rc}).")
        raise SystemExit(rc)
    save_state({**load_state(), "active": "apple", "system": None})
    ok("Apple's original emoji restored.")
    print(f"  Reboot to apply:  {c('36','sudo reboot')}")


def cmd_install_user(args):
    """Install emoji sets as ordinary USER fonts (no SIP, no admin), under their
    OWN names. They become selectable in any app's font menu and resolvable
    by-name. This does NOT change auto-substituted typed emoji — that needs
    `apply` (the system route). Use it for apps where you pick the font yourself."""
    from fontTools.ttLib import TTFont
    if not args or args[0] in ("-h", "--help"):
        sets = ", ".join(k for k in SETS if k != "apple")
        raise SystemExit(f"usage: emojiswap install-user <set|all>\n  sets: {sets}")
    pick = args[0].lower()
    names = [k for k in SETS if k != "apple"] if pick == "all" else [pick]
    USER_FONTS.mkdir(parents=True, exist_ok=True)
    installed = []
    for name in names:
        if name not in SETS or name == "apple":
            warn(f"  unknown set '{name}' — skipped"); continue
        src = get_render_font(name)
        if not src:
            continue
        dest = USER_FONTS / f"EmojiSwap-{SETS[name]['key']}.ttf"
        shutil.copy2(src, dest)
        fam = TTFont(str(dest), lazy=True, fontNumber=0)["name"].getDebugName(1)
        installed.append(fam)
        ok(f"  installed {SETS[name]['label']}  →  pick {c('1', fam)} in a font menu")
    if not installed:
        raise SystemExit("nothing installed")
    restart_fontd()
    print()
    head("Available (give fontd a few seconds; shows in newly-opened apps) —")
    print("  Pages / Keynote / Numbers, TextEdit (Format → Font), design apps, etc.")
    warn("This does NOT change emoji you simply *type* (macOS substitutes the sealed")
    print("  system font there). To change typed emoji everywhere:  ./emojiswap apply <set>")
    print("  Undo:  rm ~/Library/Fonts/EmojiSwap-*.ttf && killall fontd")


def cmd_doctor(_args):
    head("emojiswap doctor")
    # 1. environment
    print(f"  system emoji font : {'present' if os.path.exists(SYSTEM_EMOJI) else 'MISSING'}")
    print(f"  ~/Library/Fonts   : {'writable' if os.access(USER_FONTS, os.W_OK) or not USER_FONTS.exists() else 'NOT writable'}")
    try:
        import fontTools  # noqa: F401
        ok("  fonttools available")
    except ImportError:
        err("  fonttools missing — run: .venv/bin/pip install fonttools")
    swift = shutil.which("swift")
    print(f"  swift (verify)    : {swift or 'not found (verification limited)'}")
    # 2. live resolution + render
    png = APP_DIR / "verify.png"
    info = ct_resolve(render_png=png)
    if info:
        print(f"  resolves to       : {info.get('file','?')}")
        print(f"  glyph found       : {info.get('glyphFound','?')}")
        print(f"  colored pixels    : {info.get('coloredPixels','?')}  (>0 means color emoji render)")
        print(f"  render sample     : {png}")
    else:
        warn("  could not run Core Text check")
    # 3. advice
    print()
    if OVERRIDE_PATH.exists():
        print("  An override is installed. If apps still show Apple emoji:")
        print("   • quit & reopen the app (running apps cache fonts)")
        print("   • or log out and back in to refresh every process")
    else:
        print("  No override installed (Apple default).")


HELP = f"""\
{c('1','emojiswap')} — swap macOS system emoji (Noto / Twemoji / Toss Face) and back

{c('1','Change typed emoji everywhere')} (needs SIP + authenticated-root disabled):
  {c('36','emojiswap apply <set>')}      build + replace the system emoji font in one
                              step (noto|twemoji|tossface). The only thing that
                              changes auto-substituted typed emoji on macOS 10.15+.
                              Walks you through Recovery; re-run after a macOS
                              update. (apply apple = undo)
  {c('36','emojiswap unapply')}          restore Apple's original system emoji
  {c('36','emojiswap build-system <set>')} just build the drop-in .ttc, don't install

{c('1','Install fonts without SIP')} (selectable in apps / by-name; not auto-typed emoji):
  {c('36','emojiswap install-user <set|all>')} install set(s) as normal user fonts under
                              their own names — pick them in any app's font menu
  {c('36','emojiswap blend … --install')}      install an assembled blend as the user
                              font 'EmojiSwap Blend'
  {c('36','emojiswap set <set>')}        override renamed to 'Apple Color Emoji' (only
                              helps apps that request that font by name; niche)
  {c('36','emojiswap revert')}           remove the 'Apple Color Emoji' override

{c('1','Other')}:
  {c('36','emojiswap blend …')}          mix sets by category (default=<set> cat=<set> …)
  {c('36','emojiswap status | list | doctor')}   inspect / diagnose
  {c('36','emojiswap download [set]')}   pre-fetch source fonts (default: all)
"""

COMMANDS = {
    "apply": cmd_apply, "unapply": cmd_unapply, "install-user": cmd_install_user,
    "set": cmd_set, "revert": cmd_revert, "status": cmd_status,
    "list": cmd_list, "download": cmd_download, "doctor": cmd_doctor,
    "build-system": cmd_build_system, "keep-apple": cmd_keep_apple,
    "blend": cmd_blend,
}

def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(HELP)
        return 0
    cmd, *rest = argv
    fn = COMMANDS.get(cmd)
    if not fn:
        err(f"unknown command '{cmd}'")
        print(HELP)
        return 2
    fn(rest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
