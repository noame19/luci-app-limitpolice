# luci-app-limitpolice

Lightweight OpenWrt LuCI app for **per-device ingress bandwidth policing** using
`tc filter ... police rate`. Runs on weak CPUs and stays compatible with
hardware **Flow Offloading**, **fullcon** NAT and **BBR** — unlike SQM/Cake/fq_codel.

- **Kernel mechanism**: `sch_ingress` + `act_police` + `cls_u32` (or `cls_flower` on newer kernels)
- **No IFB**, **no HTB**, **no fq_codel**, **no Cake** — these are exactly what breaks Flow Offload
- **Compatibility**: OpenWrt 18.06 (kernel 4.14) → 24.10
- **Distribution**: prebuilt `.ipk` (opkg) or build via OpenWrt SDK / GitHub Actions
- **UI**: LuCI CBI, modern minimal style, reads `/tmp/dhcp.leases` for hostname/IP/MAC dropdown

## Why `tc ingress police`?

```
        ┌──────────────────────────────────────────────┐
packet→ │ NIC driver → tc ingress qdisc → netfilter    │ → conntrack → NAT → offload
        └──────────────────────────────────────────────┘
                            ↑
              police decision made HERE
```

The `police` action drops over-quota packets **before** they hit conntrack,
NAT, or any AQM. Through-traffic preserves its 5-tuple, so the hardware flow
offload engine stays engaged. CPU cost ≈ a token bucket check — negligible on
mt7621 / ipq40xx / anything with <1 GHz single core.

Any scheme that involves IFB / HTB / fq_codel / Cake diverts traffic into
software queues and **breaks hardware offload**. SQM is the right answer when
you want AQM (bufferbloat mitigation); this app is the right answer when you
just want a cap.

## Install

### Prebuilt `.ipk` (easiest)

Each release ships **one `.ipk` per CPU architecture**. The package itself is
arch-independent (`PKGARCH:=all` — only Lua + shell inside), so any single
`.ipk` works on **every supported OpenWrt release** (18.06 → 24.10) as long
as the arch tag matches your router. Opkg pulls the right per-arch kmods
(`kmod-sched-act-police`, …) automatically.

| Arch | Routers |
|---|---|
| `x86_64` | Generic x86_64 / soft-router / VM (e.g. `armvirt-64` with EFI) |
| `mipsel_24kc` | MediaTek MT7621 / MT7628 / RT305x (ramips), classic weak-CPU targets |
| `aarch64_cortex-a53` | MediaTek Filogic (MT7981/86/88), `armvirt-64` A53 builds |

Pick the `.ipk` matching **your router's CPU**, then:

```bash
opkg update
opkg install luci-app-limitpolice_*.ipk
```

If opkg complains about missing kernel modules on a very minimal build:

```bash
opkg install kmod-sched-act-police kmod-sched-core kmod-sched-flower
opkg install luci-app-limitpolice_*.ipk
```

### Build with GitHub Actions (no local toolchain)

1. Fork this repo.
2. Go to **Actions → Build IPK → Run workflow**.
3. Wait ~10 min, download the artifact matching your arch under
   *Summary → Artifacts*.

### Build from source (OpenWrt SDK)

```bash
git clone https://github.com/yourname/luci-app-limitpolice.git
cd luci-app-limitpolice
cp -r . /path/to/openwrt-sdk/package/luci-app-limitpolice/
cd /path/to/openwrt-sdk
./scripts/feeds update -a
./scripts/feeds install -a
echo "CONFIG_PACKAGE_luci-app-limitpolice=m" >> .config
make defconfig
make package/luci-app-limitpolice/compile V=s
# Output: bin/packages/<your-arch>/luci-app-limitpolice_*.ipk
```

The Makefile declares `LUCI_PKGARCH:=all`, so the resulting `.ipk` is
installable on any of the supported OpenWrt releases.

## Kernel module dependencies

The init script auto-`modprobe`s these; Makefile declares them as
`LUCI_DEPENDS`. Opkg pulls the **per-arch** matching kmod at install time —
you do **not** compile any kernel module yourself.

| Module | Package | Purpose |
|---|---|---|
| `sch_ingress` | `kmod-sched-core` | ingress qdisc (always built-in on OpenWrt) |
| `act_police` | `kmod-sched-act-police` | the police action |
| `cls_u32` | `kmod-sched-core` | U32 classifier (kernel 4.14 default) |
| `cls_flower` | `kmod-sched-flower` | Flower classifier (kernel ≥4.16, optional) |

## Quick start (CLI)

```bash
# cap a single device (iphone-15, 192.168.1.105) downlink at 5 Mbps
uci add limitpolice rule
uci set limitpolice.@rule[-1].enabled='1'
uci set limitpolice.@rule[-1].interface='br-lan'
uci set limitpolice.@rule[-1].target_type='ip'
uci set limitpolice.@rule[-1].target='192.168.1.105/32'
uci set limitpolice.@rule[-1].direction='dst'
uci set limitpolice.@rule[-1].rate='5'
uci set limitpolice.@rule[-1].unit='Mbps'
uci set limitpolice.@rule[-1].comment='iphone-15'
uci commit limitpolice
/etc/init.d/limitpolice enable
/etc/init.d/limitpolice start

# inspect
tc -s filter show dev br-lan parent ffff:
```

The LuCI UI provides the same workflow via *Network → Limit Police*.

## License

MIT