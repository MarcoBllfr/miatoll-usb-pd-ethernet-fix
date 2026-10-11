#!/bin/sh
# Battery longevity guard for an always-plugged phone whose kernel
# offers NO charge control (no /sys/class/power_supply/battery, no
# charge_control_*, no charger driver — telemetry only).
#
# Strategy: switch the CHARGER's smart plug with hysteresis, polling
# battery capacity over SSH. Keeps a Li-Po away from a permanent 100%
# float, which is what kills cells left plugged in for months.
#
# Requirements on this machine: sh, ssh (key auth, BatchMode), curl.
# The phone side needs nothing except SSH + the qcom_qg gauge.
#
# ------------------------------- config ------------------------------------
PHONE_SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 -i $HOME/.ssh/redmi user@192.168.0.199"
PHONE_CAP_FILE="/sys/class/power_supply/qcom_qg/capacity"

# Plug backend: tasmota | shelly1 | shelly2 | command
PLUG_TYPE="tasmota"
PLUG_HOST="192.168.0.50"

# Only used when PLUG_TYPE=command. STATE_CMD must print exactly "on"/"off".
PLUG_ON_CMD=""
PLUG_OFF_CMD=""
PLUG_STATE_CMD=""

HIGH=80            # at/above: turn plug OFF
LOW=65             # at/below: turn plug ON
INTERVAL=300       # seconds between polls
WATCHDOG_FAILS=6   # consecutive unreadable polls before forcing plug ON
LOG="$HOME/battery-guard.log"
# -----------------------------------------------------------------------------

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"
}

plug_set() { # $1 = on|off
    case "$PLUG_TYPE" in
        tasmota) curl -s --max-time 10 "http://$PLUG_HOST/cm?cmnd=Power%20$1" >/dev/null ;;
        shelly1) curl -s --max-time 10 "http://$PLUG_HOST/relay/0?turn=$1" >/dev/null ;;
        shelly2)
            v="false"; [ "$1" = "on" ] && v="true"
            curl -s --max-time 10 "http://$PLUG_HOST/rpc/Switch.Set?id=0,on=$v" >/dev/null ;;
        command)
            if [ "$1" = "on" ]; then sh -c "$PLUG_ON_CMD"; else sh -c "$PLUG_OFF_CMD"; fi ;;
    esac
}

plug_state() {
    case "$PLUG_TYPE" in
        tasmota)
            out=$(curl -s --max-time 10 "http://$PLUG_HOST/cm?cmnd=Power")
            case "$out" in *ON*) echo on ;; *) echo off ;; esac ;;
        shelly1)
            out=$(curl -s --max-time 10 "http://$PLUG_HOST/relay/0")
            case "$out" in *'"ison":true'*) echo on ;; *) echo off ;; esac ;;
        shelly2)
            out=$(curl -s --max-time 10 "http://$PLUG_HOST/rpc/Switch.GetStatus?id=0")
            case "$out" in *'"output":true'*) echo on ;; *) echo off ;; esac ;;
        command) sh -c "$PLUG_STATE_CMD" ;;
    esac
}

[ -n "$PHONE_SSH" ] || { echo "set PHONE_SSH" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }

log "START high=$HIGH low=$LOW interval=${INTERVAL}s plug=$PLUG_TYPE@$PLUG_HOST"
fails=0
while true; do
    cap=$($PHONE_SSH "cat $PHONE_CAP_FILE" 2>/dev/null | tr -dc '0-9')
    if [ -z "$cap" ]; then
        fails=$((fails + 1))
        log "WARN unreadable capacity ($fails consecutive)"
        if [ "$fails" -ge "$WATCHDOG_FAILS" ]; then
            plug_set on
            log "ALERT watchdog: forced plug ON (phone may be unreachable/dead)"
        fi
        sleep "$INTERVAL"
        continue
    fi
    fails=0
    state=$(plug_state)
    action="-"
    if [ "$cap" -ge "$HIGH" ] && [ "$state" = "on" ]; then
        plug_set off; action="plug OFF"
    elif [ "$cap" -le "$LOW" ] && [ "$state" = "off" ]; then
        plug_set on; action="plug ON"
    fi
    log "cap=${cap}% plug=$state $action"
    sleep "$INTERVAL"
done
