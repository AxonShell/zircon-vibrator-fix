#!/system/bin/sh

MODDIR="${0%/*}"
LOGFILE="/data/adb/vibration_bridge.log"
SYSFS_DIR="/sys/bus/i2c/devices/0-005a"
DRIVER="/sys/bus/i2c/drivers/awinic_haptic"
STATE_DIR="/data/adb/vibration_bridge"

EFFECT_ID=10
NOTIF_DURATION=210
SYSTEM_DURATION=70
CALL_DURATION=300
ALARM_DURATION=400
DEBOUNCE_SECONDS=3
POLL_SECONDS=1
ALARM_REPEAT_INTERVAL=3
CALL_REPEAT_INTERVAL=2

OLD="$STATE_DIR/notif_old.txt"
NEW="$STATE_DIR/notif_new.txt"
LOCK="$STATE_DIR/vibration.lock"
MAIN_PID="$MODDIR/main.pid"
NOTIF_PID_FILE="$MODDIR/notification.pid"
ALARM_LOOP_PID_FILE="$MODDIR/alarm_loop.pid"
CALL_LOOP_PID_FILE="$MODDIR/call_loop.pid"

mkdir -p "$STATE_DIR" || exit 1
touch "$LOGFILE"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

write_attr() {
    ATTR="$1"
    VALUE="$2"
    TARGET="$SYSFS_DIR/$ATTR"

    [ -e "$TARGET" ] || {
        log_msg "ERROR: Missing attribute: $TARGET"
        return 1
    }

    printf '%s\n' "$VALUE" > "$TARGET" 2>/dev/null || {
        log_msg "ERROR: Write failed: $ATTR=$VALUE"
        return 1
    }
}

pulse() {
    DURATION="$1"

    write_attr effect_id "$EFFECT_ID" || return 1
    write_attr duration "$DURATION" || return 1
    write_attr activate 1 || return 1

    case "$DURATION" in
        70)   sleep 0.10 ;;
        210)  sleep 0.25 ;;
        300)  sleep 0.35 ;;
        400)  sleep 0.45 ;;
        500)  sleep 0.55 ;;
        1000) sleep 1.05 ;;
        *)    sleep 0.30 ;;
    esac

    write_attr activate 0
}

pattern_single() {
    pulse "$1"
}

pattern_snapchat() {
    pulse "$NOTIF_DURATION" || return 1
    sleep 0.14
    pulse "$NOTIF_DURATION"
}

pattern_default() {
    pulse "$NOTIF_DURATION" || return 1
    sleep 0.14
    pulse "$NOTIF_DURATION" || return 1
    sleep 0.40
    pulse "$NOTIF_DURATION" || return 1
    sleep 0.14
    pulse "$NOTIF_DURATION"
}

vibrate() {
    REASON="$1"
    PATTERN="$2"

    [ -d "$SYSFS_DIR" ] || {
        log_msg "ERROR: AWINIC device unavailable"
        return 1
    }

    if ! mkdir "$LOCK" 2>/dev/null; then
        LOCK_PID=""
        [ -r "$LOCK/pid" ] &&
            LOCK_PID="$(cat "$LOCK/pid" 2>/dev/null)"

        if [ -n "$LOCK_PID" ] &&
            kill -0 "$LOCK_PID" 2>/dev/null; then
            log_msg "Vibration skipped: busy ($REASON)"
            return 1
        fi

        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || {
            log_msg "Vibration skipped: lock recovery failed ($REASON)"
            return 1
        }
    fi

    echo "$$" > "$LOCK/pid"
    write_attr activate_mode 1 ||
        log_msg "WARNING: activate_mode write failed"

    RESULT=0

    case "$PATTERN" in
        snapchat) pattern_snapchat || RESULT=1 ;;
        default)  pattern_default || RESULT=1 ;;
        single)   pattern_single "$NOTIF_DURATION" || RESULT=1 ;;
        system)   pattern_single "$SYSTEM_DURATION" || RESULT=1 ;;
        call)     pattern_single "$CALL_DURATION" || RESULT=1 ;;
        alarm)    pattern_single "$ALARM_DURATION" || RESULT=1 ;;
        *)
            log_msg "ERROR: Unknown pattern: $PATTERN"
            RESULT=1
            ;;
    esac

    write_attr activate 0 || true
    rm -rf "$LOCK"

    if [ "$RESULT" -eq 0 ]; then
        log_msg "Vibration sent: event=$REASON pattern=$PATTERN"
    else
        log_msg "ERROR: Vibration failed: event=$REASON pattern=$PATTERN"
    fi

    return "$RESULT"
}

# Snapshot capturing package, key, and ongoing status
snapshot() {
    dumpsys notification --noredact 2>/dev/null |
        awk '
        /pkg=/ && /key=/ {
            line = $0
            pkg = ""
            key = ""
            ongoing = 0

            if (match(line, /pkg=[^ ]+/))
                pkg = substr(line, RSTART + 4, RLENGTH - 4)

            if (match(line, /key=[^ ]+/))
                key = substr(line, RSTART + 4, RLENGTH - 4)

            if (index(line, "ongoing=true") > 0 || index(line, "isOngoing=true") > 0 || index(line, "FLAG_ONGOING_EVENT") > 0)
                ongoing = 1

            if (pkg != "" && key != "")
                print pkg "|" key "|" ongoing
        }
        ' |
        sort -u
}

should_ignore_package() {
    PKG="$1"
    case "$PKG" in
        # Allowed com.android.shell so ADB tests work properly!
        com.google.android.gms*|com.miui.gallery*|com.google.android.as*|com.miui.securitycenter*|com.xiaomi.mi_connect_service*|me.piebridge.brevent*|android|com.android.providers.*|com.android.settings*)
            return 0
            ;;
        com.android.deskclock|com.google.android.deskclock)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

notification_pattern() {
    PACKAGE="$1"

    case "$PACKAGE" in
        com.snapchat.android)
            echo snapchat
            ;;
        com.facebook.orca|com.whatsapp|com.instagram.android|com.telegram.messenger)
            echo default
            ;;
        com.android.shell)
            echo default
            ;;
        *)
            echo default
            ;;
    esac
}

handle_notification() {
    KEY="$1"
    PACKAGE="$2"
    ONGOING="$3"

    if [ "$ONGOING" = "1" ]; then
        return 0
    fi

    if should_ignore_package "$PACKAGE"; then
        return 0
    fi

    PATTERN="$(notification_pattern "$PACKAGE")"

    log_msg "[INFO] notification received: package=$PACKAGE"
    vibrate "notification:$PACKAGE" "$PATTERN"
}

# Prevent duplicate bridge instances
if [ -r "$MAIN_PID" ]; then
    OLD_PID="$(cat "$MAIN_PID" 2>/dev/null)"

    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log_msg "Bridge already running: PID=$OLD_PID"
        exit 0
    fi
fi

echo "$$" > "$MAIN_PID"

cleanup() {
    for PIDFILE in "$NOTIF_PID_FILE" "$ALARM_LOOP_PID_FILE" "$CALL_LOOP_PID_FILE"; do
        if [ -r "$PIDFILE" ]; then
            CHILD_PID="$(cat "$PIDFILE" 2>/dev/null)"
            if [ -n "$CHILD_PID" ]; then
                kill "$CHILD_PID" 2>/dev/null || true
            fi
        fi
    done

    rm -f "$MAIN_PID" "$NOTIF_PID_FILE" "$ALARM_LOOP_PID_FILE" "$CALL_LOOP_PID_FILE"
    log_msg "Bridge stopped"
}

trap cleanup EXIT
trap 'exit 0' INT TERM

log_msg "Zircon AWINIC Vibration Bridge starting (v2.4.1)"

WAIT=0
while [ ! -d "$SYSFS_DIR" ] && [ "$WAIT" -lt 60 ]; do
    sleep 2
    WAIT=$((WAIT + 2))
done

if [ ! -d "$SYSFS_DIR" ]; then
    log_msg "ERROR: I2C device 0-005a not found"
    exit 1
fi

for ATTR in effect_id duration activate_mode activate; do
    if [ ! -e "$SYSFS_DIR/$ATTR" ]; then
        log_msg "ERROR: Required attribute missing: $ATTR"
        exit 1
    fi
done

[ -e "$DRIVER" ] ||
    log_msg "WARNING: AWINIC driver directory not found"

log_msg "Device detected: $SYSFS_DIR"

snapshot > "$OLD"
log_msg "Notification baseline captured"

# Notification watcher
(
    while true; do
        sleep "$POLL_SECONDS"
        snapshot > "$NEW"

        if [ ! -s "$NEW" ]; then
            continue
        fi

        comm -13 <(sort "$OLD") <(sort "$NEW") 2>/dev/null |
        while IFS='|' read -r PACKAGE KEY ONGOING; do
            [ -n "$PACKAGE" ] || continue
            [ -n "$KEY" ] || continue
            handle_notification "$KEY" "$PACKAGE" "${ONGOING:-0}"
        done

        cp "$NEW" "$OLD"
    done
) &

echo "$!" > "$NOTIF_PID_FILE"
log_msg "Notification watcher started: PID=$(cat "$NOTIF_PID_FILE")"

# Dedicated Alarm Monitor (Continuous repeating vibration UNTIL DISCARDED)
(
    ALARM_ACTIVE=0
    while true; do
        sleep 2
        IS_RINGING=0
        if dumpsys notification 2>/dev/null | grep -E "pkg=com\.(android|google)\.android\.deskclock" | grep -E "category=alarm|ongoing=true|isOngoing=true" >/dev/null; then
            IS_RINGING=1
        fi

        if [ "$IS_RINGING" -eq 1 ] && [ "$ALARM_ACTIVE" -eq 0 ]; then
            ALARM_ACTIVE=1
            log_msg "[INFO] alarm entered ringing state"
            (
                while true; do
                    log_msg "[INFO] alarm repeat scheduled"
                    vibrate "alarm" "alarm"
                    sleep "$ALARM_REPEAT_INTERVAL"
                done
            ) &
            echo "$!" > "$ALARM_LOOP_PID_FILE"
        elif [ "$IS_RINGING" -eq 0 ] && [ "$ALARM_ACTIVE" -eq 1 ]; then
            ALARM_ACTIVE=0
            if [ -r "$ALARM_LOOP_PID_FILE" ]; then
                kill "$(cat "$ALARM_LOOP_PID_FILE" 2>/dev/null)" 2>/dev/null || true
                rm -f "$ALARM_LOOP_PID_FILE"
            fi
            log_msg "[INFO] alarm dismissed; playback stopped"
        fi
    done
) &
echo "$!" > "$MODDIR/alarm_monitor.pid"
log_msg "Alarm monitor started"

# Dedicated Incoming Call Monitor (Continuous repeating vibration UNTIL ENDED)
(
    CALL_ACTIVE=0
    while true; do
        sleep 1
        CALL_RINGING=0
        if dumpsys telecom 2>/dev/null | grep -i "mCallState=RINGING" >/dev/null || dumpsys telephony.registry 2>/dev/null | grep -i "mCallState=1" >/dev/null; then
            CALL_RINGING=1
        fi

        if [ "$CALL_RINGING" -eq 1 ] && [ "$CALL_ACTIVE" -eq 0 ]; then
            CALL_ACTIVE=1
            log_msg "[INFO] incoming call detected"
            log_msg "[INFO] incoming-call pattern started"
            (
                while true; do
                    vibrate "incoming_call" "call"
                    sleep "$CALL_REPEAT_INTERVAL"
                done
            ) &
            echo "$!" > "$CALL_LOOP_PID_FILE"
        elif [ "$CALL_RINGING" -eq 0 ] && [ "$CALL_ACTIVE" -eq 1 ]; then
            CALL_ACTIVE=0
            if [ -r "$CALL_LOOP_PID_FILE" ]; then
                kill "$(cat "$CALL_LOOP_PID_FILE" 2>/dev/null)" 2>/dev/null || true
                rm -f "$CALL_LOOP_PID_FILE"
            fi
            log_msg "[INFO] call answered/ended; ringing pattern stopped"
        fi
    done
) &
echo "$!" > "$MODDIR/call_monitor.pid"
log_msg "Call monitor started"

wait
