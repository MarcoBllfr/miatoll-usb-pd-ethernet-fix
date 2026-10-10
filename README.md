# USB-C PD charging + USB Ethernet at the same time on Xiaomi miatoll (SM7125)

Makes a Xiaomi Redmi Note 9 Pro / 9S (miatoll family: joyeuse/curtana, SM7125)
running postmarketOS sink USB-C PD power **while** hosting a USB Ethernet
dongle — e.g. an Esiposs 2-in-1 USB-C hub (Realtek RTL8153) with a PD charger
attached. Before this fix, plugging PD power killed the USB host bus and
rebooted the phone.

Tested on: `Xiaomi Redmi Note 9 Pro (Global, Huaxing)` = `xiaomi,joyeuse`,
kernel `6.14.7-sm7125` (`linux-postmarketos-qcom-sm7125-6.14.7-r2`).

## TL;DR

The port's Type-C connector node is declared `power-role = "source"` in
`sm7125-xiaomi-common.dtsi`, so mainline TCPM can never negotiate sink.
Patch it to `dual` + `try-power-role = "sink"` + 5V sink PDOs, rebuild just
the DTB (no kernel rebuild), and load it via a systemd-boot `devicetree`
override. Result: PD 5V/2A sink + USB host concurrently, battery charges
while Ethernet stays up.

## Hardware / software

| Item | Detail |
|---|---|
| Phone | Xiaomi Redmi Note 9 Pro Global (joyeuse, Huaxing panel), SM7125 |
| OS / kernel | postmarketOS edge (Nura), `6.14.7-sm7125` |
| Ethernet | `0bda:8153` Realtek RTL8153, in-tree `r8152 v1.12.13`, fw `rtl8153b-2` |
| Hub | Esiposs USB-C 2-in-1 Ethernet + 100W PD passthrough |
| Chargers tried | Xiaomi 33W QC (USB-A) + A-to-C 18W cable (invalid for PD); proper USB-C PD charger + C-to-C cable |

## Symptoms

1. **Ethernet only (no charger): works.** `r8152 eth0 v1.12.13`, `carrier on`,
   DHCP `192.168.0.x`, ping `~1.5ms`, stable. Firmware
   `linux-firmware-rtl_nic` was initially missing and had to be installed.
2. **PD charger (dumb A-to-C/QC brick) + Ethernet: kernel Oops + reboot.**
   `xhci-hcd remove` → `r8152` disconnect → `ip` (rtnetlink dump) dereferences
   freed memory → `Internal error: Oops`. See [`logs/oops-crash.log`](logs/oops-crash.log)
   (role-flap) and [`logs/oops-trace.log`](logs/oops-trace.log) (the Oops:
   `__pi_strlen` ← `nla_put_string` ← `rtnl_fill_ifinfo`, `Comm: ip`,
   fault address holding ASCII `b_interf…`, classic use-after-free during
   concurrent `unregister_netdev`).
3. **PD charger (proper C-to-C PD) + Ethernet, before fix: endless
   connect/disconnect loop, no charging.** `port_type=[source]`,
   `power_role=[source]`, `tcpm online=0`. The hub retries PD forever,
   power-cycling VBUS every ~2–3s. Same hub+charger works on stock Android,
   so this is a mainline port gap, not broken hardware.

## Root cause

`arch/arm64/boot/dts/qcom/sm7125-xiaomi-common.dtsi` declares:

```dts
connector {
	compatible = "usb-c-connector";
	power-role = "source";      /* <-- phone can never sink */
	data-role = "dual";
	self-powered;
	source-pdos = <PDO_FIXED(5000, 3000, PDO_FIXED_DUAL_ROLE |
			PDO_FIXED_USB_COMM | PDO_FIXED_DATA_SWAP)>;
	...
};
```

So `/sys/class/typec/port0` shows `port_type=[source]`, `power_role=[source]`.
Plugging a PD source forces a role conflict → xHCI teardown → (sometimes)
the rtnetlink UAF above. Related: the port ships no charger/battery-manager
stack (`/sys/class/power_supply` has only `qcom_qg` gauge + `tcpm-source`;
`CONFIG_BATTERY_QCOM_BATTMGR` is off and no PM6150 charger driver exists
upstream in 6.14), which is also why battery `status` reads `Unknown`.
The PMIC still charges autonomously once a sink contract is negotiated —
gauge current goes negative and capacity climbs.

Precedent: Fairphone 4 (same PMIC family) documents the same limitation in
its DTS and disables PD for now. Here we keep PD but allow 5V-only sink,
which is enough for phone + hub + dongle.

## The fix

[`sm7125-xiaomi-connector-dual-sink.patch`](sm7125-xiaomi-connector-dual-sink.patch):

```diff
-		power-role = "source";
+		power-role = "dual";
 		data-role = "dual";
+		try-power-role = "sink";
 		self-powered;
 		source-pdos = <PDO_FIXED(5000, 3000, PDO_FIXED_DUAL_ROLE |
 				PDO_FIXED_USB_COMM | PDO_FIXED_DATA_SWAP)>;
+		sink-pdos = <PDO_FIXED(5000, 3000, PDO_FIXED_USB_COMM |
+				PDO_FIXED_DATA_SWAP)>;
+		op-sink-microwatt = <15000000>;
```

5V-only sink PDOs on purpose: no high-voltage negotiation against a
charger stack the OS can't supervise.

## Deployment notes (the non-obvious parts)

- `/boot/dtbs/*.dtb` is **ignored** at boot: Das U-Boot (EFI) supplies its own
  FDT to systemd-boot → kernel. Verified: patched file deployed, live tree
  still `source`.
- systemd-boot **`devicetree` override works**: append to the default entry:
  `devicetree /dtbs/qcom/sm7125-xiaomi-joyeuse-huaxing.dtb`
  (adjust the filename to your panel: check `tr < /proc/device-tree/compatible '\0' ' '`).
- `bootctl set-oneshot` does **not** survive reboot here (U-Boot EFI vars are
  volatile; also pass the entry ID *without* `.conf`). Edit the default
  `pmos.conf` directly instead — keep WiFi/SSH up as your recovery channel.
- No kernel rebuild needed: only the DTB changes. Recompile from decompiled
  DTB with `dtc`, or build `dtbs` from source. Never pipe dtc's stderr
  through `head` (SIGPIPE kills it before writing output).
- Re-apply after every kernel upgrade (it overwrites `/boot/dtbs`):
  [`reapply-dtb-fix.sh`](reapply-dtb-fix.sh) automates backup → decompile →
  patch → recompile → verify → deploy.

## Verification (after fix + PD charger plugged into hub)

```
data_role=[host] device
power_role=source [sink]
port_type=[dual] source sink
power_operation_mode=usb_power_delivery
tcpm_online=1  voltage_now=5000000  current 2000000  usb_type=C [PD]
qg_current_now=-474853 (negative = charging)  capacity 42% -> 85%
eth0 UP 192.168.0.200, ping gateway 3/3 ~1.5ms
```

One `xhci` re-enumeration happens at PD plug (expected role negotiation),
then zero flaps over 5+ minutes and no Oops. Full snapshots:
[`logs/success-state.txt`](logs/success-state.txt),
[`logs/pd-renegotiation-ok.log`](logs/pd-renegotiation-ok.log).

## Charger matrix (all with patch applied, C-to-C unless noted)

| Supply | Result |
|---|---|
| Higher-wattage PD charger + C-to-C | Stable 5V/2A sink + host, 5+ min, battery 42% → 85% |
| 100W laptop PD charger + C-to-C | Stable 5V/2A sink + host, `eth0` + DHCP, ping clean |
| 20W PD (5V/3A, 9V/2.22A, 12V/1.67A) + C-to-C | Sink/source oscillation ~15s period, USB re-enumeration each cycle, then crash (reproduced, watched live) |
| Xiaomi 33W QC brick (USB-A) + A-to-C 18W | No PD possible (no CC lines); brown-outs, flap loop, Oops |
| No charger (battery) | Stable host, drains battery |

Rule of thumb: this phone + hub + RTL8153 + display wants a 30W-class
or better PD supply; 20W sags and the hub power-cycles VBUS.

## Operational rule: never boot with PD attached, always hot-plug

Booting with hub + PD charger connected triggers a *different*, boot-time
crash: NULL dereference in the `sock_ioctl` path (~12s into boot,
`arm64_sys_ioctl` ← `invoke_syscall`, faulting insn `(f940014a)` —
register-offset load, i.e. another freed-pointer deref during USB churn
while drivers are still probing). Photographed on-device console;
importantly the system survives it and keeps booting (modem, WiFi all come
up). Same root pattern as the rtnetlink UAFs: userspace touching network
sockets/devices mid-teardown. Three `rtnl` instances + one `ioctl`
instance now documented (`logs/oops-trace*.log` + photo record).
Procedure: boot with Ethernet-only (or nothing), wait for settled boot,
*then* plug the PD charger. Hot-plug negotiation is a single clean cycle.

## Upstream follow-ups

1. Send the DTS patch to `sm7125-mainline/linux` (+ pmaports) so it survives
   kernel updates. Iteration candidates if sink misbehaves on other boards:
   drop `self-powered`, or go FP4-style (`pd-disable` + legacy 5V).
2. The `rtnl_fill_ifinfo` UAF on surprise USB-net removal is a real (latent)
   upstream bug independent of this fix — see `logs/oops-trace.log`
   (6.14.7, `r8152` + `xhci` teardown raced with `Comm: ip` rtnetlink dump).
