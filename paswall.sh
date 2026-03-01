cat >/tmp/atlanta_passwall_auto.sh <<'EOF'
#!/bin/sh
set -eu

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say(){ printf "%b\n" "$*"; }
tty(){ if [ -w /dev/tty ]; then printf "%b\n" "$*" >/dev/tty; else printf "%b\n" "$*"; fi; }
die(){ say "${RED}ERROR:${NC} $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Запусти от root."

tty "${CYAN}========================================${NC}"
tty "${CYAN}   Atlanta PassWall Auto Installer v1   ${NC}"
tty "${CYAN}========================================${NC}"

# --- clean URL input (ONLY /dev/tty) ---
get_sub_url() {
  EXISTING="$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || true)"
  tty "${YELLOW}[Atlanta] Вставь ссылку подписки (Enter = оставить текущую)${NC}"
  [ -n "${EXISTING:-}" ] && tty "${CYAN}[Atlanta] Текущая:${NC} $EXISTING"
  if [ ! -r /dev/tty ]; then
    die "Нет /dev/tty. Запусти скрипт из SSH/консоли."
  fi
  printf "%b" "${CYAN}[Atlanta] URL> ${NC}" >/dev/tty
  SUB_URL=""
  IFS= read -r SUB_URL </dev/tty || true
  [ -z "${SUB_URL:-}" ] && SUB_URL="$EXISTING"
  [ -n "${SUB_URL:-}" ] || die "URL подписки пустой."
  case "$SUB_URL" in http://*|https://*) : ;; *) die "URL должен начинаться с http:// или https://";; esac
  printf "%s" "$SUB_URL"
}

SUB_URL="$(get_sub_url)"
tty "${CYAN}[Atlanta] Использую URL:${NC} $SUB_URL"

# --- install PassWall via upstream script ---
UP_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh"
TMP="/tmp/passwallx.sh"

tty "${YELLOW}[Atlanta] Устанавливаю PassWall (оригинальный установщик)...${NC}"
rm -f "$TMP"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
else
  wget -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
fi
chmod +x "$TMP"
sh "$TMP" || die "Установщик PassWall завершился с ошибкой."

# --- backup current config ---
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
[ -f /etc/config/passwall ] && cp -a /etc/config/passwall "/etc/config/passwall.bak.$TS" || true

# --- restore default config so LuCI tabs won't be empty ---
tty "${YELLOW}[Atlanta] Восстанавливаю дефолтный конфиг PassWall (для LuCI)...${NC}"
if [ -f /rom/etc/config/passwall ]; then
  cp -f /rom/etc/config/passwall /etc/config/passwall
fi
uci -q show passwall >/dev/null 2>&1 || die "UCI не парсит /etc/config/passwall (uci parse error)."

# --- helpers: ensure section exists ---
ensure_sec() {
  TYPE="$1"
  sec="$(uci -q show passwall | sed -n "s/^\(passwall\.[^=]*\)=$TYPE.*/\1/p" | head -n1 || true)"
  if [ -z "${sec:-}" ]; then
    s="$(uci -q add passwall "$TYPE")"
    echo "passwall.$s"
  else
    echo "$sec"
  fi
}

GLOBAL="$(ensure_sec global)"
RULES="$(ensure_sec global_rules)"
FWD="$(ensure_sec global_forwarding)"
XRAY="$(ensure_sec global_xray)"
SBOX="$(ensure_sec global_singbox)"
OTHER="$(ensure_sec global_other)"
SUBG="$(ensure_sec global_subscribe)"

# --- apply Atlanta settings via UCI (Mode/DNS/etc) ---
tty "${YELLOW}[Atlanta] Применяю Mode/DNS/Rules настройки...${NC}"

# Global
uci -q set "$GLOBAL.enabled=1"
uci -q set "$GLOBAL.dns_shunt=dnsmasq"
uci -q set "$GLOBAL.dns_mode=xray"
uci -q set "$GLOBAL.remote_dns=8.8.8.8"
uci -q set "$GLOBAL.dns_redirect=1"
uci -q set "$GLOBAL.chn_list=proxy"
uci -q set "$GLOBAL.localhost_proxy=1"
uci -q set "$GLOBAL.client_proxy=1"
uci -q set "$GLOBAL.loglevel=debug"
uci -q set "$GLOBAL.flush_set_on_reboot=1"

# Mode (best-effort; differs by builds)
uci -q set "$GLOBAL.tcp_proxy_mode=redirect" 2>/dev/null || true
uci -q set "$GLOBAL.udp_proxy_mode=tproxy"   2>/dev/null || true

# Forwarding
uci -q set "$FWD.prefer_nft=1" 2>/dev/null || true
uci -q set "$FWD.tcp_proxy_way=redirect" 2>/dev/null || true
uci -q set "$FWD.ipv6_tproxy=0" 2>/dev/null || true
uci -q set "$FWD.tcp_redir_ports=1:65535" 2>/dev/null || true
uci -q set "$FWD.udp_redir_ports=1:65535" 2>/dev/null || true

# Rules (твои URL’ы)
uci -q set "$RULES.auto_update=1" 2>/dev/null || true
uci -q set "$RULES.chnlist_update=1" 2>/dev/null || true
uci -q set "$RULES.chnroute_update=1" 2>/dev/null || true
uci -q set "$RULES.week_update=8" 2>/dev/null || true
uci -q set "$RULES.interval_update=1" 2>/dev/null || true

# purge and set list urls
uci -q delete "$RULES.chnlist_url" 2>/dev/null || true
uci -q delete "$RULES.chnroute_url" 2>/dev/null || true

uci -q add_list "$RULES.chnroute_url=https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/ipchik.lst"
uci -q add_list "$RULES.chnroute_url=https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/ipchik.lst"
uci -q add_list "$RULES.chnroute_url=https://storage.yandexcloud.net/234588/ipchik.lst"

uci -q add_list "$RULES.chnlist_url=https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=http://origin.all-streams-24.ru/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=https://storage.yandexcloud.net/234588/domenchik.lst"

# Subscribe list: ensure only one AtlantaRouter
# delete all subscribe_list sections, create fresh
for s in $(uci -q show passwall | sed -n "s/^passwall\.\([^=]*\)=subscribe_list.*/\1/p"); do
  uci -q delete "passwall.$s" 2>/dev/null || true
done
SUBSEC="$(uci -q add passwall subscribe_list)"
uci -q set "passwall.$SUBSEC.remark=AtlantaRouter"
uci -q set "passwall.$SUBSEC.url=$SUB_URL"
uci -q set "passwall.$SUBSEC.allowInsecure=0"
uci -q set "passwall.$SUBSEC.auto_update=1"
uci -q set "passwall.$SUBSEC.week_update=8"
uci -q set "passwall.$SUBSEC.interval_update=1"
uci -q set "passwall.$SUBSEC.user_agent=passwall"
uci -q delete "passwall.$SUBSEC.md5" 2>/dev/null || true

# bump timestamp
uci -q set "$GLOBAL.timestamp=$(date +%s 2>/dev/null || echo 0)" 2>/dev/null || true

uci -q commit passwall

# --- install balancing sync script + hook into subscribe.lua ---
tty "${YELLOW}[Atlanta] Ставлю pw1-xraybal-sync и хук в subscribe.lua...${NC}"
cat <<'EOF' > /usr/bin/pw1-xraybal-sync.sh
#!/bin/sh
set -u
NS="passwall"
SUB_KEY="${1:-}"
log(){ echo "[$(date '+%F %T')] $*"; }

BAL_SEC="$(uci -q show "$NS" | sed -n "s/^$NS\.\([^=]*\)\.protocol='_balancing'.*/\1/p" | head -n1)"
[ -n "$BAL_SEC" ] || { log "NO: balancing section not found"; return 0 2>/dev/null || exit 0; }
BAL_KEY="balancing_node"

NODE_SECS="$(uci -q show "$NS" | sed -n "s/^$NS\.\([^=]*\)=nodes.*/\1/p")"
[ -n "$NODE_SECS" ] || { log "NO: no nodes sections found"; return 0 2>/dev/null || exit 0; }

getoptq(){ uci -q get "$NS.$1.$2" 2>/dev/null || true; }

node_tag() {
  s="$1"
  sid="$(getoptq "$s" subscribe_id)"
  sub="$(getoptq "$s" subscribe)"
  grp="$(getoptq "$s" group)"
  rmk="$(getoptq "$s" remarks)"
  [ -n "$sid" ] && { echo "subscribe_id:$sid"; return; }
  [ -n "$sub" ] && { echo "subscribe:$sub"; return; }
  [ -n "$grp" ] && { echo "group:$grp"; return; }
  [ -n "$rmk" ] && { echo "remarks:$rmk"; return; }
  echo ""
}

# auto-pick biggest cluster
tags_tmp="/tmp/pw_tags.$$"
: > "$tags_tmp"
for s in $NODE_SECS; do
  t="$(node_tag "$s")"
  [ -n "$t" ] && echo "$t $s" >> "$tags_tmp"
done
[ -s "$tags_tmp" ] || { rm -f "$tags_tmp"; log "NO: cannot classify nodes"; return 0 2>/dev/null || exit 0; }
best_tag="$(awk '{print $1}' "$tags_tmp" | sort | uniq -c | sort -nr | head -n1 | awk '{print $2}')"
picked="$(awk -v t="$best_tag" '$1==t {print $2}' "$tags_tmp" | sort -u)"
rm -f "$tags_tmp"
[ -n "$picked" ] || { log "NO: auto-picked 0 nodes"; return 0 2>/dev/null || exit 0; }

uci -q delete "$NS.$BAL_SEC.$BAL_KEY" 2>/dev/null || true
echo "$picked" | while read -r n; do
  [ -n "$n" ] && uci -q add_list "$NS.$BAL_SEC.$BAL_KEY=$n"
done
uci -q set "$NS.$BAL_SEC.enable='1'" 2>/dev/null || true
uci -q commit "$NS"
log "OK: committed"
return 0 2>/dev/null || exit 0
EOF
chmod +x /usr/bin/pw1-xraybal-sync.sh

SUB_LUA="/usr/share/passwall/subscribe.lua"
HOOK_LINE='os.execute("/usr/bin/pw1-xraybal-sync.sh >/tmp/pw-xraybal.log 2>&1")'
if [ -f "$SUB_LUA" ]; then
  grep -Fq "$HOOK_LINE" "$SUB_LUA" || echo "$HOOK_LINE" >> "$SUB_LUA"
fi

# --- write Atlanta rules files (LuCI reads /usr/share/passwall/rules) ---
tty "${YELLOW}[Atlanta] Записываю Atlanta-списки и обновляю правила...${NC}"
mkdir -p /usr/share/passwall/rules /etc/passwall/rules /etc/passwall 2>/dev/null || true

cat >/usr/share/passwall/rules/direct_host <<'EOF'
#ATLANTA_DIRECT_HOST
youtube.com
googlevideo.com
ytimg.com
youtu.be
EOF

cat >/usr/share/passwall/rules/direct_ip <<'EOF'
#ATLANTA_DIRECT_IP
EOF

# duplicate to other buckets to avoid default IRAN lists showing
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/proxy_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/route_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/proxy_ip   2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/route_ip   2>/dev/null || true

for f in direct_host direct_ip proxy_host proxy_ip route_host route_ip; do
  [ -f "/usr/share/passwall/rules/$f" ] || continue
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/rules/$f" 2>/dev/null || true
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/$f"       2>/dev/null || true
done

# --- force update rules + subscribe now ---
RULES_LOG="/tmp/atl_rules.log"
SUB_LOG="/tmp/atl_subscribe.log"
: > "$RULES_LOG" || true
: > "$SUB_LOG" || true

# try built-in rule updater if exists (best-effort)
if [ -x /usr/bin/passwall ]; then
  /usr/bin/passwall rules >>"$RULES_LOG" 2>&1 || true
fi

# update subscribe
if command -v lua >/dev/null 2>&1 && [ -f /usr/share/passwall/subscribe.lua ]; then
  lua /usr/share/passwall/subscribe.lua >>"$SUB_LOG" 2>&1 || true
fi

# --- ensure balancing node exists; set tcp/udp node to it ---
BAL_SEC="$(uci -q show passwall | sed -n "s/^passwall\.\([^=]*\)\.protocol='_balancing'.*/\1/p" | head -n1 || true)"
if [ -z "${BAL_SEC:-}" ]; then
  BAL_SEC="$(uci -q add passwall nodes)"
  uci -q set "passwall.$BAL_SEC.type=Xray"
  uci -q set "passwall.$BAL_SEC.protocol=_balancing"
  uci -q set "passwall.$BAL_SEC.remarks=AtlantaSwitch"
  uci -q set "passwall.$BAL_SEC.enable=1"
  uci -q set "passwall.$BAL_SEC.balancingStrategy=leastLoad"
  uci -q set "passwall.$BAL_SEC.useCustomProbeUrl=1"
  uci -q set "passwall.$BAL_SEC.probeUrl=https://www.gstatic.com/generate_204"
  uci -q set "passwall.$BAL_SEC.probeInterval=5m"
  uci -q commit passwall
fi

/usr/bin/pw1-xraybal-sync.sh >>/tmp/pw-xraybal.log 2>&1 || true

uci -q set "$GLOBAL.tcp_node=$BAL_SEC" 2>/dev/null || true
uci -q set "$GLOBAL.udp_node=$BAL_SEC" 2>/dev/null || true
uci -q commit passwall

# restart services
tty "${YELLOW}[Atlanta] Перезапуск PassWall + DNS + Firewall...${NC}"
/etc/init.d/passwall enable 2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || /etc/init.d/passwall start 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

tty "${GREEN}[Atlanta] Готово. Всё применено.${NC}"
tty "${CYAN}Subscribe URL:${NC} $(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || echo '?')"
tty "${CYAN}TCP node:${NC} $(uci -q get $GLOBAL.tcp_node 2>/dev/null || echo '?')"
tty "${CYAN}UDP node:${NC} $(uci -q get $GLOBAL.udp_node 2>/dev/null || echo '?')"
tty "${CYAN}Rules log:${NC} tail -n 60 $RULES_LOG 2>/dev/null || true"
tty "${CYAN}Subscribe log:${NC} tail -n 60 $SUB_LOG 2>/dev/null || true"
tty "${CYAN}Balancing log:${NC} tail -n 60 /tmp/pw-xraybal.log 2>/dev/null || true"
EOF
chmod +x /tmp/atlanta_passwall_auto.sh
sh /tmp/atlanta_passwall_auto.sh
