#!/bin/bash
# ups-status-check.sh - Verify NUT telemetry and alert on UPS health changes.
#
# The check is read-only. It deliberately does not run upsmon or issue UPS
# commands, so it cannot initiate host or load shutdown.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")
export REPO_DIR

source "$REPO_DIR/scripts/lib.sh"
if [ "${HOMELAB_ENV_LOADED:-0}" != 1 ]; then
    source_env
fi

validate_env NUT_UPS_NAME

LOAD_WARNING_PERCENT="${UPS_LOAD_WARNING_PERCENT:-80}"
ON_BATTERY_DELAY_SECONDS="${UPS_ON_BATTERY_ALERT_DELAY_SECONDS:-30}"
COMM_FAILURE_DELAY_SECONDS="${UPS_COMM_FAILURE_ALERT_DELAY_SECONDS:-120}"
ALERT_REPEAT_HOURS="${UPS_ALERT_REPEAT_HOURS:-12}"
STATE_DIR="${UPS_ALERT_STATE_DIR:-/var/lib/homelab-ups-alerts}"

for value_name in LOAD_WARNING_PERCENT ON_BATTERY_DELAY_SECONDS COMM_FAILURE_DELAY_SECONDS ALERT_REPEAT_HOURS; do
    value="${!value_name}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $value_name must be a non-negative integer (got '$value')" >&2
        exit 1
    fi
done

mkdir -p "$STATE_DIR"
now=$(date +%s)
repeat_seconds=$(( ALERT_REPEAT_HOURS * 3600 ))
host=$(hostname)

send_notification() {
    local title="$1"
    local body="$2"
    local full="$title - $body"

    logger -t homelab-ups-alert "$full" 2>/dev/null || true
    echo "ALERT: $full"

    if [ -z "${HOMELAB_ALERT_SHOUTRRR_URL:-}" ]; then
        return 0
    fi
    if ! command -v shoutrrr &>/dev/null; then
        echo "WARNING: HOMELAB_ALERT_SHOUTRRR_URL is set but shoutrrr is unavailable" >&2
        return 1
    fi

    shoutrrr send --url "$HOMELAB_ALERT_SHOUTRRR_URL" \
        --title "homelab UPS" --message "$full"
}

condition_active() {
    local key="$1"
    local delay_seconds="$2"
    local title="$3"
    local body="$4"
    local since_file="$STATE_DIR/${key}.since"
    local alerted_file="$STATE_DIR/${key}.alerted"
    local since last_alert

    if [ ! -f "$since_file" ]; then
        echo "$now" > "$since_file"
    fi
    since=$(cat "$since_file" 2>/dev/null || echo "$now")
    [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
    if [ $(( now - since )) -lt "$delay_seconds" ]; then
        return 0
    fi

    last_alert=0
    if [ -f "$alerted_file" ]; then
        last_alert=$(cat "$alerted_file" 2>/dev/null || echo 0)
        [[ "$last_alert" =~ ^[0-9]+$ ]] || last_alert=0
    fi
    if [ "$last_alert" -ne 0 ] && [ "$repeat_seconds" -ne 0 ] \
        && [ $(( now - last_alert )) -lt "$repeat_seconds" ]; then
        return 0
    fi

    if send_notification "$title" "$body"; then
        echo "$now" > "$alerted_file"
    fi
}

condition_clear() {
    local key="$1"
    local title="$2"
    local body="$3"
    local since_file="$STATE_DIR/${key}.since"
    local alerted_file="$STATE_DIR/${key}.alerted"

    if [ ! -f "$since_file" ]; then
        return 0
    fi
    if [ ! -f "$alerted_file" ]; then
        rm -f "$since_file"
        return 0
    fi

    if send_notification "$title" "$body"; then
        rm -f "$since_file" "$alerted_file"
    fi
}

metric() {
    local key="$1"
    awk -v key="$key" 'index($0, key ": ") == 1 {
        print substr($0, length(key) + 3)
        exit
    }' <<< "$telemetry"
}

telemetry=""
if ! telemetry=$(upsc "${NUT_UPS_NAME}@localhost" 2>&1); then
    condition_active "communication" "$COMM_FAILURE_DELAY_SECONDS" \
        "$host UPS telemetry unavailable" \
        "NUT could not read ${NUT_UPS_NAME}: ${telemetry//$'\n'/ }"
    echo "ERROR: NUT telemetry unavailable: $telemetry" >&2
    exit 1
fi

status=$(metric "ups.status")
load=$(metric "ups.load")
charge=$(metric "battery.charge")
runtime=$(metric "battery.runtime")
alarm=$(metric "ups.alarm")

summary="status=${status:-missing}, load=${load:-missing}%, charge=${charge:-missing}%, runtime=${runtime:-missing}s"
condition_clear "communication" "$host UPS telemetry restored" "$summary"

missing=()
[ -n "$status" ] || missing+=("ups.status")
[ -n "$load" ] || missing+=("ups.load")
[ -n "$charge" ] || missing+=("battery.charge")
[ -n "$runtime" ] || missing+=("battery.runtime")
if [ "${#missing[@]}" -gt 0 ]; then
    missing_list=$(IFS=", "; echo "${missing[*]}")
    condition_active "telemetry-missing" 0 \
        "$host UPS telemetry incomplete" \
        "NUT is missing required fields: ${missing_list}. ${summary}"
    echo "ERROR: NUT telemetry missing required fields: $missing_list" >&2
    exit 1
fi
condition_clear "telemetry-missing" "$host UPS telemetry complete" "$summary"

if ! [[ "$load" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    condition_active "load-invalid" 0 \
        "$host UPS load is invalid" "NUT reported ups.load='$load'. ${summary}"
else
    condition_clear "load-invalid" "$host UPS load reporting restored" "$summary"
    if awk -v metric_value="$load" -v threshold="$LOAD_WARNING_PERCENT" \
        'BEGIN { exit !(metric_value + 0 >= threshold + 0) }'; then
        condition_active "load-warning" 0 \
            "$host UPS load is ${load}%" \
            "Configured warning threshold is ${LOAD_WARNING_PERCENT}%. ${summary}"
    else
        condition_clear "load-warning" "$host UPS load recovered" "$summary"
    fi
fi

if [[ " $status " == *" OB "* ]]; then
    condition_active "on-battery" "$ON_BATTERY_DELAY_SECONDS" \
        "$host UPS is on battery" "$summary"
else
    condition_clear "on-battery" "$host UPS returned to line power" "$summary"
fi

unhealthy_tokens=()
for token in LB RB FSD OFF BYPASS OVER ALARM; do
    if [[ " $status " == *" $token "* ]]; then
        unhealthy_tokens+=("$token")
    fi
done
if [ "${#unhealthy_tokens[@]}" -gt 0 ]; then
    token_list=$(IFS=", "; echo "${unhealthy_tokens[*]}")
    alarm_detail=""
    [ -z "$alarm" ] || alarm_detail=" alarm=${alarm}"
    condition_active "unhealthy-status" 0 \
        "$host UPS reports an unhealthy state" \
        "Status flags: ${token_list}.${alarm_detail} ${summary}"
else
    condition_clear "unhealthy-status" "$host UPS health recovered" "$summary"
fi

if [[ " $status " != *" OL "* ]] && [[ " $status " != *" OB "* ]]; then
    condition_active "power-state-unknown" 0 \
        "$host UPS power state is unknown" "$summary"
else
    condition_clear "power-state-unknown" "$host UPS power state recovered" "$summary"
fi

echo "UPS ${NUT_UPS_NAME}: $summary"
