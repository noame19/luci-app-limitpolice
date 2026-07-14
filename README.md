# luci-app-limitpolice

Lightweight OpenWrt LuCI app for **per-device ingress bandwidth policing** using
`tc filter ... police rate`. Runs on weak CPUs and stays compatible with
hardware **Flow Offloading**, **fullcon** NAT and **BBR** — unlike SQM/Cake/fq_codel.

- **Kernel mechanism**: `sch_ingress` + `act_police` + `cls_u32` (or `cls_flower` on newer kernels)
- **No IFB**, **no HTB**, **no fq_codel**, **no Cake** — these are exactly what breaks Flow Offload
- **Compatibility**: OpenWrt 18.06 (kernel 4.14) → 24.10
- **Distribution**: prebuilt `.ipk` (opkg) or build via OpenWrt SDK
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

Download the matching `.ipk` from the [Releases](../../releases) page, then:

```bash
opkg update
opkg install luci-app-limitpolice_*.ipk
```

### Build from source (OpenWrt SDK)

```bash
git clone https://github.com/yourname/luci-app-limitpolice.git
cd luci-app-limitpolice
cp -r . /path/to/openwrt-sdk/package/luci-app-limitpolice/
make package/luci-app-limitpolice/compile V=s
```

## Kernel module dependencies

The app pulls these automatically. Make sure they are available on the target
or `opkg install` them first:

| Module | Package | Purpose |
|---|---|---|
| `sch_ingress` | `kmod-sched-core` | ingress qdisc (always built-in on OpenWrt) |
| `act_police` | `kmod-sched-act-police` | the police action |
| `cls_u32` | `kmod-sched-core` | U32 classifier (kernel 4.14 default) |
| `cls_flower` | `kmod-sched-flower` | Flower classifier (kernel ≥4.16) |

## Quick start (CLI)

```bash
# total ingress cap of 10 Mbps on br-lan (all traffic)
uci add limitpolice rule
uci set limitpolice.@rule[-1].interface='br-lan'
uci set limitpolice.@rule[-1].target='0.0.0.0/0'
uci set limitpolice.@rule[-1].direction='dst'
uci set limitpolice.@rule[-1].rate='10'
uci set limitpolice.@rule[-1].unit='Mbps'
uci set limitpolice.@rule[-1].enabled='1'
uci commit limitpolice
/etc/init.d/limitpolice enable
/etc/init.d/limitpolice start
```

Inspect with:

```bash
tc -s filter show dev br-lan parent ffff:
```

## License

MIT
