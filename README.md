# MU300（畅行60）一键部署：PassWall2 + sing-box + AdGuard Home

版本：`2026-11-06-r3`。面向 **OpenWrt 25.12.x / aarch64_generic**，按用户 MU300 当前网络（LAN `192.168.9.1`、dnsmasq :53、Avahi :5353）设计。

> **状态**：安装脚本通过 `ash`、`dash`、`bash` 语法检查和基础逻辑复核；没有在真实 MU300 固件上做端到端运行。硬件定制内核依赖、第三方 APK 源实时可用性及实际 DNS 分流需要上机验证。

## 安装内容和边界

| 功能 | 行为 |
| --- | --- |
| AdGuard Home | 从 OpenWrt 官方 APK 源安装；无现有配置时才执行首次初始化 |
| 广告过滤 | 新实例添加 AdGuard DNS Filter 与 anti-AD DNS 列表；刷新间隔 24 小时 |
| PassWall2 | 从 `moetayuko/openwrt-passwall-build` 的 APK 签名源安装中文 LuCI 面板 |
| sing-box | 安装核心，安装后不自动启用代理 |
| 节点、订阅、密码 | **不包含、不上传、不自动生成**；由用户在本地导入 |
| 国内直连、国外代理 | 需导入节点后在 PassWall2 设置分流规则；脚本不会在缺节点时启动透明代理 |
| dnsmasq | 保留 DHCP、IPv6 RA、53 端口；仅首次初始化 AGH 且 DNS/过滤检查通过时尝试转发至 `127.0.0.1#6053` |
| Avahi | UDP 5353 不改动 |
| AGH DNS 端口 | `127.0.0.1:6053`（仅本机） |
| AGH 管理后台 | `http://<LAN-IP>:8081`（绑定 LAN IP） |
| DNS 上游 | 主用阿里 DoH；异常时以 223.5.5.5 明文 DNS 作兜底（稳定性优先） |

**重要**：DNS 过滤只覆盖经过 AdGuard Home 的请求；用户的手机私人 DNS/DoH、其他 VPN 及未来 PassWall2 的 DNS 劫持均可能绕过本方案。域名级去广告也不能保证去除视频广告和 APP 内所有推广位。

## 代码来源及签名

- AdGuard Home 官方项目：<https://github.com/AdguardTeam/AdGuardHome>
- OpenWrt 软件包说明：<https://openwrt.org/docs/guide-user/services/dns/adguard-home>
- PassWall2：<https://github.com/Openwrt-Passwall/openwrt-passwall2>
- PassWall2 APK 第三方构建源：<https://github.com/moetayuko/openwrt-passwall-build>
- 签名公钥下载：`https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub`
- 公钥 SHA-256：`52802b143489214e13b78f96599a147a638205cc22d9dd6d71229504e38ddc00`（2026-11-06 SourceForge 文件页公示值；**如果维护者换钥必须人工重新审查，脚本不会静默接受**）。
- 不使用 `--allow-untrusted` 安装包。

## 上传 GitHub（公开代码，不公开节点）

1. 在 GitHub 新建仓库 `chb1991/mu300-deploy`，选择 `Public` 和 `main` 分支。
2. 将本项目的 `install.sh`、`README.md` 上传仓库根目录。
3. 确保 `https://raw.githubusercontent.com/chb1991/mu300-deploy/main/install.sh` 可访问，且内容与本次修订版相同。
4. 在设备 SSH 上运行下面的一行命令。

```sh
wget -O /tmp/mu300-install.sh https://raw.githubusercontent.com/chb1991/mu300-deploy/main/install.sh && sh /tmp/mu300-install.sh
```

**注意：仓库在上传之前不存在，上面的 Raw 链接届时才有效。** Public 仓库只公开安装脚本；AGH 新建的随机管理员密码写入设备本地 `/root/mu300-deploy/agh-login.txt`（权限 600），不会提交到 GitHub。私有仓库不能使用上述免认证 Raw 安装命令。

## 安装过程安全控制

1. 检查 OpenWrt 25.12.x 与 `aarch64_generic`，失败则退出。
2. 备份 `/etc/config/dhcp`（还有存在的 AGH/PassWall2 配置）到 `/root/mu300-deploy/backup-*`。
3. 提前生成 DNS 恢复脚本，防止安装中途退出后没有恢复入口。
4. 安装软件，核对签名公钥 SHA-256，配置第三方 APK 源。
5. **只有首次安装、未占用预设端口、且没有已有 AdGuard Home 配置时**，自动初始化 AGH、设置上游并导入过滤列表。
6. 只有 AGH DNS 独立查询和过滤列表验证通过，且 dnsmasq 没有其他自定义上游时，才切换 dnsmasq。
7. 切换期间启动独立的 120 秒守护回滚：如果脚本没有成功结束 DNS 测试，就恢复切换前配置。安装脚本异常退出还会尝试立即恢复。
8. 任何已存在的 AdGuard Home YAML / 密码 / 自定义 DNS 不会被本脚本修改；**重复执行以不覆盖配置为优先**。

### 手动回滚

恢复首次部署前的 DNS：

```sh
sh /root/mu300-deploy/rollback-dns.sh
```

恢复最近一次执行安装脚本**之前**的 DNS：

```sh
sh /root/mu300-deploy/restore-last-run-dns.sh
```

注意：恢复脚本只恢复 dnsmasq 配置，不会移除软件包、更新源或撤销之后做过的手动修改。首次运行 `r2` 脚本时创建 `original-dhcp` 基线；如果之前已经手动修改过 DNS，该基线是运行当时的配置。DNS 的 120 秒守护进程不能跨越设备断电重启，**实际故障仍可能需要 SSH 或物理方式恢复**。

### 安装后检查

```sh
# 状态
/etc/init.d/adguardhome status
ps w | grep -E 'AdGuardHome|dnsmasq|sing-box' | grep -v grep

# DNS 解析（如已接管）
nslookup www.baidu.com 192.168.9.1
nslookup www.qq.com 192.168.9.1

# 管理员密码（仅首次由脚本成功初始化 AGH 时存在）
cat /root/mu300-deploy/agh-login.txt
```

- 管理后台：`http://192.168.9.1:8081`（如果 LAN IP 不同，以安装输出为准）。
- PassWall2：OpenWrt LuCI → 服务 → PassWall2。
- AdGuard Home：检查「过滤器 → DNS 封锁清单」与「查询日志」。
- PassWall2：先导入 HY2/TUIC，设定大陆直连、其他区域代理；确认节点工作后再启动透明代理，**然后再次核实国内 DNS、国外 DNS 和 IPv6 是否经过正确路径**。

## 不自动执行的事项

- 不在没有节点的情况下配置假节点、虚构订阅、启用全局代理。
- 不清理用户已有的 PassWall2 / AdGuard Home 配置。
- 不自动改变防火墙规则、IPv6 RA、系统 DNS 监听地址或 LuCI 端口。
- 不保证 OpenWrt 25.12.x 定制内核可找到匹配的 `kmod-*` 模块；缺失时必须人工处理，**不可强制安装不匹配的内核模块**。
- 不保证广告过滤能够消除所有国内 APP 开屏广告和内容流广告。

## R3 修复：首次启动权限不足

R2 首次启动时可能出现错误：`this is the first launch of adguard home; you must run it as administrator`。

R3 在没有现有 AdGuard Home YAML 的情况下，临时以 root 启动首次配置 API，完成后停止 root 实例，并恢复由 OpenWrt 官方的低权限 `adguardhome` 账号运行。默认持久化工作目录为 `/etc/adguardhome/data`。

已经使用 R2 但未初始化成功的 MU300，请运行独立修复脚本，无需重装 PassWall2：

```sh
wget -O /tmp/repair-agh.sh https://raw.githubusercontent.com/chb1991/mu300-deploy/main/repair-agh.sh && sh /tmp/repair-agh.sh
```

修复后访问管理界面：`http://192.168.77.1:8081`（仅在路由器实际 LAN IP 是该地址时）。管理员密码只保存在本地：`cat /root/mu300-deploy/agh-login.txt`。

注意：**独立修复脚本不会修改 dnsmasq、DHCP、PassWall2**。AGH 可以启动不代表各终端已经经过广告过滤，下一阶段仍需独立检验 DNS 接管。现有有效 YAML 不会被覆盖。

R3 尚未在真实 MU300 上完成端到端验证，遇到失败请检查 `/root/mu300-deploy/agh-bootstrap.log`、`logread` 和监听端口。

## 修复 PassWall2 内置 TPROXY 的 LuCI 误判（MU300 7.2.8）

当 `/proc/config.gz` 中 `CONFIG_NFT_TPROXY=y`、`CONFIG_NFT_SOCKET=y`、`CONFIG_NFT_REDIR=y`，并且 `modules.builtin` 含对应模块时，PassWall2 仍可能显示“缺少组件，透明代理不可用”。这是 LuCI 只读 `lsmod` 而不识别内核内置模块的误判。

先运行[专用修复脚本](fix-passwall2-builtin.sh)：

```sh
wget -O /tmp/fix-passwall2-builtin.sh https://raw.githubusercontent.com/chb1991/mu300-deploy/main/fix-passwall2-builtin.sh && sh /tmp/fix-passwall2-builtin.sh
```

脚本会验证内核配置、`modules.builtin` 和 `nft --check` 规则能力，通过后备份并修改两个 PassWall2 LuCI 检测页面，不更改 DNS、DHCP、firewall 和代理节点；未通过时拒绝修复。改动可以通过下面命令回滚：

```sh
sh /root/mu300-deploy/restore-passwall2-ui.sh
```

这**只修复 LuCI 组件检测**，不伪造 `kmod-nft-*` 包、不代替完整透明代理连通性测试。PassWall2 启动脚本仍可能提示两个 `kmod` 包名缺失。PassWall2 升级后可能需要重新应用该修复。若只安装了 sing-box，没有安装 Xray，请使用兼容的 sing-box 节点/分流设置，不要把默认 Xray 示例节点作为出站。
