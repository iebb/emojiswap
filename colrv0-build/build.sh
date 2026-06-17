#!/usr/bin/env bash
#
# build.sh — build a macOS-renderable color font from jdecked/twemoji (the
# maintained continuation of Twitter's Twemoji), from source.
#
# Output: dist/Twemoji.ttf  — a COLRv0 font (vector; macOS Core Text renders
# COLRv0 natively). nanoemoji parses the per-codepoint SVG filenames into a
# cmap + GSUB ligatures, so flags / ZWJ sequences work.
#
# Self-contained: creates its own venv and installs nanoemoji + ninja. Works
# locally and in CI (see .github/workflows/build.yml).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/work"
OUT="$HERE/dist"
mkdir -p "$WORK" "$OUT"

# --- toolchain (isolated) ----------------------------------------------------
VENV="$WORK/venv"
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q nanoemoji ninja
# nanoemoji shells out to picosvg / ninja; they must be on PATH for ninja's /bin/sh
export PATH="$VENV/bin:$PATH"

# --- source: jdecked/twemoji SVGs (shallow + sparse) -------------------------
SRC="$WORK/twemoji"
if [ ! -d "$SRC/assets/svg" ]; then
  rm -rf "$SRC"
  git clone --depth 1 --filter=blob:none --sparse https://github.com/jdecked/twemoji "$SRC"
  git -C "$SRC" sparse-checkout set assets/svg
fi
N=$(find "$SRC/assets/svg" -name '*.svg' | wc -l | tr -d ' ')
echo "jdecked twemoji SVGs: $N"

# --- stage with nanoemoji's emoji_u<cp>[_<cp>].svg naming --------------------
# twemoji names files like 1f1ee-1f1f3.svg; nanoemoji wants emoji_u1f1ee_1f1f3.svg
STAGE="$WORK/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
for f in "$SRC"/assets/svg/*.svg; do
  b="$(basename "$f" .svg)"
  cp "$f" "$STAGE/emoji_u${b//-/_}.svg"
done

# --- build COLRv0 ------------------------------------------------------------
BUILD="$WORK/nanobuild"; rm -rf "$BUILD"; mkdir -p "$BUILD"
( cd "$BUILD" && nanoemoji --color_format glyf_colr_0 \
      --family "Twemoji" --output_file Twemoji.ttf "$STAGE"/emoji_u*.svg )

cp "$BUILD/build/Twemoji.ttf" "$OUT/Twemoji.ttf"
sz=$(stat -f%z "$OUT/Twemoji.ttf" 2>/dev/null || stat -c%s "$OUT/Twemoji.ttf")
echo "built: $OUT/Twemoji.ttf ($((sz/1024)) KB)"
