#!/usr/bin/env bash
#
# install.sh — replace the macOS system emoji font with a drop-in built by
# `emojiswap build-system <set>`. This is the ONLY way to change emoji
# system-wide on macOS 26 (font substitution ignores user fonts), and it is
# inherently invasive:
#
#   • requires SIP *and* authenticated-root DISABLED (you do this in Recovery)
#   • modifies the sealed system volume and re-blesses a boot snapshot
#   • lowers system security and will be undone by macOS updates
#   • a mistake here can prevent macOS from booting
#
# It backs up the original font first and verifies the backup before overwriting.
# Usage:
#   sudo ./system-font/install.sh "system-font/Apple Color Emoji.ttc"        # interactive
#   sudo ./system-font/install.sh --yes "system-font/Apple Color Emoji.ttc"  # no prompt
#
set -euo pipefail

SYS_FONT="/System/Library/Fonts/Apple Color Emoji.ttc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backup}"   # overridable so a bundled copy backs up to a writable dir
BACKUP="$BACKUP_DIR/Apple Color Emoji.ttc.orig"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
magic_of() { head -c 4 "$1" | xxd -p; }

# --- args --------------------------------------------------------------------
AUTO=0
NEW_FONT="$SCRIPT_DIR/Apple Color Emoji.ttc"
for a in "$@"; do
  case "$a" in
    --yes|-y) AUTO=1 ;;
    *)        NEW_FONT="$a" ;;
  esac
done

# --- preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { red "Run with sudo."; exit 1; }
[ -f "$NEW_FONT" ]   || { red "New font not found: $NEW_FONT"; exit 1; }
[ "$(magic_of "$NEW_FONT")" = "74746366" ] || { red "Not a .ttc (bad magic): $NEW_FONT"; exit 1; }

sip=$(csrutil status 2>/dev/null || true)
aroot=$(csrutil authenticated-root status 2>/dev/null || true)
echo "  $sip"
echo "  $aroot"
if ! echo "$sip" | grep -qi disabled || ! echo "$aroot" | grep -qi disabled; then
  red "SIP and/or authenticated-root are still ENABLED."
  ylw "Reboot to Recovery (hold the power button), open Terminal, run:"
  ylw "    csrutil disable"
  ylw "    csrutil authenticated-root disable"
  ylw "then reboot to macOS and run this script again."
  exit 1
fi

echo
ylw "About to replace the system emoji font:"
echo "    new : $NEW_FONT  ($(stat -f%z "$NEW_FONT") bytes)"
echo "    into: $SYS_FONT"
if [ "$AUTO" -ne 1 ]; then
  read -r -p "Type 'yes' to continue: " ans
  [ "$ans" = "yes" ] || { echo "Aborted."; exit 1; }
fi

# --- backup the pristine original (never overwrite an existing good backup) ---
mkdir -p "$BACKUP_DIR"
if [ -f "$BACKUP" ]; then
  if [ "$(magic_of "$BACKUP")" = "74746366" ] && [ "$(stat -f%z "$BACKUP")" -gt 1000000 ]; then
    grn "  using existing verified backup: $BACKUP ($(stat -f%z "$BACKUP") bytes)"
  else
    red "  existing backup looks invalid — refusing to proceed. Inspect: $BACKUP"; exit 1
  fi
else
  echo "  backing up original → $BACKUP"
  cp "$SYS_FONT" "$BACKUP"
  [ "$(stat -f%z "$BACKUP")" = "$(stat -f%z "$SYS_FONT")" ] || { red "Backup size mismatch — aborting."; exit 1; }
  grn "  backup created and size-verified ($(stat -f%z "$BACKUP") bytes)"
fi

# --- mount the System volume at a side mountpoint and swap the font there -----
# The booted "/" is a read-only *snapshot*; on Apple Silicon you cannot remount
# it in place (that's the `mount -uw /` "Permission denied" / error 66). Instead
# mount the underlying System volume read-write elsewhere, edit it, then bless a
# fresh snapshot from it.
ROOTDEV=$(diskutil info / | awk -F': *' '/Device Node/{print $2}')   # e.g. /dev/disk3s1s1
SYSVOL=$(printf '%s' "$ROOTDEV" | sed -E 's/s[0-9]+$//')             # e.g. /dev/disk3s1
echo "  System volume: $SYSVOL  (booted snapshot: $ROOTDEV)"

# The System volume is normally ALREADY mounted (writable) at
# /System/Volumes/Update/mnt1. Mounting it a second time fails with "Resource
# busy" (75), so reuse the existing mountpoint; only mount it if it's missing.
MNT=$(mount | awk -v d="$SYSVOL" '$1==d {print $3; exit}')
if [ -z "$MNT" ]; then
  MNT="/System/Volumes/Update/mnt1"
  echo "  mounting $SYSVOL at $MNT …"
  mkdir -p "$MNT"
  mount -o nobrowse -t apfs "$SYSVOL" "$MNT"
else
  echo "  System volume already mounted at: $MNT"
fi
echo "  ensuring the System volume is writable …"
mount -uw "$MNT" 2>/dev/null || true

TARGET="$MNT/System/Library/Fonts/Apple Color Emoji.ttc"
[ -f "$TARGET" ] || { red "Not found on System volume: $TARGET"; exit 1; }

echo "  installing new font …"
if ! cp "$NEW_FONT" "$TARGET" 2>/dev/null; then
  red "Could not write to the System volume ($TARGET)."
  ylw "Check that authenticated-root is disabled: csrutil authenticated-root status"
  exit 1
fi
chown root:wheel "$TARGET"
chmod 644 "$TARGET"

if [ "$(stat -f%z "$TARGET")" != "$(stat -f%z "$NEW_FONT")" ] || [ "$(magic_of "$TARGET")" != "74746366" ]; then
  red "Installed file failed verification — restoring backup."
  cp "$BACKUP" "$TARGET"; chown root:wheel "$TARGET"; chmod 644 "$TARGET"
  exit 1
fi
grn "  installed font verified on the System volume"

echo "  creating + blessing a new boot snapshot …"
# Apple Silicon: --folder is external-only; use Mount Mode to snapshot the
# internal System volume and set it as the boot snapshot.
bless --mount "$MNT" --create-snapshot --setBoot

echo
grn "Done. REBOOT for the new emoji to take effect:  sudo reboot"
ylw "To undo: sudo ./system-font/restore.sh   then reboot."
