#!/bin/bash
# Module: Configure Raspberry Pi firmware settings (/boot/firmware/config.txt)
# Idempotent — manages individual lines in config.txt by key.
#
# Currently handles:
#   DISPLAY_ROTATION  - Rotation in degrees: 0, 90, 180, or 270.
#                       Maps to display_lcd_rotate values 0/1/2/3.
#                       Firmware-level setting (read by GPU bootloader before kernel) —
#                       affects boot console, kernel framebuffer, KMS DSI output, and
#                       touch input. Reboot required to take effect.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"
validate_env DISPLAY_ROTATION

CONFIG_TXT="/boot/firmware/config.txt"

case "$DISPLAY_ROTATION" in
    0)   ROTATE=0 ;;
    90)  ROTATE=1 ;;
    180) ROTATE=2 ;;
    270) ROTATE=3 ;;
    *)
        echo "ERROR: DISPLAY_ROTATION must be 0, 90, 180, or 270 (got: $DISPLAY_ROTATION)" >&2
        exit 1
        ;;
esac

DESIRED_LINE="display_lcd_rotate=$ROTATE"

echo "Configuring display rotation ($DISPLAY_ROTATION degrees)..."

if grep -qE '^display_lcd_rotate=' "$CONFIG_TXT"; then
    CURRENT=$(grep -E '^display_lcd_rotate=' "$CONFIG_TXT")
    if [ "$CURRENT" = "$DESIRED_LINE" ]; then
        echo "Already set: $CURRENT"
    else
        sed -i "s|^display_lcd_rotate=.*|$DESIRED_LINE|" "$CONFIG_TXT"
        echo "Updated: $CURRENT -> $DESIRED_LINE"
        echo "REBOOT REQUIRED for rotation to take effect"
    fi
else
    echo "$DESIRED_LINE" >> "$CONFIG_TXT"
    echo "Added: $DESIRED_LINE"
    echo "REBOOT REQUIRED for rotation to take effect"
fi

echo "Display rotation configured"
