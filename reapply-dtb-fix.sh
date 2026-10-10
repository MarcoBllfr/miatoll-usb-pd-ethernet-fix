#!/bin/sh
# Re-apply the USB-C dual-role/sink DTB fix after a kernel upgrade
# (upgrades overwrite /boot/dtbs and wipe the patched file).
#
# Target: Xiaomi miatoll/marco (SM7125, joyeuse/curtana) on postmarketOS,
# kernel package linux-postmarketos-qcom-sm7125.
# What it does: flips the pm6150 Type-C connector from power-role "source"
# to "dual" + try-power-role "sink" + 5V sink PDOs, so the phone can sink
# PD power while hosting USB devices (e.g. RTL8153 Ethernet + PD hub).
#
# Usage: ./reapply-dtb-fix.sh [dtb-name]
#   dtb-name defaults to sm7125-xiaomi-joyeuse-huaxing
#   (check yours via: tr < /proc/device-tree/compatible '\0' ' ')
# Requires: dtc, python3, sudo. Reboot afterwards and re-test.
set -e

DTB_NAME="${1:-sm7125-xiaomi-joyeuse-huaxing}"
DTB="/boot/dtbs/qcom/${DTB_NAME}.dtb"
WORK="/tmp/dtb-fix"

printf 'sudo password: '
stty -echo 2>/dev/null || true
read -r SUDO_PW
stty echo 2>/dev/null || true
echo
SUDO="printf '%s\n' \"$SUDO_PW\" | sudo -S"

command -v dtc >/dev/null || { echo "installing dtc..."; printf '%s\n' "$SUDO_PW" | sudo -S apk add dtc; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

mkdir -p "$WORK"
echo "[1/6] backup (keeps existing .bak if present)"
printf '%s\n' "$SUDO_PW" | sudo -S sh -c "test -f '${DTB}.bak' || cp '$DTB' '${DTB}.bak'"

echo "[2/6] decompile"
printf '%s\n' "$SUDO_PW" | sudo -S dtc -I dtb -O dts "$DTB" -o "$WORK/board-orig.dts" 2>"$WORK/dtc-decompile.log" || {
  echo "decompile failed:"; tail -n 5 "$WORK/dtc-decompile.log"; exit 1; }
printf '%s\n' "$SUDO_PW" | sudo -S chown "$(id -u):$(id -g)" "$WORK/board-orig.dts"

echo "[3/6] patch connector node"
python3 - "$WORK/board-orig.dts" "$WORK/board-new.dts" <<'EOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(keepends=True)
out, n_power, n_sink = [], 0, 0
for ln in lines:
    s = ln.strip()
    if s == 'power-role = "source";':
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(f'{indent}power-role = "dual";\n')
        n_power += 1
        continue
    if s == 'data-role = "dual";':
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(ln)
        out.append(f'{indent}try-power-role = "sink";\n')
        continue
    if s.startswith("source-pdos = <") and s.endswith(">;");
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(ln)
        # PDO_FIXED(5000mV, 3000mA, USB_COMM | DATA_SWAP) = 0x0601912c
        out.append(f"{indent}sink-pdos = <0x601912c>;\n")
        out.append(f"{indent}op-sink-microwatt = <15000000>;\n")
        n_sink += 1
        continue
    out.append(ln)
open(dst, "w").writelines(out)
print(f"patched power-role x{n_power}, sink-block x{n_sink}")
assert n_power == 1 and n_sink == 1, "anchors not found exactly once - aborting"
EOF

echo "[4/6] recompile (no piped head: SIGPIPE kills dtc)"
dtc -I dts -O dtb "$WORK/board-new.dts" -o "$WORK/board-new.dtb" >"$WORK/dtc-compile.log" 2>&1
echo "dtc done"

echo "[5/6] verify round-trip"
dtc -I dtb -O dts "$WORK/board-new.dtb" -o "$WORK/board-verify.dts" 2>/dev/null
grep -A6 'usb-c-connector' "$WORK/board-verify.dts" | head -n 8

echo "[6/6] deploy"
printf '%s\n' "$SUDO_PW" | sudo -S cp "$WORK/board-new.dtb" "$DTB"
echo "deployed. Make sure the loader entry loads it:"
echo "  grep devicetree /boot/loader/entries/pmos.conf"
echo "Then reboot, check: cat /sys/class/typec/port0/port_type  # want [dual]"
echo "Then plug PD charger into the hub and check power_role -> [sink]."
