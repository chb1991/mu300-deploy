#!/bin/sh
# MU300 AGH R3: repair first-run permission failure without changing dnsmasq/PassWall2.
set -eu
umask 077
say() { printf '[MU300-AGH] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
[ "$(id -u)" = 0 ] || fail '请以 root 身份运行。'
[ -x /usr/bin/AdGuardHome ] || fail '未找到 AdGuardHome 程序。'
[ -x /etc/init.d/adguardhome ] || fail '未找到 AdGuard Home 服务。'
for x in curl uci od netstat chown; do command -v "$x" >/dev/null 2>&1 || fail "缺少命令 $x"; done
LAN_IP="$(uci -q get network.lan.ipaddr || true)"
[ -n "$LAN_IP" ] || fail '无法读取 LAN 地址。'
case "$LAN_IP" in *[!0-9.]*|'') fail 'LAN 地址必须为 IPv4。' ;; esac
ROOT=/root/mu300-deploy
mkdir -p "$ROOT"
chmod 700 "$ROOT"
CONF="$(uci -q get adguardhome.config.config_file || true)"
[ -n "$CONF" ] || CONF=/etc/adguardhome/adguardhome.yaml
CONFDIR="$(dirname "$CONF")"
WORK=/etc/adguardhome/data
LOGIN="$ROOT/agh-login.txt"
AUTH="$ROOT/agh-curl.conf"
BOOT_PID=''
stop_root() {
  if [ -n "$BOOT_PID" ]; then
    kill "$BOOT_PID" 2>/dev/null || true
    wait "$BOOT_PID" 2>/dev/null || true
    BOOT_PID=''
  fi
}
trap stop_root EXIT
trap 'exit 130' HUP INT TERM
if [ -s "$CONF" ]; then
  say '检测到现有 YAML：为避免覆盖账号或现有设置，仅重启服务。'
  /etc/init.d/adguardhome restart
  say '配置未修改。若服务仍不通，请查看 logread。'
  exit 0
fi
if netstat -lnut 2>/dev/null | grep -Eq ':(3000|6053|8081)[[:space:]]'; then
  fail '3000 / 6053 / 8081 端口已有占用，停止以避免冲突。'
fi
say '停止低权限服务，临时以 root 完成首次初始化。'
/etc/init.d/adguardhome stop >/dev/null 2>&1 || true
mkdir -p "$CONFDIR" "$WORK"
chown -R adguardhome:adguardhome "$CONFDIR"
chmod 700 "$CONFDIR" "$WORK"
uci set adguardhome.config.work_dir="$WORK"
uci commit adguardhome
: > "$ROOT/agh-bootstrap.log"
/usr/bin/AdGuardHome --config "$CONF" --work-dir "$WORK" --logfile syslog --no-check-update > "$ROOT/agh-bootstrap.log" 2>&1 &
BOOT_PID=$!
ready=0
i=0
while [ "$i" -lt 20 ]; do
  if curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:3000/control/install/get_addresses 2>/dev/null | grep -q 'interfaces'; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$ready" != 1 ]; then
  warn 'root 引导启动失败，最近日志：'
  tail -n 25 "$ROOT/agh-bootstrap.log" 2>/dev/null || true
  logread | grep -Ei 'adguard|procd.*adguard' | tail -15 || true
  fail '未修改 dnsmasq 或 PassWall2。'
fi
PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
[ "$(printf '%s' "$PASS" | wc -c)" -ge 32 ] || fail '随机密码生成失败。'
if ! printf '{"web":{"ip":"%s","port":8081},"dns":{"ip":"127.0.0.1","port":6053},"username":"admin","password":"%s","language":"zh-cn"}' "$LAN_IP" "$PASS" | curl --noproxy '*' -fsS --max-time 25 -H 'Content-Type: application/json' -X POST --data-binary @- http://127.0.0.1:3000/control/install/configure >/dev/null; then
  fail '初始化 API 失败，DNS 配置未动。'
fi
printf 'URL: http://%s:8081\nusername: admin\npassword: %s\n' "$LAN_IP" "$PASS" > "$LOGIN"
printf 'user = "admin:%s"\n' "$PASS" > "$AUTH"
chmod 600 "$LOGIN" "$AUTH"
unset PASS
stop_root
[ -s "$CONF" ] || fail 'AGH 没有生成 YAML 配置。'
chown -R adguardhome:adguardhome "$CONFDIR"
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start
ready=0
i=0
while [ "$i" -lt 20 ]; do
  if curl --noproxy '*' --config "$AUTH" -fsS --max-time 3 "http://$LAN_IP:8081/control/status" >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
[ "$ready" = 1 ] || fail '配置已写入，但低权限服务还未就绪；请检查 logread。'
say '低权限服务已正常启动，配置上游 DNS 与广告过滤。'
API="http://$LAN_IP:8081/control"
curl --noproxy '*' --config "$AUTH" -fsS --max-time 25 -H 'Content-Type: application/json' -X POST --data '{"upstream_dns":["https://dns.alidns.com/dns-query"],"bootstrap_dns":["223.5.5.5","119.29.29.29"],"fallback_dns":["223.5.5.5"],"cache_size":16777216,"upstream_mode":"load_balance"}' "$API/dns_config" >/dev/null || warn 'DNS 上游设置失败。'
curl --noproxy '*' --config "$AUTH" -fsS --max-time 20 -H 'Content-Type: application/json' -X POST --data '{"enabled":true,"interval":24}' "$API/filtering/config" >/dev/null || warn '启用过滤失败。'
STATE="$(curl --noproxy '*' --config "$AUTH" -fsS --max-time 10 "$API/filtering/status" || true)"
for row in 'AdGuard DNS Filter|https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt' 'anti-AD CN|https://anti-ad.net/easylist.txt'; do
  name="$(printf '%s' "$row" | cut -d '|' -f 1)"
  url="$(printf '%s' "$row" | cut -d '|' -f 2-)"
  if ! printf '%s' "$STATE" | grep -qF "$url"; then
    curl --noproxy '*' --config "$AUTH" -fsS --max-time 180 -H 'Content-Type: application/json' -X POST --data "{\"name\":\"$name\",\"url\":\"$url\",\"whitelist\":false}" "$API/filtering/add_url" >/dev/null || warn "过滤清单添加失败：$name"
  fi
done
say '修复完成，未改变 dnsmasq、DHCP 或 PassWall2。'
printf '后台：http://%s:8081\n' "$LAN_IP"
printf '查看管理员密码：cat %s\n' "$LOGIN"
printf '本机 DNS：127.0.0.1:6053。全设备去广告仍需独立验证后接入 dnsmasq。\n'
