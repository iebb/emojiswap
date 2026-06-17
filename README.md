# emojiswap

Swap macOS's emoji for **Google Noto**, **Twitter Twemoji**, or **Toss Face**, and
switch back to Apple's. Handles downloading, converting fonts to a format macOS can
render, renaming, installing, and verifying.

## ⚠️ Important: what works on macOS 26

There are two ways to "swap" the emoji, and they are **not** equivalent on macOS 26:

| Route | Changes typed emoji in apps? | SIP | Reversible |
|-------|------------------------------|-----|------------|
| **User-font override** (`emojiswap set …`) | ❌ **No** (see below) | stays on | trivially |
| **System-font replacement** (`build-system` + `system-font/install.sh`) | ✅ Yes | must be **off** | yes (backup) |

**Why the easy route doesn't change app emoji on macOS 26:** when you type 🐷, your
text font has no emoji glyph, so macOS runs *font substitution* to find one — and
that path (`CTFontCreateForString`) is hardwired to the sealed system font
`/System/Library/Fonts/Apple Color Emoji.ttc`. It ignores a same-named font in
`~/Library/Fonts`. Only an explicit "give me the font named Apple Color Emoji"
request honors the override, and almost nothing uses that for emoji. Verified in
TextEdit and at the Core Text API level on macOS 26.2.

So for a real system-wide swap you must replace the system font — see
[`system-font/README.md`](system-font/README.md). The `set` command is kept for the
rare apps that request the emoji font *by name*, and as the building block the
system route reuses.

## Commands

```bash
./emojiswap build-system noto     # build a drop-in system font  → system-font/Apple Color Emoji.ttc
                                  # then follow system-font/README.md to install (SIP off)

./emojiswap blend default=noto flags=twemoji smileys=openmoji   # mix sets by category
./emojiswap keep-apple            # keep Apple's emoji under an alternate name (for comparison)

./emojiswap set noto              # user-font override (by-name only; see warning above)
./emojiswap revert                # remove the override
./emojiswap status | list | doctor
```

## Blending sets by category

`emojiswap blend` builds one font that takes each emoji **category** from a different
set — e.g. OpenMoji smileys, Twemoji flags, Noto everything else:

```bash
./emojiswap blend default=noto flags=twemoji smileys=openmoji          # build system .ttc
./emojiswap blend default=noto flags=twemoji smileys=openmoji --user   # install as a user font
```

Categories: `smileys`, `people`, `faces` (=smileys+people), `animals`, `food`, `travel`,
`activities`, `objects`, `symbols`, `flags`; any set may be assigned. It renders each
emoji from its category's source font into a uniform cell and assembles one **sbix**
font over Noto's cmap+GSUB (so flags / ZWJ sequences still work). The **EmojiSwap.app**
UI exposes this as a *Blend by category* mode — a default set plus a per-category set
picker — applying it through the same system-wide or user route as a single set.

**Why bitmap, not vector, for the blend:** a vector COLRv0 blend overflows TrueType's
65 535-glyph limit (COLRv0 makes one glyph per color region × ~3 800 detailed emoji);
OT‑SVG keeps detail but Chrome won't render it. Bitmap (sbix) is the only format that
covers a full mixed set, renders everywhere (incl. Chrome, via the box-glyf fix), and
works with *any* source. Individual flat sets (Twemoji) can still be true vector COLRv0.

## Emoji sets

All are free for at least personal use. macOS Core Text renders only **sbix** and
**COLRv0** directly; **CBDT** bitmaps are transcoded to sbix by `cbdt_to_sbix` in
[`emojiswap.py`](emojiswap.py) (lifts each PNG + offset out of CBDT, synthesizes the
empty `glyf`/`loca` tables sbix needs, packs one strike); **COLRv1** and **SVGinOT**
are dropped in favor of the transcoded sbix.

| Set        | Style                     | License            | Source format → used as | Auto? |
|------------|---------------------------|--------------------|-------------------------|-------|
| `noto`     | Google Noto               | Apache-2.0 / OFL   | CBDT → **sbix**         | ✅ |
| `twemoji`  | Twitter/X                 | CC BY 4.0          | **COLRv0** (as-is)      | ✅ |
| `tossface` | Toss Face                 | free               | **sbix** (as-is)        | ✅ |
| `openmoji` | minimalist outline        | CC BY-SA 4.0       | **COLRv0** (as-is)      | ✅ |
| `emojitwo` | glossy (open EmojiOne)    | CC BY 4.0          | **COLRv0** (as-is)      | ✅ |
| `blobmoji` | Android "blobs"           | OFL 1.1            | CBDT → **sbix**         | ✅ |
| `fluent`   | Microsoft Fluent 3D       | MIT                | CBDT → **sbix** ¹       | ✅ |
| `mutant`   | Mutant Standard           | CC BY-NC-SA 4.0 ²  | **sbix**                | manual ³ |

¹ Fluent's webfont carries COLRv1 + CBDT + SVG — macOS renders none, so we transcode
  its CBDT bitmaps and strip the rest. ² non-commercial use only. ³ mutant.tech is
  bot-protected; download the sbix build manually and drop it at
  `fonts/MutantStandard.ttf`.

**Why the transcode matters:** `Noto-COLRv1.ttf` and Android CBDT builds render as
*blank glyphs* on macOS (Core Text supports only COLRv0). Toss Face and the COLRv0
builds work as-is; everything else is transcoded to sbix, including flags / GSUB
ligatures.

## How the system route builds the font

The real `Apple Color Emoji.ttc` is a **2-font collection**: the text font
(`AppleColorEmoji`) and a UI variant (`.AppleColorEmojiUI`). `build-system` produces a
matching 2-member `.ttc` from the chosen set so substitution resolves to it after the
file is swapped on the system volume. `system-font/install.sh` backs up the original,
swaps it, and re-blesses the boot snapshot; `restore.sh` undoes it.

## Verification

`ctcheck.swift` resolves `Apple Color Emoji`, prints the file it points to, and renders
😀 via `CTLine` (the path apps use) counting colored pixels. `emojiswap set/revert/doctor`
run it automatically. **Note:** this checks the *by-name* path; to confirm a real
system-wide change, type an emoji in an app after the system-font install + reboot.

## Layout

```
emojiswap                 # CLI wrapper (uses the bundled venv)
emojiswap.py              # download, transcode, rename, install, verify, build-system
ctcheck.swift            # Core Text resolution + render verifier
system-font/             # SIP-off system replacement: install.sh, restore.sh, README.md
fonts/                   # cached source + built fonts (generated)
state.json, .venv/       # generated
```

## Requirements

macOS, Python 3 + `fonttools` (in `.venv`), Swift toolchain (verification only).
The system route additionally requires disabling SIP + authenticated-root (Recovery).
