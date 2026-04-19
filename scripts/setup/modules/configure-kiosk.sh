#!/bin/bash
# Module: Configure lightweight kiosk browser (Cage + Chromium on Wayland)
# Idempotent — creates kiosk user, sets up auto-login and systemd user service.
#
# Designed for RPi 3B: no desktop environment, minimal resource usage.
# Cage is a single-purpose Wayland compositor — no window decorations, no taskbar.
#
# Env vars:
#   KIOSK_URL  - URL to display in kiosk mode (e.g. https://home.example.com)
#   KIOSK_USER - System user to run the kiosk as (e.g. kiosk)

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env KIOSK_URL KIOSK_USER

echo "Configuring kiosk..."

# Install packages (idempotent — apt-get skips already installed)
apt-get install -y -qq cage chromium-browser > /dev/null

# Create kiosk user if it doesn't exist
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd --system --create-home --shell /usr/sbin/nologin "$KIOSK_USER"
    echo "Created user: $KIOSK_USER"
else
    echo "User $KIOSK_USER already exists"
fi

# Set up auto-login on tty1 via systemd getty override
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

# Create systemd user service for the kiosk
KIOSK_HOME=$(eval echo "~$KIOSK_USER")
SERVICE_DIR="$KIOSK_HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/kiosk.service"
DESIRED_SERVICE="[Unit]
Description=Kiosk Browser
After=graphical-session.target

[Service]
ExecStart=/usr/bin/cage --hide-cursor -- chromium-browser --kiosk --noerrdialogs --disable-infobars --autoplay-policy=no-user-gesture-required --disable-session-crashed-bubble ${KIOSK_URL}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target"

mkdir -p "$SERVICE_DIR"
if [ ! -f "$SERVICE_FILE" ] || [ "$DESIRED_SERVICE" != "$(cat "$SERVICE_FILE")" ]; then
    echo "$DESIRED_SERVICE" > "$SERVICE_FILE"
    chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
    echo "Kiosk service updated"
else
    echo "Kiosk service unchanged"
fi

# Enable lingering so user services start at boot without login
# Must happen before systemctl --user commands, which need /run/user/<uid>
loginctl enable-linger "$KIOSK_USER"
echo "Lingering enabled for $KIOSK_USER"

# Enable the user service
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$KIOSK_USER")" systemctl --user daemon-reload 2>/dev/null || true
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$KIOSK_USER")" systemctl --user enable kiosk.service 2>/dev/null || true

# Disable console blanking (screen saver)
if [ -f /sys/module/kernel/parameters/consoleblank ]; then
    current_blank=$(cat /sys/module/kernel/parameters/consoleblank)
    if [ "$current_blank" != "0" ]; then
        echo 0 > /sys/module/kernel/parameters/consoleblank
        echo "Console blanking disabled (runtime)"
    fi
fi

# Persist console blanking via kernel cmdline if not already set
CMDLINE_FILE="/boot/cmdline.txt"
if [ -f "$CMDLINE_FILE" ] && ! grep -q "consoleblank=0" "$CMDLINE_FILE"; then
    sed -i 's/$/ consoleblank=0/' "$CMDLINE_FILE"
    echo "Console blanking disabled (persistent via cmdline.txt)"
elif [ -f "$CMDLINE_FILE" ]; then
    echo "Console blanking already disabled in cmdline.txt"
fi

echo "Kiosk ready"
