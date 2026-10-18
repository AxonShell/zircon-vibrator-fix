#!/system/bin/sh
MODDIR="${0%/*}"

# Restore the original HAL if a backup exists, including after a partial attempt.
if [ -r "$MODDIR/rollback-hal-default.sh" ] &&
   [ -r /data/adb/zircon-vibrator-fix-hal-backup/hal.original ] &&
   [ -r /data/adb/zircon-vibrator-fix-hal-backup/manifest.original ]; then
    sh "$MODDIR/rollback-hal-default.sh" ||
        echo "[WARN] HAL rollback failed. Keep /data/adb/zircon-vibrator-fix-hal-backup and restore manually."
fi

rm -rf /data/adb/vibration_bridge
rm -f /data/adb/vibration_bridge.log
echo "[INFO] Vibration Bridge uninstalled."
