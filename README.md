# luci-app-bypass

OpenWrt 上的网关级透明分流代理。把三个各司其职的组件组合成一个 LuCI 应用：

| 组件 | 角色 | 是否在数据转发路径 |
|---|---|---|
| **naiveproxy** | 流量承载（https，`redir`/`tproxy` 透明监听） | ✅ 是 |
| **ChinaDNS-NG** | DNS 分流（国内域名 → 国内 DNS；国外域名 → 远程 DNS） | ✅ 是 |
| **BypassCore** | 规则/路由诊断（`-test` 路由预览、`-observe` 节点探测） | ❌ 否（仅控制面） |

数据面仅依赖 **nftables (fw4)**；前端为现代 LuCI **JavaScript** 视图（**无 Lua 运行时**）。

> ⚠️ **关于 BypassCore 的角色**：BypassCore 本身**只输出路由 tag，不转发流量**（无 inbound / 无 dialer）。因此本应用把 naiveproxy 作为真正的流量承载方，ChinaDNS-NG 做 DNS 分流，BypassCore 仅作为“规则大脑 + 诊断工具”——生成与防火墙规则同源的 `config.json`，供 LuCI 的“路由测试 / 探测”页面调用。

---

## 工作原理

```
LAN 客户端
   │
nftables TPROXY/REDIRECT
   │            │
  直连         代理目标
   │            │
  wan        naiveproxy (redir/tproxy://127.0.0.1:<REDIR_PORT>)
                 │  proxy = https://<user>:<pass>@<server>:<port>
                 ▼
              naive 服务器 (HTTP/2)

DNS:  dnsmasq :53 → ChinaDNS-NG :<dns_port>
       china-dns  = 国内 DNS   (国内域名 → 国内 IP → 直连)
       trust-dns  = 远程 DNS   (国外域名 → 国外 IP → 代理)
       add-tagchn-ip → nftset `bypass_chn`  (运行时由 chinadns-ng 填充)
       group vpslist → nftset `bypass_vps`  (节点服务器 IP → 永远直连)

出口接口 (naive→server 走指定接口，目的 IP fwmark 策略路由)：
  解析 naive 服务器 IP → nftset `bypass_uplink`
  nft mangle OUTPUT: ip daddr @bypass_uplink → meta mark set <FWMARK>
  ip rule:  fwmark <FWMARK> lookup <TABLE>
  ip route table <TABLE>: default via <iface-gw> dev <iface>  (隧道则 dev-only)
```

- naive **保持 root**，所以 tproxy/tun 不会因丢权限而失败。
- 出口接口有 **全局默认** + **节点级覆盖**；服务器 IP 变更时在启动 / 规则更新 / hotplug 时重新解析。

---

## 依赖关系

Makefile 只硬依赖 shell 运行时必要项；其余全部是 menuconfig 里的**可选勾选**（`INCLUDE_*`）：

- 硬依赖：`curl ip-full resolveip libubox coreutils-nohup coreutils-timeout`
- `Nftables_Transparent_Proxy`（默认 y）：`nftables kmod-nft-tproxy kmod-nft-socket kmod-nft-nat dnsmasq-full + dnsmasq_full_nftset`
- `INCLUDE_NaiveProxy` → `naiveproxy`（受架构限制，排除 mips/mips64 等）
- `INCLUDE_ChinaDNS_NG` → `chinadns-ng`
- `INCLUDE_Geoview` → `geoview`
- `INCLUDE_V2ray_Geo` → `v2ray-geoip` + `v2ray-geosite`
- `INCLUDE_Tcping` → `tcping`

> **本应用不再支持 iptables (fw3)**，仅 nftables。

> **BypassCore 不在任何 feed 里**，且仓库自带的二进制是 macOS arm64（在 OpenWrt 上跑不了），源码也当前编译不过，所以它**不在 Makefile 里**。BypassCore 由**用户自行提供 Linux ELF 二进制**，路径走 UCI 选项 `bypass.global.bypasscore_file`（默认 `/usr/bin/bypasscore`）；缺失或非 Linux ELF 时诊断功能自动禁用并给 UI 提示。

---

## 编译安装

把本目录放到 OpenWrt 源码树里（例如 `feeds/luci/applications/luci-app-bypass` 或直接 `package/luci-app-bypass`），然后：

```sh
# 在 OpenWrt buildroot 里
make menuconfig        # LuCI → Applications → luci-app-bypass，按需勾选 INCLUDE_* / 透明代理后端
make package/feeds/luci/luci-app-bypass/compile V=s
# 产物：bin/packages/<arch>/luci/luci-app-bypass_*.ipk

opkg install luci-app-bypass_*.ipk
```

安装后：
1. 把你的 BypassCore **Linux ELF** 二进制放到 `/usr/bin/bypasscore`（或改 `bypass.global.bypasscore_file`）。
2. 把 `geoip.dat` / `geosite.dat` 放到 `/usr/share/v2ray/`（或安装 `v2ray-geoip` / `v2ray-geosite`）。
3. LuCI → 服务 → Bypass，填节点、选出口接口、启用。

---

## UCI 配置（`/etc/config/bypass`）

```sh
config global
    option enabled '1'
    option node 'naive1'
    option node_socks_port '1070'
    option dns_redirect '1'
    option bypasscore_file '/usr/bin/bypasscore'
    option naive_file '/usr/bin/naive'
    option chinadns_file '/usr/bin/chinadns-ng'
    option default_egress_interface 'wan2'   # 空 = 系统默认路由
    option naive_egress_fwmark '0x2'
    option naive_egress_table '200'

config global_forwarding
    option tcp_proxy_way 'redirect'   # redirect | tproxy
    option tcp_redir_ports '1:65535'
    option udp_redir_ports '1:65535'
    option ipv6_tproxy '0'

config global_dns
    option domestic_dns 'auto'        # auto = 自动检测运营商 DNS
    option remote_dns '1.1.1.1'
    option remote_dns_protocol 'udp'  # udp|tcp|tls|https
    option query_strategy 'UseIPv4'
    option chinadns_listen_port '10553'

config global_rules
    option v2ray_location_asset '/usr/share/v2ray/'
    option domainStrategy 'IpIfNonMatch'

config shunt_rules 'China'
    option network 'tcp,udp'
    option domain_list 'geosite:cn'
    option ip_list 'geoip:cn'
    option outbound '_direct'         # _direct | _proxy | _block

config nodes 'naive1'
    option type 'NaiveProxy'
    option address 'naive.example.com'
    option port '443'
    option username 'user'
    option password 'pass'
    option egress_interface ''        # 空 = 用全局 default_egress_interface
```

---

## 目录结构

```
luci-app-bypass/
├── Makefile                          # luci.mk + INCLUDE_* 可选依赖
├── po/zh-cn/bypass.po                # 中文翻译
├── htdocs/luci-static/resources/view/bypass/
│   ├── overview.js                   # 状态面板 + 路由测试 + observatory + config 预览
│   ├── global.js forwarding.js dns.js
│   ├── node_list.js node_config.js   # 仅 NaiveProxy (https)
│   ├── shunt_rules.js rule_update.js log.js
└── root/
    ├── etc/init.d/bypass             # rc.common + flock + 延迟启动
    ├── etc/uci-defaults/luci-bypass  # 首次安装：拷默认配置、防火墙 include、chmod
    ├── etc/hotplug.d/iface/98-bypass # ifup 重启 / ifupdate 刷新
    └── usr/share/bypass/
        ├── utils.sh                  # 共享库（含出口 fwmark 路由、ELF 校验）
        ├── app.sh                    # 编排：get_config / run_naive / run_chinadns_ng / gen_bypasscore_config / start/stop
        ├── nftables.sh               # nft 透明代理 + 出口 mangle 标记
        ├── rule_update.sh            # 下载校验 geoip/geosite + 重解析出口 IP
        ├── api.sh                    # rpcd file.exec 后端（JSON）
        └── 0_default_config
```

---

## 与 passwall2 的差异

| | passwall2 | luci-app-bypass |
|---|---|---|
| 前端 | Lua CBI / Lua controller | 现代 LuCI JS 视图（无 Lua 运行时） |
| 配置生成 | Lua `util_*.lua gen_config` | 纯 shell + jshn |
| 核心 | Xray / SingBox（自己既分流又转发） | naiveproxy 转发；BypassCore 仅诊断 |
| 防火墙 | nftables + iptables | **仅 nftables** |
| 节点协议 | 多种 | 仅 NaiveProxy (https) |
| 功能 | 订阅 / ACL / haproxy / socks 自动切换 … | MVP（尚未实现订阅/ACL/haproxy） |

---

## 已知限制 / 待办

- **UDP 透明代理**：`redirect` 模式只代理 TCP（naive 的 `redir` 监听）。需要 UDP 代理时切换到 `tproxy` 模式，且你的 naive 必须是用支持 tproxy 的构建编译的。
- **BypassCore 数据面 ≠ 数据面**：`-test` 路由预览严格按规则匹配；实际 nftables/ipset 是基于集合的尽力近似，两者共享同一份规则定义但逐连接语义可能略有差异。
- **未实现**：订阅解析、ACL 规则、haproxy 负载均衡、SOCKS 自动切换、monitor/tasks 守护进程、多语言（目前仅 zh-cn）。

---

## 许可证

MIT（见 [LICENSE](LICENSE)）。
