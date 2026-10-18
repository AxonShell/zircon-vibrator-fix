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
BACKUP_CREATED=0
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
    elif [ "$PATCH_STARTED" != "1" ] && [ "$BACKUP_CREATED" = "1" ]; then
        rm -rf "$BACKUP"
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
    fail "Install and enable Magisk OverlayFS first. Standard Magisk does not reliably overlay a separate /odm partition."
"$OVERLAYFS/overlayfs_system" --test >/dev/null 2>&1 ||
    fail "Magisk OverlayFS reports that this kernel/setup is unsupported."

if ! service check android.hardware.vibrator.IVibrator/vibratorfeature 2>&1 |
    grep -Fq 'Service android.hardware.vibrator.IVibrator/vibratorfeature: found'; then
    fail "The observed IVibrator/vibratorfeature Binder service is not registered."
fi
if service check android.hardware.vibrator.IVibrator/default 2>&1 |
    grep -Fq 'Service android.hardware.vibrator.IVibrator/default: found'; then
    fail "IVibrator/default already exists; refusing to patch."
fi

# The source path in this ELF also contains the text /vibratorfeature.
# Count only the null-terminated C string used as a registration literal.
MATCHES="$(grep -aobF '/vibratorfeature' "$HAL" 2>/dev/null || true)"
OFFSET=""
INSTANCE_COUNT=0
for ENTRY in $MATCHES; do
    POS="${ENTRY%%:*}"
    NEXT_BYTE="$(dd if="$HAL" bs=1 skip="$((POS + 16))" count=1 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
    if [ "$NEXT_BYTE" = "00" ]; then
        OFFSET="$POS"
        INSTANCE_COUNT=$((INSTANCE_COUNT + 1))
    fi
done
[ "$INSTANCE_COUNT" = "1" ] ||
    fail "Expected exactly one null-terminated /vibratorfeature registration literal; found $INSTANCE_COUNT. No change made."

MANIFEST_COUNT="$(grep -F 'IVibrator/vibratorfeature' "$MANIFEST" | wc -l | tr -d '[:space:]')"
[ "$MANIFEST_COUNT" = "1" ] ||
    fail "Expected exactly one IVibrator/vibratorfeature declaration; found $MANIFEST_COUNT. No change made."

[ ! -e "$BACKUP" ] ||
    fail "Backup directory already exists at $BACKUP. Restore or inspect it before attempting another patch."

mkdir -p "$WORK" || fail "Cannot create temporary work directory."
trap cleanup EXIT HUP INT TERM
cp -p "$HAL" "$WORK/hal" || fail "Could not stage HAL binary."
cp -p "$MANIFEST" "$WORK/manifest" || fail "Could not stage VINTF manifest."

# Source registration string is 16 bytes. Replace with /default and eight NUL
# bytes so the ELF size is unchanged. This is intentionally experimental.
printf '/default\000\000\000\000\000\000\000\000' |
    dd of="$WORK/hal" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null ||
    fail "Could not patch the staged HAL binary."

CHECKED="$(dd if="$WORK/hal" bs=1 skip="$OFFSET" count=8 2>/dev/null)"
[ "$CHECKED" = "/default" ] || fail "Binary patch verification failed."
ZERO_BYTES="$(dd if="$WORK/hal" bs=1 skip="$((OFFSET + 8))" count=8 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
[ "$ZERO_BYTES" = "0000000000000000" ] || fail "Instance string terminator verification failed."

sed 's#IVibrator/vibratorfeature#IVibrator/default#g' "$WORK/manifest" > "$WORK/manifest.new"
grep -Fq 'IVibrator/default' "$WORK/manifest.new" ||
    fail "Could not create the default VINTF declaration."
if grep -Fq 'IVibrator/vibratorfeature' "$WORK/manifest.new"; then
    fail "Old instance remains in staged VINTF manifest."
fi
mv "$WORK/manifest.new" "$WORK/manifest"

mkdir -m 0700 "$BACKUP" || fail "Could not create backup directory."
BACKUP_CREATED=1
cp -p "$HAL" "$BACKUP/hal.original" || fail "Could not back up original HAL."
cp -p "$MANIFEST" "$BACKUP/manifest.original" || fail "Could not back up original manifest."
chmod 0600 "$BACKUP/hal.original" "$BACKUP/manifest.original"
BACKUP_READY=1
printf 'device=%s\n' "$DEVICE" > "$BACKUP/device.txt"

# This writes to OverlayFS' upper layer, not to the underlying flash partition.
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
if grep -Fq 'IVibrator/vibratorfeature' "$MANIFEST"; then
    fail "Old instance name remains in the manifest after writing."
fi

date '+%Y-%m-%d %H:%M:%S' > "$BACKUP/PATCH_APPLIED"
PATCH_APPLIED=1
echo "[HAL-default experiment] Patch prepared in the Magisk OverlayFS upper layer."
echo "Original files backed up to: $BACKUP"
echo "Reboot, then check IVibrator/default and dumpsys vibrator_manager."
echo "To undo, run: sh $MODDIR/rollback-hal-default.sh"
echo "This is an untested binary-literal patch. It may affect Xiaomi IVibratorExt or fail to initialize."
