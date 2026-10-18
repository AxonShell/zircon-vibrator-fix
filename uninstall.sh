#!/system/bin/sh
MODDIR=${0%/*}
rm -rf /data/adb/vibration_bridge
rm -f /data/adb/vibration_bridge.log
echo "[INFO] Vibration Bridge uninstalled."
