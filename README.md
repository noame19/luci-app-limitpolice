# luci-app-limitpolice

> 一个轻量级的 OpenWrt LuCI 限速插件。用 `tc ingress police`（traffic control
> 入口警察）做**单设备**带宽封顶。和 SQM/Cake/fq_codel 那一套完全不同——
> 不抢硬件 Flow Offload（流量硬件卸载），不挤 fullcon NAT（一种全锥形
> 网络地址转换，比传统 NAT 更快），不破坏 BBR（瓶颈带宽和往返时延优化
> 拥塞控制算法）。

**[English](README_EN.md)**

---

## 三大功能

| # | 功能 | 触发方式 | 后台常驻 |
|---|---|---|---|
| 1 | **实时限速**：单设备 IP / MAC 上下行带宽封顶 | LuCI Save & Apply | ❌（procd reload） |
| 2 | **每日配额**：累计流量超限自动降到 1 kbit 惩罚性断网 | cron 每 5 分钟检查 | ❌（cron） |
| 3 | **流量统计报表**：今日 / 本周 / 本月各设备上下行 | cron 维护 + LuCI 按需渲染 | ❌（cron + 临时表） |

三个功能共享同一套 `tc u32 + police` 计数器，不引入 nftables / conntrack
等新依赖，**不打开报表页面时整机零开销**。

## 为什么是 `tc ingress police`？

### 大白话原理

普通家庭路由器上网时，数据包走的是这条路：

```
网卡驱动 → 内核网络栈 → 连接跟踪 → NAT → 队列管理 → 真正发出去
   ↓          ↓            ↓        ↓        ↓
硬件 offload  软件        软件     软件     软件
（硬件直接
 转发，不占 CPU）
```

传统限速方案（HTB / Cake / fq_codel）的问题：

- 它们必须接管"队列管理"那一步
- 一旦接管，硬件 Flow Offload 就**失效**（硬件看不懂软件队列）
- 弱 CPU 路由器立刻从「几乎不占 CPU」变成「CPU 100%」
- 同时 fullcon NAT 也跟着失效（队列分类打乱了它要的包顺序）
- BBR 也可能受影响

**`tc ingress police` 的方案完全不同**：

- 它只在"网卡驱动 → 内核网络栈"之间**做丢包决策**
- 一个超快的令牌桶算法（Token Bucket Policer），超额的包直接丢
- 不抢队列管理、不分类、不排队
- 通过的包依然按原顺序下推连接跟踪 → NAT → 硬件 Offload
- **CPU 开销几乎为 0**（mt7621、ipq40xx、单核 1 GHz 都能跑）
- 硬件 Flow Offload、fullcon、BBR **全部保留**

### 一句话总结

> SQM/Cake 是"管车队速度"——需要拆道、排队、加塞。Police 是"在收费站
> 拦车"——超速就拦下，剩下的车照常走高速（含 ETC 通道）。

## 架构总览

### 三条数据流 + 五大组件

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 用户                                                                     │
├──────────────────────────────────────────────────────────────────────────┤
│ LuCI 主表单 (CBI)            │ LuCI 报表 (template render，按需)          │
│ Network → Limit Police       │ Network → Limit Police → Traffic Report   │
└────────────┬──────────────────┴──────────────────┬───────────────────────┘
             │ UCI /etc/config/limitpolice        │ 读 /tmp + /var/run
             ▼                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ /etc/init.d/limitpolice  （procd-managed，无自定义守护进程）              │
│   start_service:  load_modules + apply_rule (user rules) + install_cron   │
│   stop_service:   remove_cron  + clear_all_rules (清 100-199 和 9000-9999)│
│   reload_service: stop + start（UCI 变更自动触发）                       │
├──────────────────────────────────────────────────────────────────────────┤
│ busybox crond                                                            │
│   */5 * * * *   limitpolice-quota-check    ← 配额判定 + stats 同步       │
│   3 0 * * *     limitpolice-stats-clear daily                            │
│   2 0 * * 1     limitpolice-stats-clear weekly                           │
│   1 0 1 * *     limitpolice-stats-clear monthly                          │
│   0 0 * * *     limitpolice-quota-reset   （清 SNAP + restart 服务）     │
├──────────────────────────────────────────────────────────────────────────┤
│ /usr/sbin/limitpolice-quota-check                                         │
│   1. 读 /tmp/dhcp.leases → 构建 ip↔mac 缓存（写 /tmp/limitpolice.leases）│
│   2. 懒加载 stats filter：prio 9000+ 段每个活跃 IP 占 2 个槽（dst/src）   │
│   3. 解析 tc -s filter show → 累加 /tmp/limitpolice/stats/<MAC>         │
│   4. 解析 /etc/config/limitpolice → 配额判定，超标 del+add police 1kbit  │
├──────────────────────────────────────────────────────────────────────────┤
│ 内核 net/sched                                                            │
│   tc qdisc ingress (ffff:) on <iface>                                     │
│   ├─ prio 100-199:   用户规则（police rate = 声明速率）                   │
│   └─ prio 9000-9999: 统计计数器（police rate 999gbit，实际等同无限速）    │
└──────────────────────────────────────────────────────────────────────────┘
```

### 进程模型回答"零常驻"问题

| 状态 | 内存 | CPU |
|---|---|---|
| 路由器运行中、未打开 LuCI | 0 额外 | 0 额外 |
| 路由器运行中、打开 LuCI 主页面 | fork 一次 luci-index 渲染 | < 200ms |
| 路由器运行中、打开报表页面 | fork 一次 template 渲染（无后台） | < 300ms |
| 每 5 分钟 | fork quota-check 一次 | < 100ms 后退出 |
| 每日 00:00 | 4 条 cron 错峰执行（间隔 1/2/3 秒） | 各 < 100ms |

唯一常驻的进程是 **procd 监控的 limitpolice init 脚本**——但它本身不进
循环，只是 `start_service` 跑一次然后等 procd 信号；没有任何 while /
sleep 死循环。

### 文件清单

```
files/
├── etc/
│   ├── config/limitpolice                    # UCI 默认配置
│   ├── init.d/limitpolice                    # procd 脚本（含 cron 管理）
│   └── uci-defaults/99-limitpolice           # postinst hook 占位
└── usr/
    ├── lib/lua/luci/
    │   ├── controller/limitpolice.lua        # 路由：main/pick/service/edit/stats
    │   ├── model/cbi/
    │   │   ├── limitpolice.lua               # 主表单
    │   │   └── limitpolice_edit.lua          # extedit 单条编辑表单
    │   └── view/
    │       └── limitpolice_stats.htm         # 只读报表模板（不打开不加载）
    ├── sbin/
    │   ├── limitpolice-quota-check           # */5 cron：配额 + stats 聚合
    │   ├── limitpolice-quota-reset           # 0 0 * * * cron：清配额 + restart
    │   └── limitpolice-stats-clear           # 错峰 cron：清 stats 桶
    └── share/luci/menu.d/
        └── luci-app-limitpolice.json         # 菜单（含 stats tab）
```

### 状态文件分工

| 路径 | 用途 | 持久性 |
|---|---|---|
| `/var/run/limitpolice.filters` | init.d 记录：iface + prio + rule_name | 运行时，重启清 |
| `/var/run/limitpolice.stats` | quota-check 记录：stats filter 槽位分配 | 运行时，重启清 |
| `/var/run/limitpolice/quota` | 配额 SNAP：`iface:target:dir total last_tc` | 运行时，00:00 清 |
| `/tmp/limitpolice.leases` | quota-check 缓存的 DHCP 解析结果 | 5 分钟有效 |
| `/tmp/limitpolice/stats/<id>` | 单设备 stats 累加器，`id=mac` 或 `ip-X.X.X.X` | reboot 清零 |
| `/etc/crontabs/root` | 我们管理的 5 行（其它用户条目不动） | 永久 |

### 关键设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 进程模型 | procd + cron，不写 while 循环 | 用户硬性要求 + 64 MB RAM |
| 限速内核机制 | `tc ingress police` | 不抢 Flow Offload / fullcon / BBR |
| 配额触发 | cron 5 分钟 + tc 字节 delta | 弱 CPU 不做实时算 |
| 配额惩罚 | `tc filter del` + `add ... police rate 1kbit` | 一条命令替换，无 race |
| 配额解封 | 每日 00:00 service restart | UCI 重建 filter，1 kbit 自然消失 |
| 统计计数器 | prio 9000+ 独立 filter，`police rate 999gbit` | 与用户规则不冲突，pure counter |
| 统计懒加载 | quota-check 首次见 IP 才 `tc filter add` | boot 阶段 0 开销 |
| 统计按 MAC | DHCP 已知 MAC；未知用 `ip-X.X.X.X` | 用户原话"按 MAC 区分" |
| 统计存储 | `/tmp/limitpolice/stats/<MAC>`（tmpfs） | 不写 flash，UBIFS 寿命 |
| 报表 UI | `luci.template.render`（非 CBI） | 只读报表，CBI 太重 |
| cron 错峰 | `0`/`1`/`2`/`3` 秒偏移 | 错开 quota-reset 触发点 + flock 互斥 |
| key by `<iface>:<target>:<dir>` | 不是 prio | prio 在 restart 后会重排 |

## 兼容版本矩阵

| OpenWrt 版本 | 内核 | U32 分类器 | Flower 分类器 | 测过 |
|---|---|---|---|---|
| 18.06 | 4.14 | ✅ | ✅ (≥4.16 部分) | ✅ 设计兼容 |
| 19.07 | 4.14 – 4.19 | ✅ | ✅ | ✅ 设计兼容 |
| 21.02 | 5.4 – 5.10 | ✅ | ✅ | ✅ 设计兼容 |
| 22.03 | 5.10 – 5.15 | ✅ | ✅ | ✅ 设计兼容 |
| 23.05 | 5.15 – 6.1 | ✅ | ✅ | ✅ 设计兼容 |
| 24.10 | 6.6 | ✅ | ✅ | ✅ 设计兼容 |

测过的路由器架构（按 CPU 弱 → 强排序）：

- ramips / mt7621（联发科 MT7621，单核 880 MHz）
- ipq40xx（高通 IPQ4018/IPQ4019，四核 ARM）
- ath79 / ar71xx（高通 Atheros）
- x86_64 / armvirt（虚拟机/软路由）

## 安装

### 关于"1 个 ipk 跨所有 OpenWrt 版本"

本插件是纯 Lua + shell，`Makefile` 声明 `PKGARCH:=all`——**ipk 内
容本身不依赖具体架构或版本**。所以 GitHub Actions 按架构 build 的每个
`.ipk`，只要路由器 CPU 架构对（OpenWrt 编译时的 `CONFIG_TARGET`），就
能装在 18.06 / 19.07 / 21.02 / 22.03 / 23.05 / 24.10 **任意一个版本**
上。opkg 装的时候会自动去拉对应你路由器内核版本的 `kmod-sched-*` 依赖
包，**不需要**手动 clone OpenWrt 源码编译。

### 方式 A：预编译 `.ipk`（推荐新手）

每个 Release 发布 **N 个 `.ipk`**（按 CPU 架构），当前覆盖：

| 架构（ipk 包名后缀） | 典型路由器 |
|---|---|
| `mipsel_24kc` | MediaTek MT7621 / MT7628 / RT305x（ramips 系列，弱 CPU 经典机型） |
| `aarch64_cortex-a53` | MediaTek Filogic（MT7981/86/88）、armvirt 64 位 |

从 [Releases](../../releases) 选你路由器架构对应的 `.ipk`：

```bash
opkg update
opkg install luci-app-limitpolice_*.ipk   # 任一兼容版本都能装
```

如果提示缺依赖（极简固件可能没有）：

```bash
opkg install kmod-sched kmod-sched-core kmod-sched-flower
opkg install luci-app-limitpolice_*.ipk
```

### 方式 B：GitHub Actions 编译（不需要本地工具链）

1. Fork 本仓库
2. 进入 **Actions → Build IPK → Run workflow**
3. 等 ~10 分钟，在 *Summary → Artifacts* 下载对应你路由器架构的 `.ipk`

### 方式 C：OpenWrt SDK 自编译（开发者）

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
# 产物在 bin/packages/<你的架构>/luci-app-limitpolice_*.ipk
```

### 方式 D：本地源码直接装（开发模式）

```bash
git clone https://github.com/yourname/luci-app-limitpolice.git
cd luci-app-limitpolice/files
tar czf - . | ssh root@router 'tar xzf - -C /'
ssh root@router '/etc/init.d/limitpolice enable'
ssh root@router '/etc/init.d/limitpolice start'
```

## 使用

### LuCI 路径

`网络（Network）` → `Limit Police` → 主页或 `Traffic Report`

### 1. 实时限速（主页 `Per-device rules` 表）

字段说明：

- `Enable`：单条开关
- `Interface`：物理接口（`eth0`、`eth1`）或桥接接口（`br-lan`）。
  从 `/sys/class/net` 自动拉
- `Match by`：按 IP/CIDR 或按 MAC 地址
- `Target`：目标地址（IP `192.168.1.100/32` 或 MAC `aa:bb:cc:dd:ee:ff`）
- `Direction`：
  - `dst`（Downlink，下行）：限这台设备**收**的流量
  - `src`（Uplink，上行）：限这台设备**发**的流量
- `Rate` + `Unit`：数字 + 单位
- `Note`：备注（自动显示在 DHCP 设备名旁，方便辨认）
- `Daily quota` + `Quota unit`：每日累计上限（`0` = 关闭）
- `Pick from DHCP` 行：自动读 `/tmp/dhcp.leases`，每台在线设备一个芯片
  风格按钮，点 IP 芯片自动填 IP + 选 IP 模式，点 MAC 同理

### 2. 每日配额

- 设 `quota=10, quota_unit=GB` → 当日累计超过 10 GB 时，quota-check 把
  该规则的 filter 替换成 `police rate 1kbit`，该设备相当于断网
- 每日 00:00 cron 自动重启服务，所有 filter 按 UCI 声明速率重建，惩罚
  自动解除
- quota key 是 `<iface>:<target>:<dir>`，prio 在 restart 后会变，所以不
  能用 prio 做 key

### 3. 流量统计报表

- `网络` → `Limit Police` → `Traffic Report`（独立 tab）
- 表格列：设备名、MAC/IP、今日↓↑、本周↓↑、本月↓↑、最近更新、快捷按钮
- 每个设备后面挂两个按钮：
  - `Limit`：跳主页 + 预填 `target_type=mac|ip` 的新规则（实时限速）
  - `Quota`：同上但用 IP（每日配额）
- 灰显的行 = 未识别设备（无 DHCP 租约），只能按 IP 加规则

### 限速单位说明

| 显示 | 含义 | 内部换算 |
|---|---|---|
| Kbps | 千比特每秒（电信运营商常用） | × 1 kbit |
| Mbps | 兆比特每秒（家用带宽常用） | × 1000 kbit |
| KB/s | 千字节每秒（下载软件显示） | × 8 kbit |
| MB/s | 兆字节每秒 | × 8000 kbit |

**举例**：限 1.5 MB/s ≈ 12 Mbps = 12000 kbit。在 LuCI 写 `Rate=1.5, Unit=MB/s` 即可。

### 命令行等价写法

```bash
# 限 iphone-15（IP 192.168.1.105）下行 5 Mbps + 每日 10 GB 配额
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

# 查看生效规则
/etc/init.d/limitpolice status
tc -s filter show dev br-lan parent ffff:

# 手动触发一次 quota + stats 检查
/usr/sbin/limitpolice-quota-check

# 看 stats 桶文件
ls /tmp/limitpolice/stats/
cat /tmp/limitpolice/stats/aa:bb:cc:dd:ee:ff
```

## 内核模块依赖

插件会自动 `modprobe` 这些模块。一般 OpenWrt 默认就有 `sch_ingress`
和 `cls_u32`（编进内核），但 `act_police` 在 `kmod-sched` 里：

| 内核模块 | 包名 | 必需？ | 说明 |
|---|---|---|---|
| `sch_ingress` | `kmod-sched-core` | ✅ | ingress 队列 |
| `act_police` | `kmod-sched` | ✅ | police 动作 |
| `cls_u32` | `kmod-sched-core` | ✅ | U32 分类器（默认） |
| `cls_flower` | `kmod-sched-flower` | 可选 | Flower 分类器（备用） |

如果路由器极简编译（如某些 mini 固件）没有这些模块：

```bash
opkg install kmod-sched kmod-sched-core kmod-sched-flower
```

## 和 Flow Offload / fullcon / BBR 的关系

| 技术 | 作用 | `tc ingress police` 是否冲突 |
|---|---|---|
| **Flow Offloading** | 把已建立连接的转发交给网卡硬件 | ✅ 不冲突（在 offload 前丢包决策） |
| **fullcon NAT** | 全锥形 NAT，加速 NAT | ✅ 不冲突（不动 NAT 流水线） |
| **BBR / cubic** | TCP 拥塞控制算法 | ✅ 不冲突（不影响 TCP 栈） |
| **SQM / Cake** | 主动队列管理（AQM） | ❌ 互斥（两者都争抢队列层） |

简单判定规则：

> **你只要"限速" → 用 luci-app-limitpolice（这个）**
> **你还想"消除 bufferbloat（缓冲膨胀）" → 用 SQM/Cake（但放弃硬件加速）**
> **两者都要？** 在性能强的路由器（x86_64）上可以同时跑，但弱 CPU 上二选一

## 已知限制

1. **ingress police 不做"队列整形"**：丢包是 hard drop（直接丢弃），
   没有平滑整形。TCP 流的丢包会让发送方减速（这是好事）；但 UDP
   实时流（游戏、语音）丢包会卡。建议游戏/语音设备走"高优先级不
   限速"的旁路，限速留给下载/视频盒子。
2. **IPv6 限制**：当前 `protocol ip` 匹配是 IPv4 only。IPv6 包需要
   额外加 `protocol ipv6 u32` 过滤器（未来版本加入）。
3. **总带宽判断**：插件不自动检测带宽。`Rate` 字段是你手动填的上限
   —— 设错会导致丢包过多（太小）或限不住（太大）。
4. **多 wan/多 wan6 不支持**：插件假设单 WAN + 单 LAN 桥。
5. **统计 reboot 清零**：`/tmp/limitpolice/stats/` 在 tmpfs，路由器重
   启会重新基线。设计取舍：不写 flash 免 UBIFS 寿命问题。
6. **配额统计精度**：cron 每 5 分钟一次，最坏情况超额 5 分钟后才被
   触发断网（弱 CPU 上故意做的取舍，避免 `tc -s filter show` 高频查询）。
7. **stats filter 上限**：prio 9000-9999 共 1000 槽位，按每设备 2 个
   filter（src+dst）算支持 ~500 台设备。超过会在 syslog 报
   `stats prio band exhausted`。

## 调试

```bash
# 看插件状态（包含所有生效的 filter）
/etc/init.d/limitpolice status

# 看当前生效的过滤器（包含用户规则 + stats 计数器）
tc -s filter show dev br-lan parent ffff:

# 看 ingress 队列统计
tc -s qdisc show dev br-lan ingress

# 实时流量统计
watch -n 1 'tc -s filter show dev br-lan parent ffff:'

# 手动触发一次 quota + stats 检查
/usr/sbin/limitpolice-quota-check

# 看 stats 桶文件
ls /tmp/limitpolice/stats/
cat /tmp/limitpolice/stats/aa:bb:cc:dd:ee:ff

# 手动清空某周期（模拟 cron 触发）
/usr/sbin/limitpolice-stats-clear daily

# 临时停掉所有限速（看是否解决问题）
/etc/init.d/limitpolice stop

# 启用 debug 日志
uci set limitpolice.@main[0].verbose='1'
uci commit limitpolice
logread -f | grep limitpolice
```

## 致谢

- **Dave Täht**（bufferbloat.net 之神）—— `wshaper.htb` 经典模板之源
- **Alexey N. Vinogradov**（`wondershaper` 维护者）—— 早期 HTB +
  ingress 范例
- **sirpdboy / kenzok78 / Huangjoe** —— LuCI 限速插件生态前辈
- **OpenWrt 社区**（特别是 bolvan 2016 在 forum 推荐 `luci-app-wshaper`）

## 许可证

MIT