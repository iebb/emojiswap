# twemoji-build

A **standalone** project that builds a macOS-renderable color emoji font from
[jdecked/twemoji](https://github.com/jdecked/twemoji) — the maintained
continuation of Twitter's Twemoji (CC BY 4.0) — *from source*.

Twemoji ships only SVG/PNG assets, not a font. This builds them into a **COLRv0**
font (`dist/Twemoji.ttf`), which macOS Core Text renders natively. `nanoemoji`
turns the per-codepoint SVG filenames into a `cmap` + GSUB ligatures, so flags
and ZWJ sequences work.

## Build

```bash
./build.sh           # → dist/Twemoji.ttf
```

It creates its own venv, installs `nanoemoji` + `ninja`, shallow-sparse-clones
jdecked/twemoji's `assets/svg`, stages the files under nanoemoji's
`emoji_u<cp>[_<cp>].svg` naming, and runs nanoemoji with `--color_format glyf_colr_0`.

## CI

`.github/workflows/build.yml` runs the same build on a weekly schedule (and on
demand), uploads `dist/Twemoji.ttf` as an artifact, and refreshes a
`twemoji-latest` release — so the font tracks upstream jdecked/twemoji
automatically. This directory can be pushed as its **own repo** (the workflow
assumes it's the repo root).

## Used by emojiswap

The parent `emojiswap` tool's `twemoji` set consumes `dist/Twemoji.ttf` (via a
local fallback, or the CI release asset). Run this build once and `emojiswap
build-system twemoji` / the UI will pick it up.

## Why COLRv0 (not SVGinOT or sbix)

macOS renders sbix, COLRv0, and OT-SVG — but **not** COLRv1 or CBDT. COLRv0 keeps
Twemoji's flat vector art crisp at every size with the broadest compatibility.
Twemoji's flat design has no gradients, so nothing is lost.
