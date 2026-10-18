# zircon-vibrator-fix

Experimental Magisk module for Xiaomi/Redmi Zircon devices using the AWINIC haptic driver.

## Experimental branch: hal-instance-default-experiment

This branch is based on `vibration-log-monitor` and adds an **opt-in, systemless experiment** that changes the Xiaomi HAL instance from `IVibrator/vibratorfeature` to the conventional `IVibrator/default`.

The experiment has two parts:

- A copied HAL executable with its single embedded `/vibratorfeature` literal replaced by the same-length `/default\0\0\0\0\0\0\0\0` byte sequence.
- A matching copied VINTF manifest declaring `IVibrator/default`.

The original files under `/odm` are not written to. The overlay files are placed under this module's `system/odm/` tree for Magisk to mount on the next boot.

### Prepare the experiment

1. Install the ZIP built from this branch as the existing `vibration_bridge` module.
2. Open Termux and run:

   ```sh
   su
   sh /data/adb/modules/vibration_bridge/prepare-hal-default.sh
   ```

3. If the script reports success, reboot.
4. Check the service and framework state:

   ```sh
   su
   service check android.hardware.vibrator.IVibrator/default
   service check android.hardware.vibrator.IVibrator/vibratorfeature
   dumpsys vibrator_manager | grep -iE 'vibratorIds|Vibrators:|hapticChannelMaxAmplitude'
   ```

The script fails closed unless it detects Zircon, the expected registered service, exactly one embedded instance literal, and exactly one matching manifest entry. If the installed firmware differs, it makes no overlay changes.

### Rollback

Disable this module in Magisk and reboot. The systemless overlay disappears and the original HAL binary and VINTF manifest remain untouched.

## Important: this is not a proven fix

On the tested firmware, `vibratorfeature` is registered and the framework reports `vibratorIds = []`. The framework library also contains a `vibratorfeature` lookup-related string, so an instance-name mismatch is plausible but **not proven**. This experiment only tests that hypothesis; it does not repair the kernel driver or change its sysfs interface.

The HAL binary is proprietary and its source is not included here. Rewriting an embedded string is brittle: this may not work if the binary uses a fixed-length string, or if the string is shared with Xiaomi's `IVibratorExt` registration. The script verifies the byte replacement, but it cannot prove that the patched service will initialize correctly. It has not been run on-device. Keep a recovery route available and disable the module if the HAL fails to start or the phone's haptic behavior worsens.

## Existing log monitor

This branch retains the logcat watcher. Matching vibration/haptic diagnostics are appended to:

`/data/adb/vibration_bridge/vibration_events.log`

The bridge's operational log remains:

`/data/adb/vibration_bridge.log`

The watcher attempts an AWINIC sysfs fallback for recognized Android notification, alarm, and ringtone usage records. Vendor builds may not expose those records, so event capture and fallback triggering are not guaranteed.

## Device-specific assumptions

The existing service expects the AWINIC device at `/sys/bus/i2c/devices/0-005a`, with `effect_id`, `duration`, `activate_mode`, and `activate` attributes. It uses effect ID 10. These values are device/firmware-specific; do not install on other devices without adapting and testing them.
