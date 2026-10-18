# zircon-vibrator-fix

Experimental Magisk module for Xiaomi/Redmi Zircon devices using the AWINIC haptic driver.

## Experimental branch: hal-instance-default-experiment

This branch started as an **opt-in test** of changing Xiaomi's HAL instance from `IVibrator/vibratorfeature` to `IVibrator/default`, but the current device evidence argues against applying that rename without more diagnostics. The installed `/system/lib64/libvibratorservice.so` contains `Connected to Vibrator HAL AIDL service : vibratorfeature`, suggesting this firmware intentionally supports that instance. The prep script now detects that exact string and **refuses to patch**. Do not install OverlayFS just to force this test; capture runtime HAL errors first. The conventional `default` name alone does not prove the current instance is wrong.

### Requirements

- The intended Xiaomi/Redmi Zircon firmware.
- Magisk root.
- The separate **Magisk OverlayFS** module installed and working. Standard Magisk does not reliably map `system/odm` overlays onto a separately mounted `/odm` partition; this branch uses OverlayFS instead. See [Magisk OverlayFS](https://github.com/Magisk-Modules-Alt-Repo/magisk_overlayfs).
- A way to disable modules or access recovery before testing.

### Prepare the experiment

1. Install the ZIP built from this branch as the existing `vibration_bridge` module.
2. Open Termux and run:

   ```sh
   su
   sh /data/adb/modules/vibration_bridge/prepare-hal-default.sh
   ```

3. If the script reports success, reboot.
4. Check the HAL and framework:

   ```sh
   su
   service check android.hardware.vibrator.IVibrator/default
   service check android.hardware.vibrator.IVibrator/vibratorfeature
   dumpsys vibrator_manager | grep -iE 'vibratorIds|Vibrators:|hapticChannelMaxAmplitude'
   ```

The preparation script fails closed unless it detects Zircon, the expected running service, exactly one null-terminated registration literal, and exactly one matching VINTF declaration. It backs up both original files to `/data/adb/zircon-vibrator-fix-hal-backup` before changing them. Changes are written through the OverlayFS upper layer, not to the underlying flash partition.

### Rollback

**Disabling this module alone does not undo changes stored in the separate OverlayFS upper layer.** To restore the original files, run:

```sh
su
sh /data/adb/modules/vibration_bridge/rollback-hal-default.sh
reboot
```

The restore script verifies both files and keeps the backup at `/data/adb/zircon-vibrator-fix-hal-backup`. Delete that directory only after confirming the original service is restored and working.

### Risks and limitations

This is not a proven fix. The HAL binary is proprietary and its source is not included. Rewriting an embedded string is brittle: the binary may use a fixed-length string, or the literal may also be used by Xiaomi's `IVibratorExt` registration. The script verifies the byte replacement and VINTF edit but cannot prove that the service initializes correctly. It has **not** been tested on-device. If haptics worsen, run the rollback script and reboot.

## Existing log monitor

This branch retains the `logcat -b all -v threadtime` watcher. Matching vibration/haptic diagnostics are appended to:

`/data/adb/vibration_bridge/vibration_events.log`

The bridge's operational log remains:

`/data/adb/vibration_bridge.log`

The watcher attempts an AWINIC sysfs fallback for recognized Android notification, alarm, and ringtone usage records. Vendor builds may not expose those records, so capture and fallback triggering are not guaranteed.

## Device-specific assumptions

The existing service expects the AWINIC device at `/sys/bus/i2c/devices/0-005a`, with `effect_id`, `duration`, `activate_mode`, and `activate` attributes. It uses effect ID 10. These values are firmware-specific; do not install on other devices without adapting and testing them.
