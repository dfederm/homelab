#!/bin/bash
# Module: Configure lightweight kiosk browser (Cage + Chromium on Wayland)
# Idempotent — creates kiosk user, sets up tty1 autologin, launches cage from
# the kiosk user's interactive shell, and applies display rotation via wlr-randr.
#
# Designed for a Raspberry Pi running Raspberry Pi OS (Bookworm or later) with a
# DSI panel on the vc4-kms-v3d KMS driver. No desktop environment.
#
# Launch model:
#   getty@tty1 → agetty autologin → login → bash → ~/.bash_profile execs cage.
#   Cage inherits the seat0 session that pam_systemd attached to the autologin,
#   which is what libseat needs to claim DRM master. Crash recovery is automatic:
#   if cage exits, bash exits, and agetty respawns to retry.
#
# Env vars:
#   KIOSK_URL         - URL to display in kiosk mode (e.g. https://home.example.com)
#   KIOSK_USER        - System user to run the kiosk as (e.g. kiosk)
#   DISPLAY_ROTATION  - Optional. Screen rotation in degrees: 0, 90, 180, or 270.
#                       Defaults to 0 (no rotation). Applied at compositor level
#                       via wlr-randr after cage starts, and to the touchscreen
#                       input via a libinput calibration matrix written as a
#                       udev rule. (Wayland compositors ignore firmware-level
#                       rotation knobs under vc4-kms-v3d; wlr-randr is what
#                       actually works.)

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env KIOSK_URL KIOSK_USER

DISPLAY_ROTATION="${DISPLAY_ROTATION:-0}"

case "$DISPLAY_ROTATION" in
    0|90|180|270) ;;
    *)
        echo "ERROR: DISPLAY_ROTATION must be 0, 90, 180, or 270 (got: $DISPLAY_ROTATION)" >&2
        exit 1
        ;;
esac

echo "Configuring kiosk..."

apt-get install -y -qq cage chromium wlr-randr wlrctl > /dev/null

# Kiosk user — shell must be /bin/bash (not nologin) so autologin establishes a
# real seat0 session for cage to inherit.
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd --system --create-home --shell /bin/bash "$KIOSK_USER"
    echo "Created user: $KIOSK_USER"
else
    echo "User $KIOSK_USER already exists"
fi

# Autologin override for getty@tty1.
GETTY_DIR="/etc/systemd/system/getty@tty1.service.d"
GETTY_OVERRIDE="$GETTY_DIR/autologin.conf"
DESIRED_GETTY="[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM"

mkdir -p "$GETTY_DIR"
if [ ! -f "$GETTY_OVERRIDE" ] || [ "$DESIRED_GETTY" != "$(cat "$GETTY_OVERRIDE")" ]; then
    echo "$DESIRED_GETTY" > "$GETTY_OVERRIDE"
    systemctl daemon-reload
    echo "Auto-login configured for $KIOSK_USER on tty1"
else
    echo "Auto-login already configured"
fi

# Kiosk user's .bash_profile: launch cage only when on tty1, so SSH or other
# consoles into the kiosk user still get an ordinary shell.
KIOSK_HOME=$(eval echo "~$KIOSK_USER")
PROFILE_FILE="$KIOSK_HOME/.bash_profile"
DESIRED_PROFILE='# Managed by configure-pi-kiosk.sh - DO NOT EDIT
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec /usr/bin/cage -- /usr/local/bin/kiosk-session.sh
fi'

if [ ! -f "$PROFILE_FILE" ] || [ "$DESIRED_PROFILE" != "$(cat "$PROFILE_FILE")" ]; then
    echo "$DESIRED_PROFILE" > "$PROFILE_FILE"
    chown "$KIOSK_USER:$KIOSK_USER" "$PROFILE_FILE"
    echo "Kiosk .bash_profile updated"
else
    echo "Kiosk .bash_profile unchanged"
fi

# In-cage session script: cage exec's this, the script sets the Wayland output
# transform, parks the cursor off-screen (cage 0.2.0 has no hide-cursor flag, and
# the only input is a touchscreen so the cursor never gets moved back), then
# exec's chromium. The for-loop tolerates the brief window before cage's
# compositor accepts wlr-randr connections.
SESSION_SCRIPT="/usr/local/bin/kiosk-session.sh"
DESIRED_SESSION="#!/bin/bash
# Managed by configure-pi-kiosk.sh - DO NOT EDIT
set -e
for i in 1 2 3 4 5; do
    if /usr/bin/wlr-randr --output DSI-1 --transform $DISPLAY_ROTATION 2>/dev/null; then
        break
    fi
    sleep 0.5
done
# Park cursor off-screen. No real mouse means it stays parked.
/usr/bin/wlrctl pointer move 10000 10000 2>/dev/null || true
exec /usr/bin/chromium \\
    --kiosk \\
    --noerrdialogs \\
    --disable-infobars \\
    --autoplay-policy=no-user-gesture-required \\
    --disable-session-crashed-bubble \\
    \"$KIOSK_URL\""

if [ ! -f "$SESSION_SCRIPT" ] || [ "$DESIRED_SESSION" != "$(cat "$SESSION_SCRIPT")" ]; then
    echo "$DESIRED_SESSION" > "$SESSION_SCRIPT"
    chmod +x "$SESSION_SCRIPT"
    echo "Kiosk session script updated"
else
    echo "Kiosk session script unchanged"
fi

# Touchscreen rotation calibration matrix. wlr-randr only rotates the display
# output; the touchscreen continues reporting native panel coordinates. Apply a
# libinput calibration matrix via udev so touch lines up with the rotated display.
TOUCH_RULE="/etc/udev/rules.d/70-touchscreen-rotation.rules"
case "$DISPLAY_ROTATION" in
    0)   TOUCH_MATRIX="" ;;
    90)  TOUCH_MATRIX="0 -1 1 1 0 0" ;;
    180) TOUCH_MATRIX="-1 0 1 0 -1 1" ;;
    270) TOUCH_MATRIX="0 1 0 -1 0 1" ;;
esac

if [ -z "$TOUCH_MATRIX" ]; then
    if [ -f "$TOUCH_RULE" ]; then
        rm -f "$TOUCH_RULE"
        udevadm control --reload
        udevadm trigger --subsystem-match=input --action=change
        echo "Removed touchscreen rotation udev rule"
    fi
else
    DESIRED_TOUCH_RULE="# Managed by configure-pi-kiosk.sh - DO NOT EDIT
# ${DISPLAY_ROTATION}-degree touchscreen rotation calibration matrix.
ACTION==\"add|change\", SUBSYSTEM==\"input\", KERNEL==\"event*\", ENV{ID_INPUT_TOUCHSCREEN}==\"1\", ENV{LIBINPUT_CALIBRATION_MATRIX}=\"$TOUCH_MATRIX\""
    if [ ! -f "$TOUCH_RULE" ] || [ "$DESIRED_TOUCH_RULE" != "$(cat "$TOUCH_RULE")" ]; then
        echo "$DESIRED_TOUCH_RULE" > "$TOUCH_RULE"
        udevadm control --reload
        udevadm trigger --subsystem-match=input --action=change
        echo "Touchscreen rotation udev rule updated"
    else
        echo "Touchscreen rotation udev rule unchanged"
    fi
fi

# Disable console blanking at runtime.
if [ -f /sys/module/kernel/parameters/consoleblank ]; then
    current_blank=$(cat /sys/module/kernel/parameters/consoleblank)
    if [ "$current_blank" != "0" ]; then
        echo 0 > /sys/module/kernel/parameters/consoleblank
        echo "Console blanking disabled (runtime)"
    fi
fi

# Persist console-blank-disable in cmdline.txt.
# On Trixie/Bookworm Pi images, the active path is /boot/firmware/cmdline.txt.
CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE_FILE" ] && ! grep -q "consoleblank=0" "$CMDLINE_FILE"; then
    current=$(tr -d '\n' < "$CMDLINE_FILE")
    printf "%s consoleblank=0\n" "$current" > "$CMDLINE_FILE"
    echo "Added consoleblank=0 to $CMDLINE_FILE"
fi

echo "Kiosk ready"
