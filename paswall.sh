#!/bin/sh
set -eu

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say(){ printf "%b\n" "$*"; }
tty(){ [ -w /dev/tty ] && printf "%b\n" "$*" >/dev/tty || printf "%b\n" "$*"; }
die(){ say "${RED}ERROR:${NC} $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Запусти от root."

tty "${CYAN}========================================${NC}"
tty "${CYAN}      Atlanta PassWall Loader (OpenWrt) ${NC}"
tty "${CYAN}========================================${NC}"

# --- read URL ONLY from tty to avoid pollution ---
get_sub_url() {
  EXISTING="$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || true)"
  tty "${YELLOW}[Atlanta] Вставь ссылку подписки (Enter = оставить текущую)${NC}"
  [ -n "${EXISTING:-}" ] && tty "${CYAN}[Atlanta] Текущая:${NC} $EXISTING"
  tty -n "${CYAN}[Atlanta] URL> ${NC}"
  SUB_URL=""
  IFS= read -r SUB_URL </dev/tty || true
  [ -z "${SUB_URL:-}" ] && SUB_URL="$EXISTING"
  [ -n "${SUB_URL:-}" ] || die "URL подписки пустой."
  case "$SUB_URL" in http://*|https://*) : ;; *) die "URL должен начинаться с http:// или https://";; esac
  printf "%s" "$SUB_URL"
}

SUB_URL="$(get_sub_url)"
tty "${CYAN}[Atlanta] Использую URL:${NC} $SUB_URL"

# --- install via upstream ---
UP_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh"
TMP="/tmp/passwallx.sh"
tty "${YELLOW}[Atlanta] Установка PassWall через оригинальный скрипт...${NC}"
rm -f "$TMP"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
else
  wget -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
fi
chmod +x "$TMP"
sh "$TMP" || die "Оригинальный установщик завершился с ошибкой."

# --- backup config ---
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
[ -f /etc/config/passwall ] && cp -a /etc/config/passwall "/etc/config/passwall.bak.$TS" || true
BACKUP="/etc/config/passwall.bak.$TS"

# --- pw1-xraybal-sync ---
tty "${YELLOW}[Atlanta] Ставлю pw1-xraybal-sync (балансинг после подписки)...${NC}"
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

if [ -n "$SUB_KEY" ]; then
  picked=""
  for s in $NODE_SECS; do
    sid="$(getoptq "$s" subscribe_id)"
    sub="$(getoptq "$s" subscribe)"
    grp="$(getoptq "$s" group)"
    rmk="$(getoptq "$s" remarks)"
    echo "$sid $sub $grp $rmk" | grep -Fq -- "$SUB_KEY" || continue
    picked="$picked $s"
  done
  picked="$(echo "$picked" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  [ -n "$picked" ] || { log "NO: SUB_KEY matched 0 nodes"; return 0 2>/dev/null || exit 0; }
else
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
fi

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

# --- write config atomically, then sanity-check uci can parse ---
tty "${YELLOW}[Atlanta] Пишу конфиг PassWall (атомарно, с проверкой)...${NC}"

TMP_CFG="/tmp/passwall.atlanta.$$"
cat >"$TMP_CFG" <<EOF
config global
	option enabled '1'
	option dns_shunt 'dnsmasq'
	option dns_mode 'xray'
	option remote_dns '8.8.8.8'
	option dns_redirect '1'
	option chn_list 'proxy'
	option localhost_proxy '1'
	option client_proxy '1'
	option loglevel 'debug'
	option flush_set_on_reboot '1'

config global_rules
	option auto_update '0'
	option chnlist_update '0'
	option chnroute_update '0'
	option week_update '8'
	option interval_update '1'
	list chnroute_url 'https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/ipchik.lst'
	list chnroute_url 'https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/ipchik.lst'
	list chnroute_url 'https://storage.yandexcloud.net/234588/ipchik.lst'
	list chnlist_url 'https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/domenchik.lst'
	list chnlist_url 'https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/domenchik.lst'
	list chnlist_url 'http://origin.all-streams-24.ru/domenchik.lst'
	list chnlist_url 'https://storage.yandexcloud.net/234588/domenchik.lst'

config subscribe_list
	option remark 'AtlantaRouter'
	option url '$SUB_URL'
	option allowInsecure '0'
	option auto_update '1'
	option week_update '8'
	option interval_update '1'
	option user_agent 'passwall'
EOF

# install file + test parse by running uci show on it
cp -f "$TMP_CFG" /etc/config/passwall
rm -f "$TMP_CFG"

# if parsing fails -> rollback
if ! uci -q show passwall >/dev/null 2>&1; then
  tty "${RED}[Atlanta] UCI parse failed. Откатываюсь на бэкап: $BACKUP${NC}"
  [ -f "$BACKUP" ] && cp -f "$BACKUP" /etc/config/passwall
  die "Конфиг PassWall невалиден (uci parse error)."
fi

# ensure url set (again)
uci -q set passwall.@subscribe_list[0].url="$SUB_URL" 2>/dev/null || true
uci -q delete passwall.@subscribe_list[0].md5 2>/dev/null || true
uci -q commit passwall || true

# --- lists to LuCI paths ---
tty "${YELLOW}[Atlanta] Пишу списки (LuCI rules) и применяю...${NC}"
mkdir -p /usr/share/passwall/rules /etc/passwall/rules /etc/passwall 2>/dev/null || true

cat >/usr/share/passwall/rules/direct_host <<'EOF'
#ATLANTA_DIRECT_HOST
youtube.com
www.youtube.com
m.youtube.com
music.youtube.com
youtu.be
googlevideo.com
ytimg.com
youtubei.googleapis.com
EOF

cat >/usr/share/passwall/rules/direct_ip <<'EOF'
#ATLANTA_DIRECT_IP
EOF

# mirror also to proxy/route so UI won't show default buckets
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/proxy_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/route_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/proxy_ip   2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/route_ip   2>/dev/null || true

for f in direct_host direct_ip proxy_host proxy_ip route_host route_ip; do
  [ -f "/usr/share/passwall/rules/$f" ] || continue
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/rules/$f" 2>/dev/null || true
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/$f"       2>/dev/null || true
done

# --- subscribe now + create/ensure balancing section + set tcp/udp node ---
SUB_LOG="/tmp/atl_subscribe_reload.log"
: > "$SUB_LOG" || true

tty "${YELLOW}[Atlanta] Обновляю подписку...${NC}"
if command -v lua >/dev/null 2>&1 && [ -f /usr/share/passwall/subscribe.lua ]; then
  lua /usr/share/passwall/subscribe.lua >>"$SUB_LOG" 2>&1 || true
else
  echo "NO: subscribe.lua not found or lua missing" >>"$SUB_LOG"
fi

# Ensure there is a balancing node section; if absent, create one
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

# Run sync to populate balancing_node list from subscription nodes
tty "${YELLOW}[Atlanta] Sync balancing list...${NC}"
/usr/bin/pw1-xraybal-sync.sh >>/tmp/pw-xraybal.log 2>&1 || true

# Set tcp_node/udp_node to balancing section id
uci -q set passwall.@global[0].tcp_node="$BAL_SEC" 2>/dev/null || true
uci -q set passwall.@global[0].udp_node="$BAL_SEC" 2>/dev/null || true
uci -q commit passwall || true

# restart services
tty "${YELLOW}[Atlanta] Restart passwall + dnsmasq + firewall...${NC}"
/etc/init.d/passwall enable 2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || /etc/init.d/passwall start 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

tty "${GREEN}[Atlanta] ГОТОВО.${NC}"
tty "${CYAN}URL:${NC} $(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || echo '?')"
tty "${CYAN}Subscribe log:${NC} tail -n 80 $SUB_LOG 2>/dev/null || true"
tty "${CYAN}Balancing section:${NC} $BAL_SEC"
tty "${CYAN}Balancing log:${NC} tail -n 80 /tmp/pw-xraybal.log 2>/dev/null || true"
