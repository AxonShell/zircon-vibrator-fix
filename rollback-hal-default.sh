#!/system/bin/sh
# Restore the original HAL binary and VINTF manifest from the saved copies.
set -eu

BACKUP="/data/adb/zircon-vibrator-fix-hal-backup"
HAL="/odm/bin/hw/vendor.xiaomi.hardware.vibratorfeature.service"
MANIFEST="/odm/etc/vintf/manifest/vendor.xiaomi.hardware.vibratorfeature.service.xml"
OVERLAYFS="/data/adb/modules/magisk_overlayfs"

fail() {
    echo "[HAL-default rollback] ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "Run from a root shell (enter su first)."
[ -r "$BACKUP/hal.original" ] || fail "Original HAL backup is missing: $BACKUP/hal.original"
[ -r "$BACKUP/manifest.original" ] || fail "Original manifest backup is missing: $BACKUP/manifest.original"
[ -x "$OVERLAYFS/overlayfs_system" ] ||
    fail "Magisk OverlayFS is required to restore the /odm files."

"$OVERLAYFS/overlayfs_system" --test >/dev/null 2>&1 ||
    fail "Magisk OverlayFS is not available for this setup."
su -mm -c magic_remount_rw || fail "Could not make OverlayFS writable."

cat "$BACKUP/hal.original" > "$HAL" || fail "Could not restore original HAL."
cat "$BACKUP/manifest.original" > "$MANIFEST" || fail "Could not restore original manifest."
chmod 0755 "$HAL"
chmod 0644 "$MANIFEST"
restorecon "$HAL" "$MANIFEST" 2>/dev/null || true

if grep -aqF '/vibratorfeature' "$HAL" &&
   grep -Fq 'IVibrator/vibratorfeature' "$MANIFEST"; then
    echo "[HAL-default rollback] Original HAL and manifest restored. Reboot now."
    echo "Backup retained at $BACKUP until you remove it manually."
else
    fail "Restore verification failed. Originals remain in $BACKUP."
fi
