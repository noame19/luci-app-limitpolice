# luci-app-limitpolice

> 一个轻量级的 OpenWrt LuCI 限速插件。用 `tc ingress police`（traffic control
> 入口警察）做**单设备**带宽封顶。和 SQM/Cake/fq_codel 那一套完全不同——
> 不抢硬件 Flow Offload（流量硬件卸载），不挤 fullcon NAT（一种全锥形
> 网络地址转换，比传统 NAT 更快），不破坏 BBR（瓶颈带宽和往返时延优化
> 拥塞控制算法）。

- **内核机制**：内核模块 `sch_ingress`（入口调度队列）+ `act_police`
  （警察动作）+ `cls_u32`（U32 分类器）或 `cls_flower`（Flower 分类器，
  新内核更现代的那个）
- **不用 IFB**（中间功能块设备，软件转发用）、**不用 HTB**（分层令牌桶
  队列）、**不用 fq_codel**（公平队列+主动队列管理）、**不用 Cake**
  —— 这一堆东西恰恰是**搞坏 Flow Offload 的元凶**
- **兼容性**：OpenWrt 18.06（内核 4.14）到 24.10
- **发布形态**：预编译 `.ipk`（opkg 软件包，直接装）或 OpenWrt SDK 自编
- **界面**：LuCI CBI（基于 OpenWrt 的网页配置后台框架），简约现代风格，
  自动从 `/tmp/dhcp.leases`（DHCP 租约文件）读设备清单

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

本插件是纯 Lua + shell，`Makefile` 声明 `LUCI_PKGARCH:=all`——**ipk 内
容本身不依赖具体架构或版本**。所以 GitHub Actions 按架构 build 的每个
`.ipk`，只要路由器 CPU 架构对（OpenWrt 编译时的 `CONFIG_TARGET`），就
能装在 18.06 / 19.07 / 21.02 / 22.03 / 23.05 / 24.10 **任意一个版本**
上。opkg 装的时候会自动去拉对应你路由器内核版本的 `kmod-sched-*` 依赖
包，**不需要**手动 clone OpenWrt 源码编译。

### 方式 A：预编译 `.ipk`（推荐新手）

每个 Release 发布 **3 个 `.ipk`**（按 CPU 架构），对应 3 个目标架构：

| 架构（ipk 包名后缀） | 典型路由器 |
|---|---|
| `x86_64` | x86_64 软路由 / 虚拟机 / `armvirt-64`（EFI） |
| `mipsel_24kc` | MediaTek MT7621 / MT7628 / RT305x（ramips 系列，弱 CPU 经典机型） |
| `aarch64_cortex-a53` | MediaTek Filogic（MT7981/86/88）、armvirt 64 位 |

从 [Releases](../../releases) 选你路由器架构对应的 `.ipk`：

```bash
opkg update
opkg install luci-app-limitpolice_*.ipk   # 任一兼容版本都能装
```

如果提示缺依赖（极简固件可能没有）：

```bash
opkg install kmod-sched-act-police kmod-sched-core kmod-sched-flower
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

`网络（Network）` → `Limit Police`

界面分三大块：

1. **Service** 区
   - 启用开关
   - Start/Stop/Restart/Reload 按钮（直接调 init 脚本，不用 ssh）
   - 当前生效状态（`tc -s filter show` 的输出）

2. **Per-device rules** 表
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

3. **Pick from DHCP** 行
   - 自动读 `/tmp/dhcp.leases`，每台在线设备一个芯片（chip 风格按钮）
   - 点 IP 芯片 → 自动填 IP + 选 IP 模式
   - 点 MAC 芯片 → 自动填 MAC + 选 MAC 模式

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
# 限 iphone-15（IP 192.168.1.105）下行 5 Mbps
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
/etc/init.d/limitpolice restart

# 查看生效规则
/etc/init.d/limitpolice status
tc -s filter show dev br-lan parent ffff:
```

## 内核模块依赖

插件会自动 `modprobe` 这些模块。一般 OpenWrt 默认就有 `sch_ingress`
和 `cls_u32`（编进内核），但 `act_police` 通常作为模块：

| 内核模块 | 包名 | 必需？ | 说明 |
|---|---|---|---|
| `sch_ingress` | `kmod-sched-core` | ✅ | ingress 队列 |
| `act_police` | `kmod-sched-act-police` | ✅ | police 动作 |
| `cls_u32` | `kmod-sched-core` | ✅ | U32 分类器（默认） |
| `cls_flower` | `kmod-sched-flower` | 可选 | Flower 分类器（备用） |

如果路由器极简编译（如某些 mini 固件）没有这些模块：

```bash
opkg install kmod-sched-act-police kmod-sched-core kmod-sched-flower
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

## 调试

```bash
# 看插件状态
/etc/init.d/limitpolice status

# 看当前生效的过滤器
tc -s filter show dev br-lan parent ffff:

# 看 ingress 队列统计
tc -s qdisc show dev br-lan ingress

# 实时流量统计
watch -n 1 'tc -s filter show dev br-lan parent ffff:'

# 临时停掉所有限速（看是否解决问题）
/etc/init.d/limitpolice stop

# 启用 debug 日志
uci set limitpolice.@main[0].verbose='1'
uci commit limitpolice
logread -f | grep limitpolice
```

## 目录结构

```
luci-app-limitpolice/
├── Makefile                       # OpenWrt 包构建描述
├── README.md                      # 英文 README
├── README_CN.md                   # 本文件
├── LICENSE                        # MIT
├── .gitignore
└── files/                         # 安装时复制到路由器根目录
    ├── etc/
    │   ├── config/limitpolice     # UCI 默认配置
    │   ├── init.d/limitpolice     # 主脚本（start/stop/reload/status）
    │   └── uci-defaults/99-limitpolice
    └── usr/
        ├── lib/lua/luci/
        │   ├── controller/limitpolice.lua   # LuCI 路由
        │   └── model/cbi/limitpolice.lua    # LuCI 表单
        └── share/luci/menu.d/
            └── luci-app-limitpolice.json    # 菜单项
```

## 致谢

- **Dave Täht**（bufferbloat.net 之神）—— `wshaper.htb` 经典模板之源
- **Alexey N. Vinogradov**（`wondershaper` 维护者）—— 早期 HTB +
  ingress 范例
- **sirpdboy / kenzok78 / Huangjoe** —— LuCI 限速插件生态前辈
- **OpenWrt 社区**（特别是 bolvan 2016 在 forum 推荐 `luci-app-wshaper`）

## 许可证

MIT
