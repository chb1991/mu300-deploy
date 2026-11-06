#!/bin/sh
# MU300/Changxing-60 — OpenWrt 25.12.x aarch64_generic
# PassWall2 + sing-box + AdGuard Home installer (no private nodes included).
# Version: 2026-11-06-r2
set -eu
umask 077

say() { printf '\n[MU300] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

KEY_TMP=''
FEED_TMP=''
PENDING_FILE=''
SWITCH_SNAPSHOT=''
cleanup() {
  result=$?
  [ -z "$KEY_TMP" ] || rm -f "$KEY_TMP"
  [ -z "$FEED_TMP" ] || rm -f "$FEED_TMP"
  if [ -n "$PENDING_FILE" ] && [ -f "$PENDING_FILE" ] && [ -n "$SWITCH_SNAPSHOT" ]; then
    warn '安装流程异常退出：正在恢复 DNS 配置。'
    cp -p "$SWITCH_SNAPSHOT" /etc/config/dhcp || true
    /etc/init.d/dnsmasq restart || true
    rm -f "$PENDING_FILE"
  fi
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ "$(id -u)" = 0 ] || fail '必须以 root 用户运行。'
[ -r /etc/openwrt_release ] || fail '找不到 /etc/openwrt_release。'
. /etc/openwrt_release
[ "${DISTRIB_ID:-}" = 'OpenWrt' ] || fail '仅支持官方 OpenWrt 标识的固件。'
case "${DISTRIB_RELEASE:-}" in 25.12.*) ;; *) fail '仅支持 OpenWrt 25.12.x。' ;; esac
[ "${DISTRIB_ARCH:-}" = 'aarch64_generic' ] || fail '仅支持 aarch64_generic 架构。'
[ -x /etc/init.d/dnsmasq ] || fail '找不到 dnsmasq 服务。'
for tool in apk uci sha256sum grep sed mktemp od netstat; do
  command -v "$tool" >/dev/null 2>&1 || fail "缺少命令：$tool"
done
LAN_IP="$(uci -q get network.lan.ipaddr || true)"
[ -n "$LAN_IP" ] || fail '无法读取 network.lan.ipaddr。'
case "$LAN_IP" in *[!0-9.]*|'') fail 'LAN IP 不是预期的 IPv4 格式，停止。' ;; esac

ROOT=/root/mu300-deploy
mkdir -p "$ROOT" /etc/apk/keys /etc/apk/repositories.d
chmod 700 "$ROOT"
RUN="$(date +%Y%m%d-%H%M%S)-$$"
BK="$ROOT/backup-$RUN"
mkdir -p "$BK"
cp -p /etc/config/dhcp "$BK/dhcp"
[ ! -f /etc/config/passwall2 ] || cp -p /etc/config/passwall2 "$BK/passwall2"
[ ! -f /etc/config/adguardhome ] || cp -p /etc/config/adguardhome "$BK/adguardhome"
[ ! -f /etc/adguardhome/adguardhome.yaml ] || cp -p /etc/adguardhome/adguardhome.yaml "$BK/adguardhome.yaml"
[ -f "$ROOT/original-dhcp" ] || cp -p /etc/config/dhcp "$ROOT/original-dhcp"
printf '%s\n' "$BK" > "$ROOT/latest-backup"
say "原始配置已备份：$BK"

# Always create the recovery command before touching DNS settings.
cat > "$ROOT/rollback-dns.sh" <<'EOFROLL'
#!/bin/sh
set -eu
source_file=/root/mu300-deploy/original-dhcp
[ -f "$source_file" ] || { echo '原始备份不存在。' >&2; exit 1; }
cp -p "$source_file" /etc/config/dhcp
/etc/init.d/dnsmasq restart
echo '已恢复首次部署前的 dnsmasq 配置（不会卸载软件）。'
EOFROLL
chmod 700 "$ROOT/rollback-dns.sh"
cat > "$ROOT/restore-last-run-dns.sh" <<'EOFROLL'
#!/bin/sh
set -eu
base="$(cat /root/mu300-deploy/latest-backup)"
[ -f "$base/dhcp" ] || { echo '本次运行备份不存在。' >&2; exit 1; }
cp -p "$base/dhcp" /etc/config/dhcp
/etc/init.d/dnsmasq restart
echo '已恢复最近一次安装脚本执行前的 dnsmasq 配置。'
EOFROLL
chmod 700 "$ROOT/restore-last-run-dns.sh"

# Do not take over a DNS topology already customized by another component.
DNS_CAN_SWITCH=1
if uci -q show dhcp | grep -E '^dhcp\.@dnsmasq\[[0-9]+\]\.server=' | grep -vqF '127.0.0.1#6053'; then
  warn '已有自定义 dnsmasq 上游，跳过自动 DNS 接管。'
  DNS_CAN_SWITCH=0
fi
if [ "$(uci -q get dhcp.@dnsmasq[0].port || echo 53)" != '53' ]; then
  warn 'dnsmasq 不是默认 53 端口，跳过自动 DNS 接管。'
  DNS_CAN_SWITCH=0
fi

say '更新官方 APK 源并安装 AdGuard Home 与 curl'
apk update || fail '官方 APK 更新失败，尚未修改 DNS。'
apk add ca-bundle curl adguardhome || fail 'AdGuard Home 或依赖安装失败，尚未修改 DNS。'

# Signing key checksum confirmed on SourceForge publisher page (2026-11-06).
KEY_SHA256='52802b143489214e13b78f96599a147a638205cc22d9dd6d71229504e38ddc00'
KEY_PATH=/etc/apk/keys/openwrt-passwall-build.pem
KEY_TMP="$(mktemp /tmp/mu300-key.XXXXXX)"
if [ -f "$KEY_PATH" ]; then
  cp "$KEY_PATH" "$KEY_TMP"
else
  say '下载 PassWall2 第三方构建源签名公钥'
  curl -fL --retry 2 --connect-timeout 10 --max-time 90 --silent --show-error \
    'https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub' \
    -o "$KEY_TMP" || fail '下载签名公钥失败。'
fi
grep -q '^-----BEGIN PUBLIC KEY-----' "$KEY_TMP" || fail '公钥不是预期的 PEM 格式。'
printf '%s  %s\n' "$KEY_SHA256" "$KEY_TMP" | sha256sum -c - >/dev/null 2>&1 || \
  fail '公钥与发布方公布的 SHA-256 不一致，停止。'
if [ ! -f "$KEY_PATH" ]; then
  cp "$KEY_TMP" "$KEY_PATH"
  chmod 644 "$KEY_PATH"
fi
rm -f "$KEY_TMP"
KEY_TMP=''

REPO_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-25.12/$DISTRIB_ARCH"
FEED_PATH=/etc/apk/repositories.d/mu300-passwall2.list
FEED_TMP="$(mktemp /tmp/mu300-feed.XXXXXX)"
cat > "$FEED_TMP" <<EOFFEEDS
$REPO_BASE/passwall_packages/packages.adb
$REPO_BASE/passwall_luci/packages.adb
$REPO_BASE/passwall2/packages.adb
EOFFEEDS
if [ -f "$FEED_PATH" ] && ! cmp -s "$FEED_TMP" "$FEED_PATH"; then
  fail "$FEED_PATH 已有不同内容，为避免覆盖，请手动检查。"
fi
FEED_WAS_NEW=0
[ -f "$FEED_PATH" ] || FEED_WAS_NEW=1
cp "$FEED_TMP" "$FEED_PATH"
chmod 644 "$FEED_PATH"
rm -f "$FEED_TMP"
FEED_TMP=''

say '更新 PassWall2 签名源并安装 PassWall2、中文语言包、sing-box'
if ! apk update; then
  [ "$FEED_WAS_NEW" != 1 ] || rm -f "$FEED_PATH"
  fail '第三方 APK 索引更新失败；已撤销本次新加的软件源，DNS 保持原状。'
fi
apk add luci-app-passwall2 luci-i18n-passwall2-zh-cn sing-box || \
  fail 'PassWall2 或 sing-box 安装失败（可能是定制内核依赖），DNS 保持原状。'
# geoview is useful with geosite/geoip rules, but may not be available on every feed.
apk add geoview >/dev/null 2>&1 || warn '可选 geoview 不可安装，后续需检查分流规则支持情况。'

# For a fresh installation, do not activate a proxy with no user-defined node.
if [ ! -f "$BK/passwall2" ] && [ -f /etc/config/passwall2 ]; then
  uci -q set passwall2.@global[0].enabled='0' || true
  uci -q commit passwall2 || true
fi

AGH_YAML="$(uci -q get adguardhome.config.config_file || true)"
[ -n "$AGH_YAML" ] || AGH_YAML=/etc/adguardhome/adguardhome.yaml
AGH_AUTH="$ROOT/agh-curl.conf"
AGH_LOGIN="$ROOT/agh-login.txt"
NEW_AGH=0
AGH_READY=0
AGH_DNS_OK=0
AGH_FILTER_OK=1
AGH_API="http://$LAN_IP:8081/control"

if [ -s "$AGH_YAML" ]; then
  say '已存在 AdGuard Home YAML；不覆盖管理员密码或现有 DNS/过滤配置。'
  /etc/init.d/adguardhome start >/dev/null 2>&1 || warn '现有 AGH 启动失败，请检查日志。'
else
  if netstat -lnut 2>/dev/null | grep -Eq '[[:space:]][^[:space:]]+:(6053|8081)[[:space:]]'; then
    warn '6053 或 8081 已被占用，跳过 AdGuard Home 自动初始化。'
  else
    say '首次配置 AdGuard Home（DNS 127.0.0.1:6053，Web LAN:8081）'
    uci -q set adguardhome.config.work_dir='/opt/adguardhome'
    uci commit adguardhome
    /etc/init.d/adguardhome stop >/dev/null 2>&1 || true
    if ! /etc/init.d/adguardhome start; then
      warn 'AdGuard Home 服务无法启动，保留 dnsmasq 原配置。'
    else
      WIZARD_READY=0
      i=0
      while [ "$i" -lt 15 ]; do
        if curl --noproxy '*' -fsS --max-time 3 \
          http://127.0.0.1:3000/control/install/get_addresses 2>/dev/null | grep -q 'interfaces'; then
          WIZARD_READY=1
          break
        fi
        i=$((i + 1))
        sleep 2
      done
      if [ "$WIZARD_READY" = 1 ]; then
        PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
        [ "${#PASS}" -ge 32 ] || fail '无法生成强密码。'
        if printf '{"web":{"ip":"%s","port":8081},"dns":{"ip":"127.0.0.1","port":6053},"username":"admin","password":"%s","language":"zh-cn"}' \
          "$LAN_IP" "$PASS" | \
          curl --noproxy '*' -fsS --max-time 25 -H 'Content-Type: application/json' \
            -X POST --data-binary @- 'http://127.0.0.1:3000/control/install/configure' >/dev/null; then
          printf 'URL: http://%s:8081\nusername: admin\npassword: %s\n' "$LAN_IP" "$PASS" > "$AGH_LOGIN"
          printf 'user = "admin:%s"\n' "$PASS" > "$AGH_AUTH"
          chmod 600 "$AGH_LOGIN" "$AGH_AUTH"
          NEW_AGH=1
          say "首次配置成功，管理员密码保存在 $AGH_LOGIN（仅 root 可读）。"
        else
          warn "自动配置失败：请手动打开 http://$LAN_IP:3000 完成初始化。"
        fi
        unset PASS
      else
        warn "未检测到首次设置 API，请检查 http://$LAN_IP:3000。"
      fi
    fi
  fi
fi

# Only alter AGH settings on a newly initialized instance. Existing settings stay untouched.
if [ "$NEW_AGH" = 1 ]; then
  i=0
  while [ "$i" -lt 15 ]; do
    if curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 3 "$AGH_API/status" >/dev/null 2>&1; then
      AGH_READY=1
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  if [ "$AGH_READY" = 1 ]; then
    say '设置 AdGuard Home DNS 上游和过滤列表'
    if curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 25 \
      -H 'Content-Type: application/json' -X POST \
      --data '{"upstream_dns":["https://dns.alidns.com/dns-query"],"bootstrap_dns":["223.5.5.5","119.29.29.29"],"fallback_dns":["223.5.5.5"],"cache_size":16777216,"upstream_mode":"load_balance"}' \
      "$AGH_API/dns_config" >/dev/null; then
      AGH_DNS_OK=1
    else
      warn 'DNS 上游设置失败，跳过 dnsmasq 接管。'
    fi
    curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 20 \
      -H 'Content-Type: application/json' -X POST \
      --data '{"enabled":true,"interval":24}' "$AGH_API/filtering/config" >/dev/null || \
      warn '启用过滤规则失败。'
    FILTER_STATE="$(curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 10 "$AGH_API/filtering/status" || true)"
    URL1='https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt'
    URL2='https://anti-ad.net/easylist.txt'
    if ! printf '%s' "$FILTER_STATE" | grep -qF "$URL1"; then
      curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 180 \
        -H 'Content-Type: application/json' -X POST \
        --data "{\"name\":\"AdGuard DNS Filter\",\"url\":\"$URL1\",\"whitelist\":false}" \
        "$AGH_API/filtering/add_url" >/dev/null || { warn 'AdGuard DNS Filter 下载/添加失败。'; AGH_FILTER_OK=0; }
    fi
    if ! printf '%s' "$FILTER_STATE" | grep -qF "$URL2"; then
      curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 180 \
        -H 'Content-Type: application/json' -X POST \
        --data "{\"name\":\"anti-AD CN\",\"url\":\"$URL2\",\"whitelist\":false}" \
        "$AGH_API/filtering/add_url" >/dev/null || { warn 'anti-AD 下载/添加失败。'; AGH_FILTER_OK=0; }
    fi
    FILTER_STATE="$(curl --noproxy '*' --config "$AGH_AUTH" -fsS --max-time 10 "$AGH_API/filtering/status" || true)"
    printf '%s' "$FILTER_STATE" | grep -qF "$URL1" || AGH_FILTER_OK=0
    printf '%s' "$FILTER_STATE" | grep -qF "$URL2" || AGH_FILTER_OK=0
    [ "$AGH_FILTER_OK" = 1 ] || warn '过滤列表未完全加载，暂不切换 dnsmasq。'
  else
    warn '管理 API 无法验证；不修改 dnsmasq。'
  fi
fi

# A true independent DNS test is required before replacing dnsmasq's upstream.
# This runs only after first-time initialization; reruns preserve existing DNS settings.
if [ "$AGH_READY" = 1 ] && [ "$AGH_DNS_OK" = 1 ] && [ "$AGH_FILTER_OK" = 1 ] && [ "$DNS_CAN_SWITCH" = 1 ]; then
  if ! command -v drill >/dev/null 2>&1; then
    apk add drill >/dev/null 2>&1 || warn '无法安装 drill，跳过自动 DNS 接管。'
  fi
  DNS_TEST_OK=0
  if command -v drill >/dev/null 2>&1; then
    if drill -p 6053 @127.0.0.1 www.baidu.com A 2>/dev/null | grep -Eq 'rcode:[[:space:]]*NOERROR'; then
      DNS_TEST_OK=1
    fi
  fi
  if [ "$DNS_TEST_OK" = 1 ]; then
    if command -v nohup >/dev/null 2>&1; then
      say 'DNS 独立测试通过；启用 120 秒安全回滚保护后切换 dnsmasq'
      SWITCH_SNAPSHOT="$BK/dhcp-pre-switch"
      cp -p /etc/config/dhcp "$SWITCH_SNAPSHOT"
      PENDING_FILE="$BK/dns-pending"
      touch "$PENDING_FILE"
      cat > "$BK/watchdog.sh" <<'EOFWATCH'
#!/bin/sh
# Independent fail-safe against SSH/session loss during DNS switchover.
set -eu
backup="$1"
sleep 120
if [ -f "$backup/dns-pending" ] && [ -f "$backup/dhcp-pre-switch" ]; then
  cp -p "$backup/dhcp-pre-switch" /etc/config/dhcp
  /etc/init.d/dnsmasq restart || true
  rm -f "$backup/dns-pending"
  logger -t mu300-deploy 'DNS watchdog restored pre-switch configuration' 2>/dev/null || true
fi
EOFWATCH
      chmod 700 "$BK/watchdog.sh"
      nohup sh "$BK/watchdog.sh" "$BK" </dev/null >/dev/null 2>&1 &
      WATCHDOG_PID=$!
      if ! uci -q show dhcp | grep -qF '127.0.0.1#6053'; then
        uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
      fi
      uci set dhcp.@dnsmasq[0].noresolv='1'
      uci commit dhcp
      DNS_SWITCH_OK=1
      /etc/init.d/dnsmasq restart || DNS_SWITCH_OK=0
      if [ "$DNS_SWITCH_OK" = 1 ]; then
        sleep 3
        nslookup www.baidu.com "$LAN_IP" >/dev/null 2>&1 || DNS_SWITCH_OK=0
      fi
      if [ "$DNS_SWITCH_OK" = 1 ]; then
        sleep 8
        nslookup www.qq.com "$LAN_IP" >/dev/null 2>&1 || DNS_SWITCH_OK=0
      fi
      if [ "$DNS_SWITCH_OK" = 1 ]; then
        # Cancel recovery only after both post-switch checks have passed.
        rm -f "$PENDING_FILE"
        PENDING_FILE=''
        say 'dnsmasq 已安全切换至 AdGuard Home。'
      else
        warn '切换检查失败，立即恢复原 DNS。'
        cp -p "$SWITCH_SNAPSHOT" /etc/config/dhcp
        /etc/init.d/dnsmasq restart || warn 'dnsmasq 恢复服务失败，请使用物理终端处理。'
        rm -f "$PENDING_FILE"
        PENDING_FILE=''
      fi
    else
      warn '缺少 nohup，无独立回滚保护，因此跳过自动 DNS 切换。'
    fi
  else
    warn 'AdGuard Home 6053 端口未通过独立 DNS 解析测试；保留 dnsmasq 原配置。'
  fi
fi

/etc/init.d/adguardhome enable >/dev/null 2>&1 || warn '启用 AGH 开机自启失败。'
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
say '安装流程结束。'
printf 'PassWall2: http://%s/cgi-bin/luci/admin/services/passwall2\n' "$LAN_IP"
printf 'AdGuard Home: http://%s:8081\n' "$LAN_IP"
printf '首次安装密码：cat %s\n' "$AGH_LOGIN"
printf '恢复初次部署前 DNS：sh %s/rollback-dns.sh\n' "$ROOT"
printf '恢复最近一次执行前 DNS：sh %s/restore-last-run-dns.sh\n' "$ROOT"
printf '注意：PassWall2 不自动启用；由你导入 HY2/TUIC 后配置国内直连、国外代理。\n'
printf '注意：未来开启 PassWall2 后必须重新验证 AGH DNS 和 IPv6 DNS 是否被绕过。\n'
