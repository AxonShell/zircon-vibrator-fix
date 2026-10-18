#!/system/bin/sh
MODDIR="${0%/*}"

# Restore the original HAL if this experimental branch was applied.
if [ -r "$MODDIR/rollback-hal-default.sh" ] &&
   [ -r /data/adb/zircon-vibrator-fix-hal-backup/PATCH_APPLIED ]; then
    sh "$MODDIR/rollback-hal-default.sh" ||
        echo "[WARN] HAL rollback failed. Keep /data/adb/zircon-vibrator-fix-hal-backup and restore manually."
fi

rm -rf /data/adb/vibration_bridge
rm -f /data/adb/vibration_bridge.log
echo "[INFO] Vibration Bridge uninstalled."
