# System-wide emoji replacement (the SIP-off route)

On macOS 26 a user-font override **cannot** change emoji in apps — typed emoji are
resolved by font *substitution*, which is hardwired to the sealed system font
`/System/Library/Fonts/Apple Color Emoji.ttc`. The only way to change them
everywhere is to replace that file. That requires turning off system security and
modifying the sealed system volume.

## ⚠️ Read this first

- **You must disable SIP and authenticated-root yourself, in Recovery.** This lowers
  your Mac's security.
- This **modifies the sealed system volume** and re-blesses the boot snapshot. A
  mistake can stop macOS from booting.
- The change **does not survive macOS updates** (they restore the sealed system
  volume) — you'll re-run this after each update.
- These scripts back up the original font and can restore it, but **you accept the
  risk**. If you're not comfortable, use the browser-only route instead.

The scripts do *not* touch SIP — that's the one part only you can do, in Recovery.

## Quickest path

Once SIP + authenticated-root are disabled (step 2 below), a single command does
the rest — build, install, and prompt you to reboot:

```bash
./emojiswap apply noto        # or twemoji | tossface   (apply apple = undo)
./emojiswap unapply           # restore Apple's original
```

`apply` checks your security state first: if SIP/authenticated-root are still on it
prints the Recovery steps and changes nothing. The manual steps below are the same
operations broken out, if you'd rather run them yourself.

## Steps

### 1. Build the drop-in font (no privileges needed)
```bash
./emojiswap build-system noto        # or twemoji | tossface
```
Produces `system-font/Apple Color Emoji.ttc` (a 2-member collection: the text font
and the `.Apple Color Emoji UI` variant, both required).

### 2. Disable SIP + authenticated-root (in Recovery)
1. Shut down. Hold the **power button** until "Loading startup options" → **Options** → **Continue**.
2. Menu bar → **Utilities → Terminal**. Run:
   ```
   csrutil disable
   csrutil authenticated-root disable
   ```
   (Pick your admin user / authenticate if prompted.)
3. **Apple menu → Restart**, boot back into macOS normally.

### 3. Install the font (back in macOS)
```bash
sudo ./system-font/install.sh "system-font/Apple Color Emoji.ttc"
```
It verifies SIP is off, **backs up** the original to `system-font/backup/`, swaps the
font, and re-blesses the snapshot. Then:
```bash
sudo reboot
```
After reboot, type 🐷 anywhere — it'll be Noto.

### 4. (Optional) re-enable security
Replacing system files keeps working with SIP off. To raise security again you'd
re-enable it in Recovery (`csrutil enable`, `csrutil authenticated-root enable`) —
but note some setups won't boot a *modified* system volume with authenticated-root
back on, so only do this after you've restored the original font (step below).

## Undo
```bash
sudo ./system-font/restore.sh
sudo reboot
```
Restores Apple's original emoji from the backup.

## After a macOS update
Updates restore the stock system volume, so your emoji revert to Apple's. Re-run
step 3 (the backup from before is preserved). Rebuild the font (step 1) if you want
a newer emoji set.

## Notes
- On Apple Silicon you **cannot remount the booted snapshot** in place — `mount -uw /`
  fails with "Permission denied" / `error 66` even with SIP off. `install.sh` handles
  this correctly: it mounts the underlying **System volume** (e.g. `/dev/disk3s1`,
  derived automatically from the booted snapshot) read-write at `/tmp/emojiswap-sysmount`,
  swaps the font there, then `bless --create-snapshot` makes it the boot snapshot.
- If the mount step still fails, double-check **authenticated-root** is disabled
  (not just SIP): `csrutil authenticated-root status`.
- The drop-in uses one bitmap strike, so it scales (mild blur only at very large
  sizes); normal text/emoji sizes look crisp.
