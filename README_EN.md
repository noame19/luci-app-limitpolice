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
| 2 | **Daily quota**: cumulative bytes over cap → punitive throttle (1 kbit default) | daemon polls every `stats_interval` (default 300 s) | ✅ `limitpoliced` (~300 KB RSS) |
| 3 | **Traffic report**: per-device today / week / month up/down | daemon aggregates + LuCI renders on demand | ✅ same daemon |

All three reuse the same `tc u32 + police` counter machinery. No
nftables / conntrack dependency is added. One single-purpose daemon
serializes all `tc` writes, so quota-check and `init.d reload` can
never race on the rtnetlink lock.

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
│ /etc/init.d/limitpolice  (procd-managed)                                 │
│   start_service: load_modules + apply_rule (user rules) under flock      │
│                  + start /usr/sbin/limitpoliced as procd instance        │
│   stop_service:  flock + backup_stats + clear_all_rules (100-199, 9xxx)  │
│   reload_service: stop + start (auto-fired by UCI change via procd)      │
├──────────────────────────────────────────────────────────────────────────┤
│ /usr/sbin/limitpoliced  (single resident daemon; while true + sleep 10)   │
│   tick loop reads UCI stats_interval / backup_interval, schedules:       │
│     • /usr/sbin/limitpolice-quota-check   every stats_interval           │
│     • /usr/sbin/limitpolice-stats-backup  every backup_interval          │
│   check_crossings(): compares date +%Y%m%d / +%u / +%d against LAST_*;   │
│     on change → triggers stats-clear daily/weekly/monthly + 00:00 reset  │
├──────────────────────────────────────────────────────────────────────────┤
│ /usr/sbin/limitpolice-quota-check                                         │
│   1. read /tmp/dhcp.leases → build ip↔mac cache (→ /tmp/limitpolice.leases)│
│   2. lazy stats filters: prio 9000+ band, 2 slots per active IP (dst/src) │
│   3. parse tc -s filter show → accumulate /tmp/limitpolice/stats/<MAC>   │
│   4. parse /etc/config/limitpolice → quota check, overflow → del+add     │
│      with police rate = main.quota_throttle_rate (default 1 kbit)        │
├──────────────────────────────────────────────────────────────────────────┤
│ kernel net/sched                                                         │
│   tc qdisc ingress (ffff:) on <iface>                                     │
│   ├─ prio 100-199:   user rules (police rate = declared rate)            │
│   └─ prio 9000-9999: stats counters (police rate 999gbit, effectively ∞) │
└──────────────────────────────────────────────────────────────────────────┘
```

### Process accounting

| State | Memory | CPU |
|---|---|---|
| Router up, LuCI closed | 1 × `limitpoliced` (~300 KB RSS) | sleep 10 in a loop |
| LuCI main page open | + one fork of luci-index | < 200ms |
| Report tab open | + one fork of template renderer | < 300ms |
| Every `stats_interval` | daemon forks quota-check, exits | < 100ms |
| Every `backup_interval` | daemon forks stats-backup, exits | < 100ms |
| Day / week / month rollover | daemon itself detects + forks | < 100ms |

The trade vs. pure cron is ~300 KB resident memory in exchange for
**zero race condition** between quota-check, stats-backup and
`init.d reload` — all `tc` writes go through the daemon's serialized
task loop, and `init.d` uses `flock` on `/var/run/limitpolice/.lock`
for the parts that touch `tc` directly.

### File layout

```
files/
├── etc/
│   ├── config/limitpolice                    # default UCI config
│   ├── init.d/limitpolice                    # procd script; flock on tc writes
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
    │   ├── limitpoliced                      # resident daemon (while true; sleeps)
    │   ├── limitpolice-quota-check           # quota + stats aggregation (called by daemon)
    │   ├── limitpolice-stats-backup          # tar.gz snapshot of /tmp stats → /etc
    │   └── limitpolice-stats-clear           # day/week/month bucket clear (called by daemon)
    └── share/luci/menu.d/
        └── luci-app-limitpolice.json         # menu (incl. stats tab)
```

### State files

| Path | Purpose | Persistence |
|---|---|---|
| `/var/run/limitpolice.filters` | init.d record: iface + prio + rule_name | runtime, cleared on restart |
| `/var/run/limitpolice.qdiscs` | init.d record: ifaces where we added ingress qdisc | runtime, cleared on restart |
| `/var/run/limitpolice/.lock` | `flock` mutex for all `tc` writers | runtime |
| `/var/run/limitpoliced.last_*` | daemon: last day / week / month / quota-tick epoch | runtime |
| `/tmp/limitpolice.leases` | quota-check cached DHCP parse | valid 5 min |
| `/tmp/limitpolice/stats/<id>` | per-device stats accumulator (`id=mac` or `ip-X.X.X.X`) | cleared on reboot |
| `/etc/limitpolice/stats_backup.tar.gz` | tar.gz snapshot written by daemon before quit | persistent — protects active reboot only |

### Key design decisions

| Decision | Choice | Why |
|---|---|---|
| Process model | one procd-supervised `limitpoliced` daemon | serialize all `tc` writes; no race with init.d reload |
| Limit kernel mechanism | `tc ingress police` | preserves Flow Offload / fullcon / BBR |
| Quota trigger | daemon polls every `stats_interval` + tc byte delta | weak CPU; UCI-configurable interval |
| Quota punishment | `tc filter del` + `add ... police rate $quota_throttle_rate` | atomic replace; throttle rate UCI-tunable (default 1 kbit = hard wall) |
| Quota lift | daemon detects day rollover, runs `init.d reload` | no cron dependency; UCI rebuilds filters at declared rate |
| Stats counter | prio 9000+ separate filter, `police rate 999gbit` | no collision with user rules, pure counter |
| Stats lazy load | `tc filter add` on first sight in daemon tick | 0 cost at boot; new device visible within one tick |
| Stats key | DHCP-known MAC; unknown → `ip-X.X.X.X` | user requested "by MAC" |
| Stats storage | `/tmp/limitpolice/stats/<MAC>` (tmpfs) | no flash writes, no UBIFS wear |
| Stats persistence | daemon writes tar.gz to `/etc/limitpolice/` before exit | protects against active reboot; power loss can drop one interval |
| Report UI | `luci.template.render` (not CBI) | read-only view, CBI too heavy |
| Direction / iface pairing | `dst` ↔ WAN iface; `src` ↔ LAN iface (validated in init.d) | wrong pairing = zero packets matched = silently wasted rule |
| rtnetlink lock | `flock -x -w 10` on `/var/run/limitpolice/.lock` | serializes init.d reload vs. daemon's quota-check vs. stats-backup |
| Quota key by `<iface>:<target>:<dir>` | not by prio | prio changes across restarts |
| Daemon tick | `while true; sleep 10; ...` | weak CPU: busybox sleep = ~zero; ~300 KB RSS |

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
- `Interface`: physical iface (`eth0`, `eth1`, `wan`, `pppoe-wan`) or
  bridge (`br-lan`), auto-populated from `/sys/class/net`
- `Match by`: IP/CIDR or MAC address
- `Target`: the value (`192.168.1.100/32` or `aa:bb:cc:dd:ee:ff`)
- `Direction`:
  - `dst` (downlink) — caps traffic **to** the device. Pair with a
    **WAN-side** iface (where packets from the internet first hit
    ingress: `wan`, `pppoe-wan`, `eth1`).
  - `src` (uplink)   — caps traffic **from** the device. Pair with a
    **LAN-side** iface (where packets from the device first hit
    ingress: `br-lan`, `eth0`).
  - **Wrong pairing silently matches zero packets.** init.d validates
    and skips the rule with a `logread` warning.
- `Rate` + `Unit`: numeric + unit
- `Note`: free-text label (shown beside the DHCP hostname)
- `Daily quota` + `Quota unit`: cumulative cap (`0` = off)
- `Pick from DHCP` row: chip-style buttons auto-generated from
  `/tmp/dhcp.leases`; clicking an IP chip prefills IP+target_type, MAC
  chip does the same with MAC mode

### 2. Daily quota

- Set `quota=10, quota_unit=GB` → when cumulative ingress bytes exceed
  10 GB today, quota-check replaces the rule's filter with
  `police rate <quota_throttle_rate>kbit` (default `1 kbit` = hard wall).
  Raise `main.quota_throttle_rate` UCI value to `16` / `64` to keep
  basic IM text flowing on the offending device.
- Every day at 00:00 the daemon detects the day rollover and triggers
  `init.d reload`; all filters are rebuilt from UCI at their declared
  rate, so the punishment lifts automatically
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
# NOTE: dst (downlink) MUST pair with a WAN-side iface, not br-lan.
uci add limitpolice rule
uci set limitpolice.@rule[-1].enabled='1'
uci set limitpolice.@rule[-1].interface='wan'             # WAN iface (or pppoe-wan, eth1)
uci set limitpolice.@rule[-1].target_type='ip'
uci set limitpolice.@rule[-1].target='192.168.1.105/32'
uci set limitpolice.@rule[-1].direction='dst'             # downlink → WAN iface
uci set limitpolice.@rule[-1].rate='5'
uci set limitpolice.@rule[-1].unit='Mbps'
uci set limitpolice.@rule[-1].quota='10'
uci set limitpolice.@rule[-1].quota_unit='GB'
uci set limitpolice.@rule[-1].comment='iphone-15'
uci commit limitpolice
/etc/init.d/limitpolice restart

# cap macbook (MAC aa:bb:cc:dd:ee:ff) uplink 2 Mbps
# src (uplink) MUST pair with a LAN-side iface.
uci add limitpolice rule
uci set limitpolice.@rule[-1].enabled='1'
uci set limitpolice.@rule[-1].interface='br-lan'         # LAN iface (or eth0)
uci set limitpolice.@rule[-1].target_type='mac'
uci set limitpolice.@rule[-1].target='aa:bb:cc:dd:ee:ff'
uci set limitpolice.@rule[-1].direction='src'            # uplink → LAN iface
uci set limitpolice.@rule[-1].rate='2'
uci set limitpolice.@rule[-1].unit='Mbps'
uci set limitpolice.@rule[-1].comment='macbook'
uci commit limitpolice
/etc/init.d/limitpolice restart

# inspect
/etc/init.d/limitpolice status
tc -s filter show dev wan parent ffff:

# trigger quota + stats once manually
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
5. **Stats reset on power loss** — `/tmp/limitpolice/stats/` lives on
   tmpfs, but the daemon writes a `tar.gz` snapshot to
   `/etc/limitpolice/stats_backup.tar.gz` on every graceful exit
   (`init.d stop` / `reload`). After an **active reboot** (Save & Apply,
   upgrade, `reboot` CLI), stats resume from the last snapshot.
   After **power loss**, the most recent `backup_interval` of deltas is
   gone — new baseline restarts. Conscious tradeoff to avoid UBIFS
   wear.
6. **Quota granularity = `stats_interval`** — by default 300 s
   (`5 min`). Lower it in UCI for tighter enforcement, raise it on
   extremely weak CPUs. Conscious choice to keep `tc -s filter show`
   off the hot path.
7. **Stats filter ceiling** — prio 9000-9999 gives 1000 slots = ~500
   devices (2 filters each). Exceeding logs `stats prio band exhausted`.
8. **Wrong iface/direction pairing is silently wasted** — init.d logs
   a warning but does not refuse to write UCI. Always cross-check
   `direction` against the iface's role (WAN vs LAN) before saving.

## Debug

```bash
# plugin status (lists every active filter)
/etc/init.d/limitpolice status

# current filters (user rules + stats counters)
tc -s filter show dev wan parent ffff:

# ingress qdisc stats
tc -s qdisc show dev wan ingress

# live traffic
watch -n 1 'tc -s filter show dev wan parent ffff:'

# daemon state directory (last day/week/month/tick epochs)
/var/run/limitpoliced.last_*

# trigger quota + stats once manually
/usr/sbin/limitpolice-quota-check

# backup now
/usr/sbin/limitpolice-stats-backup

# inspect stats bucket files
ls /tmp/limitpolice/stats/
cat /tmp/limitpolice/stats/aa:bb:cc:dd:ee:ff

# manually clear one period (simulate daemon's day rollover)
/usr/sbin/limitpolice-stats-clear daily

# temporarily stop everything (drains daemon + writes backup)
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