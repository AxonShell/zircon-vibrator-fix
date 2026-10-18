#!/system/bin/sh
# Prepare an EXPERIMENTAL, systemless IVibrator/default overlay for Zircon.
# This does not modify the original /odm binary or VINTF manifest.
set -eu

MODDIR="${0%/*}"
HAL_SRC="/odm/bin/hw/vendor.xiaomi.hardware.vibratorfeature.service"
MANIFEST_SRC="/odm/etc/vintf/manifest/vendor.xiaomi.hardware.vibratorfeature.service.xml"
HAL_DST="$MODDIR/system/odm/bin/hw/vendor.xiaomi.hardware.vibratorfeature.service"
MANIFEST_DST="$MODDIR/system/odm/etc/vintf/manifest/vendor.xiaomi.hardware.vibratorfeature.service.xml"
WORK="$MODDIR/.hal-default-work.$$"
INSTALL_STARTED=0
TARGETS_WRITTEN=0

fail() {
    echo "[HAL-default experiment] ERROR: $*" >&2
    exit 1
}

cleanup() {
    RC=$?
    if [ "$INSTALL_STARTED" = "1" ] && [ "$TARGETS_WRITTEN" != "1" ]; then
        rm -f "$HAL_DST" "$MANIFEST_DST"
    fi
    rm -rf "$WORK"
    exit "$RC"
}

[ "$(id -u)" = "0" ] || fail "Run as root (enter su first)."

DEVICE="$(getprop ro.product.device)"
VENDOR_DEVICE="$(getprop ro.product.vendor.device)"
ODM_DEVICE="$(getprop ro.product.odm.device)"
case " $DEVICE $VENDOR_DEVICE $ODM_DEVICE " in
    *" zircon "*) ;;
    *) fail "This patch is restricted to Zircon. Detected: device=$DEVICE vendor=$VENDOR_DEVICE odm=$ODM_DEVICE" ;;
esac

[ -r "$HAL_SRC" ] || fail "HAL binary not readable: $HAL_SRC"
[ -r "$MANIFEST_SRC" ] || fail "VINTF manifest not readable: $MANIFEST_SRC"

command -v grep >/dev/null 2>&1 || fail "grep is unavailable"
command -v dd >/dev/null 2>&1 || fail "dd is unavailable"
command -v sed >/dev/null 2>&1 || fail "sed is unavailable"

# Require the observed service state so this cannot silently patch a different layout.
service check android.hardware.vibrator.IVibrator/vibratorfeature >/dev/null 2>&1 ||
    fail "The vibratorfeature Binder service is not currently registered."
if service check android.hardware.vibrator.IVibrator/default >/dev/null 2>&1; then
    fail "IVibrator/default already exists; refusing to patch."
fi

INSTANCE_COUNT="$(grep -aoF '/vibratorfeature' "$HAL_SRC" 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$INSTANCE_COUNT" = "1" ] ||
    fail "Expected exactly one /vibratorfeature literal in the HAL binary; found $INSTANCE_COUNT. No changes made."

MANIFEST_COUNT="$(grep -F 'IVibrator/vibratorfeature' "$MANIFEST_SRC" | wc -l | tr -d '[:space:]')"
[ "$MANIFEST_COUNT" = "1" ] ||
    fail "Expected exactly one IVibrator/vibratorfeature declaration; found $MANIFEST_COUNT. No changes made."

[ ! -e "$HAL_DST" ] && [ ! -e "$MANIFEST_DST" ] ||
    fail "An overlay already exists. Disable this module, remove its system/odm overlay files, reboot, and retry only if needed."

OFFSET="$(grep -aobF '/vibratorfeature' "$HAL_SRC" | head -n 1 | cut -d: -f1)"
[ -n "$OFFSET" ] || fail "Could not locate the instance literal offset."

mkdir -p "$WORK" || fail "Cannot create temporary work directory."
trap cleanup EXIT HUP INT TERM
cp -p "$HAL_SRC" "$WORK/hal" || fail "Could not copy the original HAL binary."
cp -p "$MANIFEST_SRC" "$WORK/manifest" || fail "Could not copy the original VINTF manifest."

# /vibratorfeature is 16 bytes; /default plus eight NUL bytes is also 16 bytes.
# Patch only the copy under the module directory, never the real /odm file.
printf '/default\000\000\000\000\000\000\000\000' |
    dd of="$WORK/hal" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null ||
    fail "Could not patch the copied HAL binary."

CHECKED="$(dd if="$WORK/hal" bs=1 skip="$OFFSET" count=8 2>/dev/null)"
[ "$CHECKED" = "/default" ] || fail "Binary patch verification failed."
if grep -aqF '/vibratorfeature' "$WORK/hal"; then
    fail "The old instance string remains in the patched binary; refusing to install."
fi

sed 's#IVibrator/vibratorfeature#IVibrator/default#g' "$WORK/manifest" > "$WORK/manifest.new"
grep -Fq 'IVibrator/default' "$WORK/manifest.new" ||
    fail "Could not create the default VINTF declaration."
if grep -Fq 'IVibrator/vibratorfeature' "$WORK/manifest.new"; then
    fail "Old instance name remains in the patched VINTF manifest."
fi
mv "$WORK/manifest.new" "$WORK/manifest"

mkdir -p "${HAL_DST%/*}" "${MANIFEST_DST%/*}" ||
    fail "Could not create systemless overlay directories."
INSTALL_STARTED=1
cp -p "$WORK/hal" "$HAL_DST" || fail "Could not install the HAL overlay."
cp -p "$WORK/manifest" "$MANIFEST_DST" || fail "Could not install the VINTF overlay."
chmod 0755 "$HAL_DST"
chmod 0644 "$MANIFEST_DST"
TARGETS_WRITTEN=1

echo "[HAL-default experiment] Prepared systemless overlay."
echo "  HAL:     $HAL_DST"
echo "  VINTF:   $MANIFEST_DST"
echo "  Offset:  $OFFSET"
echo "The original /odm files were not modified."
echo "Reboot to activate the overlay. Then check IVibrator/default and vibratorIds."
echo "If haptics or boot behavior worsens, disable this Magisk module and reboot."
echo "NOTE: This binary-literal patch is experimental and has not been tested on-device."
