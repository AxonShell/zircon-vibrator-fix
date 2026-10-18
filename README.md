# zircon-vibrator-fix

Experimental Magisk module for Xiaomi/Redmi Zircon devices using the AWINIC haptic driver.

## Experimental branch: vibration-log-monitor

This branch replaces notification-list polling with a `logcat -b all -v threadtime` watcher. Matching vibration/haptic diagnostics are appended to:

`/data/adb/vibration_bridge/vibration_events.log`

The bridge's own operational log remains:

`/data/adb/vibration_bridge.log`

The watcher also attempts an AWINIC sysfs fallback when it sees recognized Android framework usage records for notifications, alarms, or ringtone vibration. This depends on the exact log messages emitted by the installed firmware; vendor builds may not expose those records, so **event capture and fallback triggering are not guaranteed**. The module does not hook Android's vibration API and cannot reliably infer every requested haptic from arbitrary log lines.

## Device-specific assumptions

The service currently expects the AWINIC device at `/sys/bus/i2c/devices/0-005a` and attributes including `effect_id`, `duration`, `activate_mode`, and `activate`. It uses effect ID 10. These values are device/firmware-specific; do not install on other devices without adapting and testing them.

## Install and test

1. Keep a copy of the known-working module ZIP and ensure you can disable the module from Magisk or recovery.
2. Install the ZIP built from this branch in Magisk and reboot.
3. Trigger a notification or haptic action, then inspect the logs:

   ```sh
   su
   tail -f /data/adb/vibration_bridge.log
   ```

   In another shell:

   ```sh
   su
   tail -f /data/adb/vibration_bridge/vibration_events.log
   ```

4. Check whether the firmware actually emits the expected `VibratorManagerService` / `VibrationThread` usage lines before relying on automatic fallback.

## Safety and limitations

- This is a diagnostic workaround, not a fix to the Android vibrator HAL.
- Log messages vary by Android version and vendor build; matching rules may need adjustment.
- The fallback writes to AWINIC sysfs nodes. Test on the intended device and firmware only.
- To roll back, disable or uninstall the module in Magisk and reboot. Removing the module also removes its bridge logs.
