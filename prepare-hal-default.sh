#!/system/bin/sh
# EXPERIMENTAL: rename the Xiaomi AIDL instance to IVibrator/default.
# Requires the separate Magisk OverlayFS module so /odm edits stay systemless.
set -eu

MODDIR="${0%/*}"
HAL="/odm/bin/hw/vendor.xiaomi.hardware.vibratorfeature.service"
MANIFEST="/odm/etc/vintf/manifest/vendor.xiaomi.hardware.vibratorfeature.service.xml"
OVERLAYFS="/data/adb/modules/magisk_overlayfs"
BACKUP="/data/adb/zircon-vibrator-fix-hal-backup"
WORK="/data/adb/.zircon-vibrator-fix-work.$$"
BACKUP_READY=0
PATCH_STARTED=0
PATCH_APPLIED=0

fail() {
    echo "[HAL-default experiment] ERROR: $*" >&2
    exit 1
}

restore_originals() {
    [ "$BACKUP_READY" = "1" ] || return 1
    [ -r "$BACKUP/hal.original" ] || return 1
    [ -r "$BACKUP/manifest.original" ] || return 1
    cat "$BACKUP/hal.original" > "$HAL" || return 1
    cat "$BACKUP/manifest.original" > "$MANIFEST" || return 1
    chmod 0755 "$HAL" 2>/dev/null || true
    chmod 0644 "$MANIFEST" 2>/dev/null || true
    restorecon "$HAL" "$MANIFEST" 2>/dev/null || true
    return 0
}

cleanup() {
    RC=$?
    trap - EXIT HUP INT TERM
    if [ "$PATCH_STARTED" = "1" ] && [ "$PATCH_APPLIED" != "1" ]; then
        echo "[HAL-default experiment] Patch incomplete; attempting automatic restore." >&2
        if ! restore_originals; then
            echo "[HAL-default experiment] CRITICAL: restore failed. Originals are in $BACKUP" >&2
        fi
    fi
    rm -rf "$WORK"
    exit "$RC"
}

[ "$(id -u)" = "0" ] || fail "Run from a root shell (enter su first)."

DEVICE="$(getprop ro.product.device)"
VENDOR_DEVICE="$(getprop ro.product.vendor.device)"
ODM_DEVICE="$(getprop ro.product.odm.device)"
case " $DEVICE $VENDOR_DEVICE $ODM_DEVICE " in
    *" zircon "*) ;;
    *) fail "Restricted to Zircon. Detected: device=$DEVICE vendor=$VENDOR_DEVICE odm=$ODM_DEVICE" ;;
esac

[ -r "$HAL" ] || fail "HAL binary not readable: $HAL"
[ -r "$MANIFEST" ] || fail "VINTF manifest not readable: $MANIFEST"
[ -x "$OVERLAYFS/overlayfs_system" ] ||
    fail "Install and enable Magisk OverlayFS first. Stock Magisk cannot reliably overlay a separate /odm partition."
"$OVERLAYFS/overlayfs_system" --test >/dev/null 2>&1 ||
    fail "Magisk OverlayFS reports that this kernel/setup is unsupported."

service check android.hardware.vibrator.IVibrator/vibratorfeature >/dev/null 2>&1 ||
    fail "The observed IVibrator/vibratorfeature Binder service is not registered."
if service check android.hardware.vibrator.IVibrator/default >/dev/null 2>&1; then
    fail "IVibrator/default already exists; refusing to patch."
fi

INSTANCE_COUNT="$(grep -aoF '/vibratorfeature' "$HAL" 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$INSTANCE_COUNT" = "1" ] ||
    fail "Expected exactly one /vibratorfeature literal in the HAL binary; found $INSTANCE_COUNT. No change made."

MANIFEST_COUNT="$(grep -F 'IVibrator/vibratorfeature' "$MANIFEST" | wc -l | tr -d '[:space:]')"
[ "$MANIFEST_COUNT" = "1" ] ||
    fail "Expected exactly one IVibrator/vibratorfeature declaration; found $MANIFEST_COUNT. No change made."

[ ! -e "$BACKUP" ] ||
    fail "Backup directory already exists at $BACKUP. Restore or inspect it before attempting another patch."
mkdir -p "$WORK" || fail "Cannot create temporary work directory."
trap cleanup EXIT HUP INT TERM

cp -p "$HAL" "$WORK/hal" || fail "Could not stage HAL binary."
cp -p "$MANIFEST" "$WORK/manifest" || fail "Could not stage VINTF manifest."

OFFSET="$(grep -aobF '/vibratorfeature' "$HAL" | head -n 1 | cut -d: -f1)"
[ -n "$OFFSET" ] || fail "Could not locate the instance literal offset."

# The source string is 16 bytes. Replace it with /default and eight NUL bytes,
# preserving the ELF file size. This is intentionally guarded and experimental.
printf '/default\000\000\000\000\000\000\000\000' |
    dd of="$WORK/hal" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null ||
    fail "Could not patch the staged HAL binary."

CHECKED="$(dd if="$WORK/hal" bs=1 skip="$OFFSET" count=8 2>/dev/null)"
[ "$CHECKED" = "/default" ] || fail "Binary patch verification failed."
if grep -aqF '/vibratorfeature' "$WORK/hal"; then
    fail "Old instance literal remains in the staged binary."
fi

sed 's#IVibrator/vibratorfeature#IVibrator/default#g' "$WORK/manifest" > "$WORK/manifest.new"
grep -Fq 'IVibrator/default' "$WORK/manifest.new" ||
    fail "Could not create the default VINTF declaration."
if grep -Fq 'IVibrator/vibratorfeature' "$WORK/manifest.new"; then
    fail "Old instance remains in staged VINTF manifest."
fi
mv "$WORK/manifest.new" "$WORK/manifest"

# Keep restorable originals outside the module directory, because the OverlayFS
# changes live in its own upper layer and disabling this module alone won't undo them.
mkdir -m 0700 "$BACKUP" || fail "Could not create backup directory."
cp -p "$HAL" "$BACKUP/hal.original" || fail "Could not back up original HAL."
cp -p "$MANIFEST" "$BACKUP/manifest.original" || {
    rm -rf "$BACKUP"
    fail "Could not back up original manifest."
}
chmod 0600 "$BACKUP/hal.original" "$BACKUP/manifest.original"
BACKUP_READY=1
printf 'device=%s\n' "$DEVICE" > "$BACKUP/device.txt"

# Magisk OverlayFS documents this command for making the mounted overlays writable.
su -mm -c magic_remount_rw ||
    fail "Could not make OverlayFS writable; no target file has been changed."

PATCH_STARTED=1
cat "$WORK/hal" > "$HAL" || fail "Could not write patched HAL through OverlayFS."
cat "$WORK/manifest" > "$MANIFEST" || fail "Could not write patched VINTF manifest through OverlayFS."
chmod 0755 "$HAL"
chmod 0644 "$MANIFEST"
restorecon "$HAL" "$MANIFEST" 2>/dev/null || true

CHECKED="$(dd if="$HAL" bs=1 skip="$OFFSET" count=8 2>/dev/null)"
[ "$CHECKED" = "/default" ] || fail "On-device HAL verification failed."
grep -Fq 'IVibrator/default' "$MANIFEST" || fail "On-device VINTF verification failed."
if grep -aqF '/vibratorfeature' "$HAL" || grep -Fq 'IVibrator/vibratorfeature' "$MANIFEST"; then
    fail "Old instance name remains after writing."
fi

date '+%Y-%m-%d %H:%M:%S' > "$BACKUP/PATCH_APPLIED"
PATCH_APPLIED=1
echo "[HAL-default experiment] Patch prepared in the Magisk OverlayFS upper layer."
echo "Original files backed up to: $BACKUP"
echo "Reboot, then check IVibrator/default and dumpsys vibrator_manager."
echo "To undo, run: sh $MODDIR/rollback-hal-default.sh"
echo "This is an untested binary-literal patch. It may affect Xiaomi IVibratorExt or fail to initialize."
