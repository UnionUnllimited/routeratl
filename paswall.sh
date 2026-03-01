#!/bin/sh
set -eu

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say(){ printf "%b\n" "$*"; }
tprint(){ if [ -w /dev/tty ]; then printf "%b\n" "$*" >/dev/tty; else printf "%b\n" "$*"; fi; }
die(){ say "${RED}ERROR:${NC} $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Запусти от root."

tprint "${CYAN}========================================${NC}"
tprint "${CYAN}   Atlanta PassWall Auto Installer v1   ${NC}"
tprint "${CYAN}========================================${NC}"

# --- clean URL input (ONLY /dev/tty if available) ---
get_sub_url() {
  EXISTING="$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || true)"
  tprint "${YELLOW}[Atlanta] Вставь ссылку подписки (Enter = оставить текущую)${NC}"
  [ -n "${EXISTING:-}" ] && tprint "${CYAN}[Atlanta] Текущая:${NC} $EXISTING"

  SUB_URL=""
  if [ -r /dev/tty ]; then
    printf "%b" "${CYAN}[Atlanta] URL> ${NC}" >/dev/tty
    IFS= read -r SUB_URL </dev/tty || true
  else
    # fallback (если запускают без tty)
    printf "%b" "${CYAN}[Atlanta] URL> ${NC}"
    IFS= read -r SUB_URL || true
  fi

  [ -z "${SUB_URL:-}" ] && SUB_URL="$EXISTING"
  [ -n "${SUB_URL:-}" ] || die "URL подписки пустой."
  case "$SUB_URL" in http://*|https://*) : ;; *) die "URL должен начинаться с http:// или https://";; esac
  printf "%s" "$SUB_URL"
}

SUB_URL="$(get_sub_url)"
tprint "${CYAN}[Atlanta] Использую URL:${NC} $SUB_URL"

# --- install PassWall via upstream script ---
UP_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh"
TMP="/tmp/passwallx.sh"

tprint "${YELLOW}[Atlanta] Устанавливаю PassWall (оригинальный установщик)...${NC}"
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
tprint "${YELLOW}[Atlanta] Восстанавливаю дефолтный конфиг PassWall (для LuCI)...${NC}"
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
SUBG="$(ensure_sec global_subscribe)"

# --- apply Atlanta settings via UCI (Mode/DNS/etc) ---
tprint "${YELLOW}[Atlanta] Применяю Mode/DNS/Rules настройки...${NC}"

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

# best-effort mode flags (different builds may ignore)
uci -q set "$GLOBAL.tcp_proxy_mode=redirect" 2>/dev/null || true
uci -q set "$GLOBAL.udp_proxy_mode=tproxy"   2>/dev/null || true

uci -q set "$FWD.prefer_nft=1" 2>/dev/null || true
uci -q set "$FWD.tcp_proxy_way=redirect" 2>/dev/null || true
uci -q set "$FWD.ipv6_tproxy=0" 2>/dev/null || true
uci -q set "$FWD.tcp_redir_ports=1:65535" 2>/dev/null || true
uci -q set "$FWD.udp_redir_ports=1:65535" 2>/dev/null || true

uci -q set "$RULES.auto_update=1" 2>/dev/null || true
uci -q set "$RULES.chnlist_update=1" 2>/dev/null || true
uci -q set "$RULES.chnroute_update=1" 2>/dev/null || true
uci -q set "$RULES.week_update=8" 2>/dev/null || true
uci -q set "$RULES.interval_update=1" 2>/dev/null || true

uci -q delete "$RULES.chnlist_url" 2>/dev/null || true
uci -q delete "$RULES.chnroute_url" 2>/dev/null || true

uci -q add_list "$RULES.chnroute_url=https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/ipchik.lst"
uci -q add_list "$RULES.chnroute_url=https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/ipchik.lst"
uci -q add_list "$RULES.chnroute_url=https://storage.yandexcloud.net/234588/ipchik.lst"

uci -q add_list "$RULES.chnlist_url=https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=http://origin.all-streams-24.ru/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=https://storage.yandexcloud.net/234588/domenchik.lst"

# reset subscribe_list sections, create one correct
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

uci -q set "$GLOBAL.timestamp=$(date +%s 2>/dev/null || echo 0)" 2>/dev/null || true
uci -q commit passwall

# --- write rules files (LuCI reads /usr/share/passwall/rules) ---
tprint "${YELLOW}[Atlanta] Записываю Atlanta-списки...${NC}"
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

cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/proxy_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/route_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/proxy_ip   2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/route_ip   2>/dev/null || true

for f in direct_host direct_ip proxy_host proxy_ip route_host route_ip; do
  [ -f "/usr/share/passwall/rules/$f" ] || continue
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/rules/$f" 2>/dev/null || true
  cp -f "/usr/share/passwall/rules/$f" "/etc/passwall/$f"       2>/dev/null || true
done

# --- try update rules + subscribe now ---
RULES_LOG="/tmp/atl_rules.log"
SUB_LOG="/tmp/atl_subscribe.log"
: > "$RULES_LOG" || true
: > "$SUB_LOG" || true

if [ -x /usr/bin/passwall ]; then
  /usr/bin/passwall rules >>"$RULES_LOG" 2>&1 || true
fi

if command -v lua >/dev/null 2>&1 && [ -f /usr/share/passwall/subscribe.lua ]; then
  lua /usr/share/passwall/subscribe.lua >>"$SUB_LOG" 2>&1 || true
else
  echo "NO: subscribe.lua not found or lua missing" >>"$SUB_LOG"
fi

# --- restart services ---
tprint "${YELLOW}[Atlanta] Перезапуск PassWall + DNS + Firewall...${NC}"
/etc/init.d/passwall enable 2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || /etc/init.d/passwall start 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

tprint "${GREEN}[Atlanta] Готово.${NC}"
tprint "${CYAN}Subscribe URL:${NC} $(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || echo '?')"
tprint "${CYAN}Rules log:${NC} tail -n 60 $RULES_LOG 2>/dev/null || true"
tprint "${CYAN}Subscribe log:${NC} tail -n 60 $SUB_LOG 2>/dev/null || true"
