# luci-app-limitpolice

> Lightweight OpenWrt LuCI app for per-device bandwidth policing via
> `tc ingress police`. Stays compatible with hardware **Flow Offloading**,
> **fullcon** NAT, and **BBR** — unlike SQM/Cake/fq_codel, which all break
> hardware acceleration by diverting traffic into software queues.

**[中文](README.md)**

---

## Three features in one tiny package

| # | Feature | Trigger | Background process |
|---|---|---|---|
| 1 | **Real-time rate limit**: cap downlink / uplink per device (IP or MAC) | LuCI Save & Apply | ❌ (procd reload) |
| 2 | **Daily quota**: cumulative bytes over cap → punitive 1 kbit block | cron every 5 min | ❌ (cron) |
| 3 | **Traffic report**: per-device today / week / month up/down | cron aggregates + LuCI renders on demand | ❌ (cron + scratch file) |

All three reuse the same `tc u32 + police` counter machinery. No
nftables / conntrack dependency is added. When the report tab is not
open, the plugin costs exactly **zero memory and zero CPU**.

## Why `tc ingress police`?

```
        ┌──────────────────────────────────────────────┐
packet→ │ NIC driver → tc ingress qdisc → netfilter    │ → conntrack → NAT → offload
        └──────────────────────────────────────────────┘
                            ↑
              police decision made HERE
```

The `police` action drops over-quota packets **before** they hit
conntrack, NAT, or any AQM. Through-traffic preserves its 5-tuple, so
the hardware flow offload engine stays engaged. CPU cost ≈ a token
bucket check — negligible on mt7621 / ipq40xx / anything below 1 GHz.

Any scheme involving IFB / HTB / fq_codel / Cake diverts traffic into
software queues and **breaks hardware offload**. SQM is the right answer
when you want AQM (bufferbloat mitigation); this app is the right answer
when you just want a cap.

## Architecture

### Three data flows + five components

```
┌──────────────────────────────────────────────────────────────────────────┐
│ User                                                                     │
├──────────────────────────────────────────────────────────────────────────┤
│ LuCI main form (CBI)           │ LuCI report (template render, on-demand)│
│ Network → Limit Police         │ Network → Limit Police → Traffic Report │
└────────────┬────────────────────┴──────────────────┬────────────────────┘
             │ UCI /etc/config/limitpolice           │ read /tmp + /var/run
             ▼                                       ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ /etc/init.d/limitpolice  (procd-managed; no custom daemon)                │
│   start_service: load_modules + apply_rule (user rules) + install_cron   │
│   stop_service:  remove_cron  + clear_all_rules (wipe 100-199, 9000-9999)│
│   reload_service: stop + start (triggered automatically by UCI change)   │
├──────────────────────────────────────────────────────────────────────────┤
│ busybox crond                                                            │
│   */5 * * * *   limitpolice-quota-check    ← quota + stats sync          │
│   3 0 * * *     limitpolice-stats-clear daily                            │
│   2 0 * * 1     limitpolice-stats-clear weekly                           │
│   1 0 1 * *     limitpolice-stats-clear monthly                          │
│   0 0 * * *     limitpolice-quota-reset   (clear SNAP + restart service) │
├──────────────────────────────────────────────────────────────────────────┤
│ /usr/sbin/limitpolice-quota-check                                         │
│   1. read /tmp/dhcp.leases → build ip↔mac cache (→ /tmp/limitpolice.leases)│
│   2. lazy stats filters: prio 9000+ band, 2 slots per active IP (dst/src) │
│   3. parse tc -s filter show → accumulate /tmp/limitpolice/stats/<MAC>   │
│   4. parse /etc/config/limitpolice → quota check, overflow → del+add 1kbit│
├──────────────────────────────────────────────────────────────────────────┤
│ kernel net/sched                                                         │
│   tc qdisc ingress (ffff:) on <iface>                                     │
│   ├─ prio 100-199:   user rules (police rate = declared rate)            │
│   └─ prio 9000-9999: stats counters (police rate 999gbit, effectively ∞) │
└──────────────────────────────────────────────────────────────────────────┘
```

### "Zero resident" answered by process accounting

| State | Memory | CPU |
|---|---|---|
| Router up, LuCI closed | 0 extra | 0 extra |
| LuCI main page open | one fork of luci-index | < 200ms |
| Report tab open | one fork of template renderer (no daemon) | < 300ms |
| Every 5 min | one fork of quota-check, exits | < 100ms |
| Daily at 00:00 | 4 cron jobs staggered 1/2/3s apart | each < 100ms |

The only always-on piece is the **procd-managed init script** — but the
script itself does not enter a loop. `start_service` runs once and
returns; procd then waits for a signal. No `while true`, no `sleep`.

### File layout

```
files/
├── etc/
│   ├── config/limitpolice                    # default UCI config
│   ├── init.d/limitpolice                    # procd script (also manages cron)
│   └── uci-defaults/99-limitpolice           # postinst hook placeholder
└── usr/
    ├── lib/lua/luci/
    │   ├── controller/limitpolice.lua        # routes: main/pick/service/edit/stats
    │   ├── model/cbi/
    │   │   ├── limitpolice.lua               # main form
    │   │   └── limitpolice_edit.lua          # extedit single-rule form
    │   └── view/
    │       └── limitpolice_stats.htm         # read-only report template (lazy load)
    ├── sbin/
    │   ├── limitpolice-quota-check           # */5 cron: quota + stats aggregation
    │   ├── limitpolice-quota-reset           # 0 0 * * * cron: clear SNAP + restart
    │   └── limitpolice-stats-clear           # staggered cron: clear stats buckets
    └── share/luci/menu.d/
        └── luci-app-limitpolice.json         # menu (incl. stats tab)
```

### State files

| Path | Purpose | Persistence |
|---|---|---|
| `/var/run/limitpolice.filters` | init.d record: iface + prio + rule_name | runtime, cleared on restart |
| `/var/run/limitpolice.stats` | quota-check record: stats filter slot allocation | runtime, cleared on restart |
| `/var/run/limitpolice/quota` | quota SNAP: `iface:target:dir total last_tc` | runtime, cleared at 00:00 |
| `/tmp/limitpolice.leases` | quota-check cached DHCP parse | valid 5 min |
| `/tmp/limitpolice/stats/<id>` | per-device stats accumulator (`id=mac` or `ip-X.X.X.X`) | cleared on reboot |
| `/etc/crontabs/root` | the 5 cron lines we own (other user entries untouched) | permanent |

### Key design decisions

| Decision | Choice | Why |
|---|---|---|
| Process model | procd + cron; no while loops | hard requirement + 64 MB RAM |
| Limit kernel mechanism | `tc ingress police` | preserves Flow Offload / fullcon / BBR |
| Quota trigger | cron 5 min + tc byte delta | weak CPU cannot poll in real time |
| Quota punishment | `tc filter del` + `add ... police rate 1kbit` | atomic replace, no race |
| Quota lift | service restart at 00:00 daily | UCI rebuilds filters at declared rate |
| Stats counter | prio 9000+ separate filter, `police rate 999gbit` | no collision with user rules, pure counter |
| Stats lazy load | `tc filter add` on first sight in cron | 0 cost at boot; new device visible within 5 min |
| Stats key | DHCP-known MAC; unknown → `ip-X.X.X.X` | user requested "by MAC" |
| Stats storage | `/tmp/limitpolice/stats/<MAC>` (tmpfs) | no flash writes, no UBIFS wear |
| Report UI | `luci.template.render` (not CBI) | read-only view, CBI too heavy |
| Cron stagger | `0`/`1`/`2`/`3` second offsets | dodge quota-reset trigger + flock mutual exclusion |
| Quota key by `<iface>:<target>:<dir>` | not by prio | prio changes across restarts |

## Compatibility matrix

| OpenWrt | Kernel | U32 classifier | Flower classifier | Tested |
|---|---|---|---|---|
| 18.06 | 4.14 | ✅ | ✅ (≥4.16 partial) | ✅ design-compatible |
| 19.07 | 4.14 – 4.19 | ✅ | ✅ | ✅ design-compatible |
| 21.02 | 5.4 – 5.10 | ✅ | ✅ | ✅ design-compatible |
| 22.03 | 5.10 – 5.15 | ✅ | ✅ | ✅ design-compatible |
| 23.05 | 5.15 – 6.1 | ✅ | ✅ | ✅ design-compatible |
| 24.10 | 6.6 | ✅ | ✅ | ✅ design-compatible |

Architectures exercised (weakest → strongest):

- ramips / mt7621 (MediaTek MT7621, single-core 880 MHz)
- ipq40xx (Qualcomm IPQ4018/IPQ4019, quad-core ARM)
- ath79 / ar71xx (Qualcomm Atheros)
- x86_64 / armvirt (VM / soft-router)

## Install

### "One ipk across every OpenWrt version"

The package is pure Lua + shell. The Makefile declares `PKGARCH:=all` —
the ipk **content** does not depend on arch or release. So every arch
build is installable on **any** supported OpenWrt release (18.06 → 24.10)
as long as the arch tag matches your router. Opkg pulls the matching
per-arch `kmod-sched-*` at install time. **No need to clone OpenWrt source.**

### Method A: prebuilt `.ipk` (easiest)

Each release ships **one `.ipk` per CPU architecture**. Currently covered:

| Arch (ipk suffix) | Typical routers |
|---|---|
| `mipsel_24kc` | MediaTek MT7621 / MT7628 / RT305x (ramips, classic weak-CPU targets) |
| `aarch64_cortex-a53` | MediaTek Filogic (MT7981/86/88), armvirt-64 A53 |

Pick the `.ipk` matching your router's CPU from
[Releases](../../releases):

```bash
opkg update
opkg install luci-app-limitpolice_*.ipk
```

If opkg complains about missing kernel modules on a very minimal build:

```bash
opkg install kmod-sched kmod-sched-core kmod-sched-flower
opkg install luci-app-limitpolice_*.ipk
```

### Method B: GitHub Actions (no local toolchain)

1. Fork this repo
2. Go to **Actions → Build IPK → Run workflow**
3. Wait ~10 min; download the artifact matching your arch under
   *Summary → Artifacts*

### Method C: OpenWrt SDK (developers)

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

### Method D: copy files directly (dev mode)

```bash
git clone https://github.com/yourname/luci-app-limitpolice.git
cd luci-app-limitpolice/files
tar czf - . | ssh root@router 'tar xzf - -C /'
ssh root@router '/etc/init.d/limitpolice enable'
ssh root@router '/etc/init.d/limitpolice start'
```

## Usage

### LuCI path

`Network` → `Limit Police` (main form) and `Network` → `Limit Police`
→ `Traffic Report` (stats tab).

### 1. Real-time rate limit (main `Per-device rules` table)

Field reference:

- `Enable`: per-row switch
- `Interface`: physical iface (`eth0`, `eth1`) or bridge (`br-lan`),
  auto-populated from `/sys/class/net`
- `Match by`: IP/CIDR or MAC address
- `Target`: the value (`192.168.1.100/32` or `aa:bb:cc:dd:ee:ff`)
- `Direction`:
  - `dst` (downlink) — caps traffic **to** the device
  - `src` (uplink)   — caps traffic **from** the device
- `Rate` + `Unit`: numeric + unit
- `Note`: free-text label (shown beside the DHCP hostname)
- `Daily quota` + `Quota unit`: cumulative cap (`0` = off)
- `Pick from DHCP` row: chip-style buttons auto-generated from
  `/tmp/dhcp.leases`; clicking an IP chip prefills IP+target_type, MAC
  chip does the same with MAC mode

### 2. Daily quota

- Set `quota=10, quota_unit=GB` → when cumulative ingress bytes exceed
  10 GB today, quota-check replaces the rule's filter with
  `police rate 1kbit` — effectively cutting the device off
- Every day at 00:00 the cron restarts the service; all filters are
  rebuilt from UCI at their declared rate, so the punishment lifts
  automatically
- Quota key is `<iface>:<target>:<dir>`. Prio changes after restart, so
  using prio as the key would leak bytes across restarts

### 3. Traffic report

- `Network` → `Limit Police` → `Traffic Report` (separate tab)
- Columns: device name, MAC/IP, today ↓↑, week ↓↑, month ↓↑, last seen,
  quick-action buttons
- Per device:
  - `Limit` — jumps to main page with prefilled new rule
    (`target_type=mac|ip`)
  - `Quota` — same jump but uses the IP target for daily-quota rule
- Greyed rows = unidentified devices (no DHCP lease); only IP-based
  quick-add is available

### Unit reference

| Display | Meaning | Internal conversion |
|---|---|---|
| Kbps | kilobits per second (ISP convention) | × 1 kbit |
| Mbps | megabits per second (home broadband) | × 1000 kbit |
| KB/s  | kilobytes per second (downloaders) | × 8 kbit |
| MB/s  | megabytes per second | × 8000 kbit |

**Example**: cap at 1.5 MB/s ≈ 12 Mbps = 12000 kbit. In LuCI type
`Rate=1.5, Unit=MB/s`.

### CLI equivalent

```bash
# cap iphone-15 (192.168.1.105) downlink 5 Mbps + 10 GB/day quota
uci add limitpolice rule
uci set limitpolice.@rule[-1].enabled='1'
uci set limitpolice.@rule[-1].interface='br-lan'
uci set limitpolice.@rule[-1].target_type='ip'
uci set limitpolice.@rule[-1].target='192.168.1.105/32'
uci set limitpolice.@rule[-1].direction='dst'
uci set limitpolice.@rule[-1].rate='5'
uci set limitpolice.@rule[-1].unit='Mbps'
uci set limitpolice.@rule[-1].quota='10'
uci set limitpolice.@rule[-1].quota_unit='GB'
uci set limitpolice.@rule[-1].comment='iphone-15'
uci commit limitpolice
/etc/init.d/limitpolice restart

# inspect
/etc/init.d/limitpolice status
tc -s filter show dev br-lan parent ffff:

# trigger quota + stats manually
/usr/sbin/limitpolice-quota-check

# inspect stats bucket files
ls /tmp/limitpolice/stats/
cat /tmp/limitpolice/stats/aa:bb:cc:dd:ee:ff
```

## Kernel module dependencies

The init script auto-`modprobe`s these; the Makefile declares them as
`DEPENDS`. Opkg pulls the **per-arch** matching kmod at install time.

| Module | Package | Required? | Purpose |
|---|---|---|---|
| `sch_ingress` | `kmod-sched-core` | ✅ | ingress qdisc (usually built-in) |
| `act_police` | `kmod-sched` | ✅ | police action |
| `cls_u32` | `kmod-sched-core` | ✅ | U32 classifier (default, kernel 4.14+) |
| `cls_flower` | `kmod-sched-flower` | optional | Flower classifier (newer kernels) |

On a minimal build that lacks these:

```bash
opkg install kmod-sched kmod-sched-core kmod-sched-flower
```

## Compatibility with Flow Offload / fullcon / BBR

| Tech | Purpose | Conflicts with `tc ingress police`? |
|---|---|---|
| **Flow Offloading** | hand off established flows to NIC hardware | ✅ no (drop decision is made before offload) |
| **fullcon NAT** | full-cone NAT, faster NAT pipeline | ✅ no (does not touch NAT) |
| **BBR / cubic** | TCP congestion control | ✅ no (does not touch TCP stack) |
| **SQM / Cake** | active queue management (AQM) | ❌ mutually exclusive (both want the queue layer) |

Rule of thumb:

> **You only want a cap** → use luci-app-limitpolice (this)
> **You want bufferbloat mitigation** → use SQM/Cake (sacrifice hardware acceleration)
> **You want both** → only feasible on a strong CPU (x86_64); weak CPUs pick one

## Known limitations

1. **ingress police does not shape** — packets are hard-dropped, not
   smoothed. TCP backs off (good); UDP real-time (gaming, VoIP)
   stutters. Run game/voice devices through an un-capped lane.
2. **IPv6 not supported** — current `protocol ip` matches IPv4 only.
   Add `protocol ipv6 u32` separately (future).
3. **No automatic bandwidth detection** — `Rate` is what you type. Set
   too low → packet loss; too high → no real cap.
4. **No multi-WAN / multi-WAN6** — single-WAN + LAN-bridge assumed.
5. **Stats reset on reboot** — `/tmp/limitpolice/stats/` lives on tmpfs
   and starts a new baseline each boot. Design tradeoff: avoid flash
   wear on UBIFS devices.
6. **5-minute quota granularity** — the cron runs every 5 min; worst
   case a quota overflow is enforced up to 5 min late. Conscious
   choice to keep `tc -s filter show` off the hot path on weak CPUs.
7. **Stats filter ceiling** — prio 9000-9999 gives 1000 slots = ~500
   devices (2 filters each). Exceeding logs `stats prio band exhausted`.

## Debug

```bash
# plugin status (lists every active filter)
/etc/init.d/limitpolice status

# current filters (user rules + stats counters)
tc -s filter show dev br-lan parent ffff:

# ingress qdisc stats
tc -s qdisc show dev br-lan ingress

# live traffic
watch -n 1 'tc -s filter show dev br-lan parent ffff:'

# trigger quota + stats once manually
/usr/sbin/limitpolice-quota-check

# inspect stats bucket files
ls /tmp/limitpolice/stats/
cat /tmp/limitpolice/stats/aa:bb:cc:dd:ee:ff

# manually clear one period (simulate cron)
/usr/sbin/limitpolice-stats-clear daily

# temporarily stop everything
/etc/init.d/limitpolice stop

# verbose log
uci set limitpolice.@main[0].verbose='1'
uci commit limitpolice
logread -f | grep limitpolice
```

## Acknowledgements

- **Dave Täht** (bufferbloat.net) — original `wshaper.htb` template
- **Alexey N. Vinogradov** (wondershaper maintainer) — early HTB + ingress examples
- **sirpdboy / kenzok78 / Huangjoe** — LuCI QoS ecosystem predecessors
- **OpenWrt community** (especially bolvan's 2016 forum recommendation of `luci-app-wshaper`)

## License

MIT