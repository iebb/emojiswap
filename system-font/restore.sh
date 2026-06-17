#!/usr/bin/env bash
#
# restore.sh — put Apple's original emoji font back, from the backup install.sh made.
# Run:  sudo ./system-font/restore.sh   (then reboot)
#
set -euo pipefail

SYS_FONT="/System/Library/Fonts/Apple Color Emoji.ttc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP="$SCRIPT_DIR/backup/Apple Color Emoji.ttc.orig"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { red "Run with sudo."; exit 1; }
[ -f "$BACKUP" ]     || { red "No backup found at: $BACKUP"; exit 1; }

magic=$(head -c 4 "$BACKUP" | xxd -p)
[ "$magic" = "74746366" ] || { red "Backup is not a valid .ttc (magic $magic) — aborting."; exit 1; }

ROOTDEV=$(diskutil info / | awk -F': *' '/Device Node/{print $2}')
SYSVOL=$(printf '%s' "$ROOTDEV" | sed -E 's/s[0-9]+$//')
MNT=$(mount | awk -v d="$SYSVOL" '$1==d {print $3; exit}')
if [ -z "$MNT" ]; then
  MNT="/System/Volumes/Update/mnt1"
  mkdir -p "$MNT"
  mount -o nobrowse -t apfs "$SYSVOL" "$MNT"
else
  echo "  System volume already mounted at: $MNT"
fi
mount -uw "$MNT" 2>/dev/null || true

TARGET="$MNT/System/Library/Fonts/Apple Color Emoji.ttc"
echo "  restoring original font …"
cp "$BACKUP" "$TARGET"
chown root:wheel "$TARGET"
chmod 644 "$TARGET"
echo "  creating + blessing a new boot snapshot …"
bless --mount "$MNT" --create-snapshot --setBoot

echo
grn "Original emoji restored. REBOOT to apply:  sudo reboot"
echo "Optional: re-enable security in Recovery with 'csrutil enable' and"
echo "'csrutil authenticated-root enable'."
