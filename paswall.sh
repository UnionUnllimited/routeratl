#!/bin/sh
set -eu

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say(){ printf "%b\n" "$*"; }
die(){ say "${RED}ERROR:${NC} $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Запусти от root."

say "${CYAN}========================================${NC}"
say "${CYAN}      Atlanta PassWall Loader (OpenWrt) ${NC}"
say "${CYAN}========================================${NC}"

get_sub_url() {
  EXISTING="$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || true)"
  say "${YELLOW}[Atlanta] Вставь ссылку подписки (Enter = оставить текущую)${NC}"
  [ -n "${EXISTING:-}" ] && say "${CYAN}[Atlanta] Текущая:${NC} $EXISTING"

  SUB_URL=""
  if [ -r /dev/tty ]; then
    printf "%b" "${CYAN}[Atlanta] URL> ${NC}" >/dev/tty
    IFS= read -r SUB_URL </dev/tty || true
  fi
  [ -z "${SUB_URL:-}" ] && { IFS= read -r SUB_URL || true; }
  [ -z "${SUB_URL:-}" ] && SUB_URL="$EXISTING"

  [ -n "${SUB_URL:-}" ] || die "URL подписки пустой."
  case "$SUB_URL" in http://*|https://*) : ;; *) die "URL должен начинаться с http:// или https://";; esac
  echo "$SUB_URL"
}

SUB_URL="$(get_sub_url)"
say "${CYAN}[Atlanta] Использую URL:${NC} $SUB_URL"

# --- install via upstream passwallx.sh ---
UP_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh"
TMP="/tmp/passwallx.sh"

say "${YELLOW}[Atlanta] Установка PassWall через оригинальный скрипт...${NC}"
rm -f "$TMP"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
else
  wget -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
fi
chmod +x "$TMP"
sh "$TMP" || die "Оригинальный установщик завершился с ошибкой."

# --- install pw1-xraybal-sync + hook into subscribe.lua ---
say "${YELLOW}[Atlanta] Ставлю pw1-xraybal-sync (балансинг после подписки)...${NC}"
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

# --- backup current passwall config ---
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
[ -f /etc/config/passwall ] && cp -a /etc/config/passwall "/etc/config/passwall.bak.$TS" || true

# --- IMPORTANT: disable auto rule update to avoid overwriting your lists right away ---
say "${YELLOW}[Atlanta] Отключаю авто-обновление rules (чтобы не перетирало списки)...${NC}"
uci -q set passwall.@global_rules[0].auto_update='0'     2>/dev/null || true
uci -q set passwall.@global_rules[0].chnlist_update='0'  2>/dev/null || true
uci -q set passwall.@global_rules[0].chnroute_update='0' 2>/dev/null || true
uci -q commit passwall 2>/dev/null || true

# --- write YOUR config: embed URL directly so it cannot revert ---
say "${YELLOW}[Atlanta] Пишу конфиг PassWall (URL вшит сразу)...${NC}"
cat >/etc/config/passwall <<EOF
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
	option tcp_node 'fNDZDacw'
	option udp_node 'fNDZDacw'
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

# NOTE: твои nodes/balancing можешь сюда дописать если нужно.
EOF

# Force URL again via UCI (belt & suspenders)
uci -q set passwall.@subscribe_list[0].remark='AtlantaRouter' 2>/dev/null || true
uci -q set passwall.@subscribe_list[0].url="$SUB_URL"        2>/dev/null || true
uci -q delete passwall.@subscribe_list[0].md5 2>/dev/null || true
uci -q set passwall.@global[0].timestamp="$(date +%s 2>/dev/null || echo 0)" 2>/dev/null || true
uci -q commit passwall || true

# --- write lists to LuCI-visible path + duplicates ---
say "${YELLOW}[Atlanta] Пишу списки в /usr/share/passwall/rules и делаю reload...${NC}"
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

# Also mirror to files some LuCI tabs may display
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/proxy_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/route_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/proxy_ip   2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/route_ip   2>/dev/null || true

# duplicates in /etc (some builds read from there)
for f in direct_host direct_ip proxy_host proxy_ip route_host route_ip; do
  [ -f "/usr/share/passwall/rules/$f" ] || continue
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/rules/$f" 2>/dev/null || true
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/$f"       2>/dev/null || true
done

# --- HARD reload sequence ---
SUB_LOG="/tmp/atl_subscribe_reload.log"
: > "$SUB_LOG" || true

say "${YELLOW}[Atlanta] Обновляю подписку (lua subscribe.lua)...${NC}"
if command -v lua >/dev/null 2>&1 && [ -f /usr/share/passwall/subscribe.lua ]; then
  lua /usr/share/passwall/subscribe.lua >>"$SUB_LOG" 2>&1 || true
else
  echo "NO: /usr/share/passwall/subscribe.lua not found or lua missing" >>"$SUB_LOG"
fi

say "${YELLOW}[Atlanta] Sync balancing...${NC}"
/usr/bin/pw1-xraybal-sync.sh >>/tmp/pw-xraybal.log 2>&1 || true

say "${YELLOW}[Atlanta] Restart passwall + dnsmasq + firewall...${NC}"
/etc/init.d/passwall enable 2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || /etc/init.d/passwall start 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

say "${GREEN}[Atlanta] ГОТОВО.${NC}"
say "${CYAN}URL:${NC} $(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || echo '?')"
say "${CYAN}Subscribe log:${NC} tail -n 80 $SUB_LOG 2>/dev/null || true"
say "${CYAN}Balancing log:${NC} tail -n 80 /tmp/pw-xraybal.log 2>/dev/null || true"
say "${CYAN}Direct_host head:${NC} head -n 10 /usr/share/passwall/rules/direct_host 2>/dev/null || true"
