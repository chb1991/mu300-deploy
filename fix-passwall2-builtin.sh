#!/bin/sh
# MU300: repair false-negative PassWall2 LuCI checks for built-in nftables support.
# No kernel packages, firewall changes, DNS changes, or proxy activation.
set -eu
umask 077
say() { printf '[MU300-PW2] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail '请以 root 运行。'
for x in nft zcat grep awk lua cp mv uname; do
  command -v "$x" >/dev/null 2>&1 || fail "缺少 $x"
done
[ -r /proc/config.gz ] || fail '无法读取 /proc/config.gz。'
for flag in NFT_REDIR NFT_SOCKET NFT_TPROXY NF_SOCKET_IPV4 NF_TPROXY_IPV4 NF_SOCKET_IPV6 NF_TPROXY_IPV6; do
  zcat /proc/config.gz | grep -qx "CONFIG_$flag=y" || fail "内核缺少内置 $flag。"
done
MODS="/lib/modules/$(uname -r)/modules.builtin"
[ -r "$MODS" ] || fail "无法读取 $MODS。"
for mod in nft_redir nft_socket nft_tproxy; do
  grep -q "/$mod[.]ko$" "$MODS" || fail "缺少内置 $mod。"
done
# --check is non-mutating: it does not install live firewall rules.
nft --check -f - <<'NFT' || fail 'nftables TPROXY/SOCKET 规则检查失败，未修改文件。'
table inet mu300_probe {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto tcp socket transparent 1 accept
    meta l4proto udp tproxy to :1041 accept
  }
}
NFT

A=/usr/lib/lua/luci/model/cbi/passwall2/client/global.lua
B=/usr/lib/lua/luci/model/cbi/passwall2/client/other.lua
[ -f "$A" ] && [ -f "$B" ] || fail '找不到 PassWall2 LuCI Lua 文件。'
MARKER=MU300_BUILTIN_NFT_V1
if grep -q "$MARKER" "$A" || grep -q "$MARKER" "$B"; then
  if grep -q "$MARKER" "$A" && grep -q "$MARKER" "$B"; then
    say '修复已存在，无需重复执行。'
    exit 0
  fi
  fail '检测到不完整的旧补丁，停止。'
fi
ANCHOR='if (mods:find("REDIRECT") and mods:find("TPROXY")) or (mods:find("nft_redir") and mods:find("nft_tproxy")) then'
for f in "$A" "$B"; do
  [ "$(grep -Fxc "$ANCHOR" "$f")" = 1 ] || fail "代码版本不匹配：$f"
done

ROOT=/root/mu300-deploy
mkdir -p "$ROOT"
chmod 700 "$ROOT"
BK="$ROOT/passwall2-ui-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BK"
chmod 700 "$BK"
cp -p "$A" "$BK/global.lua"
cp -p "$B" "$BK/other.lua"
T1="$A.mu300-tmp-$$"
T2="$B.mu300-tmp-$$"
cleanup() { rm -f "$T1" "$T2"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
for f in "$A" "$B"; do
  case "$f" in
    "$A") t="$T1" ;;
    "$B") t="$T2" ;;
  esac
  cp -p "$f" "$t"
  awk '
    $0 == "if (mods:find(\"REDIRECT\") and mods:find(\"TPROXY\")) or (mods:find(\"nft_redir\") and mods:find(\"nft_tproxy\")) then" {
      print "-- MU300_BUILTIN_NFT_V1: read built-ins, not only lsmod."
      print "local relfile = io.open(\"/proc/sys/kernel/osrelease\", \"r\")"
      print "if relfile then"
      print "  local rel = relfile:read(\"*l\")"
      print "  relfile:close()"
      print "  if rel then"
      print "    local bf = io.open(\"/lib/modules/\" .. rel .. \"/modules.builtin\", \"r\")"
      print "    if bf then"
      print "      mods = mods .. \" \" .. (bf:read(\"*a\") or \"\")"
      print "      bf:close()"
      print "    end"
      print "  end"
      print "end"
    }
    {print}
  ' "$f" > "$t"
  grep -q "$MARKER" "$t" || fail "写入暂存补丁失败：$f"
  if command -v luac >/dev/null 2>&1; then
    luac -p "$t" || fail "Lua 语法检查失败：$f"
  else
    lua -e "assert(loadfile([[$t]]))" || fail "Lua 语法检查失败：$f"
  fi
done
mv "$T1" "$A" || fail '写入 global.lua 失败。'
if ! mv "$T2" "$B"; then
  cp -p "$BK/global.lua" "$A" || true
  fail '写入 other.lua 失败；已尝试恢复。'
fi
printf '%s\n' "$BK" > "$ROOT/last-passwall2-ui-backup"
cat > "$ROOT/restore-passwall2-ui.sh" <<'ROLLBACK'
#!/bin/sh
set -eu
ROOT=/root/mu300-deploy
BK="$(cat "$ROOT/last-passwall2-ui-backup")"
A=/usr/lib/lua/luci/model/cbi/passwall2/client/global.lua
B=/usr/lib/lua/luci/model/cbi/passwall2/client/other.lua
[ -s "$BK/global.lua" ] && [ -s "$BK/other.lua" ] || exit 1
cp -p "$BK/global.lua" "$A"
cp -p "$BK/other.lua" "$B"
/etc/init.d/uhttpd restart || true
printf 'PassWall2 界面文件已恢复。\n'
ROLLBACK
chmod 700 "$ROOT/restore-passwall2-ui.sh"
[ ! -x /etc/init.d/uhttpd ] || /etc/init.d/uhttpd restart || true
say '已修复两个 LuCI 页面的内核内置组件识别。请刷新网页。'
say '恢复命令：sh /root/mu300-deploy/restore-passwall2-ui.sh'
say '注意：未修改包管理器记录；app.sh 仍可能提示 kmod 包名不存在。'
