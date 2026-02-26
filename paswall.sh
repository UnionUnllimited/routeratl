#!/bin/sh
set -eu

# =========================
# Atlanta PassWall Loader
# - installs via upstream passwallx.sh
# - applies Atlanta config (/etc/config/passwall)
# - asks for subscription URL, sets it in UCI
# - updates subscription (if subscribe.lua found)
# =========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

say() { printf "%b\n" "$*"; }
die() { say "${RED}ERROR:${NC} $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Запусти от root."

say "${CYAN}========================================${NC}"
say "${CYAN}      Atlanta PassWall Loader (OpenWrt) ${NC}"
say "${CYAN}========================================${NC}"

# --- ask subscription url (interactive) ---
get_sub_url() {
  # Try to read existing url from UCI if present
  EXISTING="$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || true)"

  say "${YELLOW}[Atlanta] Вставь ссылку подписки PassWall (Enter = оставить текущую)${NC}"
  [ -n "${EXISTING:-}" ] && say "${CYAN}[Atlanta] Текущая:${NC} $EXISTING"

  printf "%b" "${CYAN}[Atlanta] URL> ${NC}" >/dev/tty
  SUB_URL=""
  IFS= read -r SUB_URL </dev/tty || true

  if [ -z "${SUB_URL:-}" ]; then
    SUB_URL="$EXISTING"
  fi

  [ -n "${SUB_URL:-}" ] || die "URL подписки пустой."

  # minimal sanity check
  case "$SUB_URL" in
    http://*|https://*) : ;;
    *) die "URL должен начинаться с http:// или https://";;
  esac

  echo "$SUB_URL"
}

SUB_URL="$(get_sub_url)"

# --- upstream installer ---
UP_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh"
TMP="/tmp/passwallx.sh"

say "${YELLOW}[Atlanta] Скачиваю и запускаю оригинальный установщик PassWall...${NC}"
rm -f "$TMP"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
else
  wget -O "$TMP" "$UP_URL" || die "Не удалось скачать $UP_URL"
fi
chmod +x "$TMP"
sh "$TMP" || die "Оригинальный установщик завершился с ошибкой."

# --- backup existing config ---
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
if [ -f /etc/config/passwall ]; then
  cp -a /etc/config/passwall "/etc/config/passwall.bak.$TS" || true
  say "${GREEN}[Atlanta] Бэкап: /etc/config/passwall.bak.$TS${NC}"
fi

# --- apply PassWall config (your base config) ---
say "${YELLOW}[Atlanta] Накатываю твой конфиг PassWall...${NC}"
cat >/etc/config/passwall <<'EOF'
config global
	option enabled '1'
	option socks_enabled '0'
	option dns_shunt 'dnsmasq'
	option dns_mode 'xray'
	option remote_dns '8.8.8.8'
	list smartdns_remote_dns 'https://1.1.1.1/dns-query'
	option dns_redirect '1'
	option use_gfw_list '0'
	option chn_list 'proxy'
	option tcp_proxy_mode 'disable'
	option udp_proxy_mode 'disable'
	option localhost_proxy '1'
	option client_proxy '1'
	option acl_enable '0'
	option log_tcp '1'
	option log_udp '0'
	option loglevel 'debug'
	option trojan_loglevel '4'
	option log_chinadns_ng '0'
	option timestamp '1771340953'
	option tcp_node_socks_port '1080'
	option use_block_list '0'
	option v2ray_dns_mode 'tcp'
	option tcp_node 'fNDZDacw'
	option udp_node 'fNDZDacw'
	option use_proxy_list '0'
	option flush_set_on_reboot '1'

config global_haproxy
	option balancing_enable '0'

config global_delay
	option start_daemon '1'
	option start_delay '50'

config global_forwarding
	option tcp_no_redir_ports 'disable'
	option udp_no_redir_ports 'disable'
	option tcp_proxy_drop_ports 'disable'
	option udp_proxy_drop_ports '443'
	option tcp_redir_ports '1:65535'
	option udp_redir_ports '1:65535'
	option accept_icmp '0'
	option prefer_nft '1'
	option tcp_proxy_way 'redirect'
	option ipv6_tproxy '0'

config global_xray
	option sniffing_override_dest '0'
	option fragment '0'
	option noise '0'

config global_singbox
	option sniff_override_destination '0'

config global_other
	option auto_detection_time 'tcping'
	option show_node_info '0'
	option enable_group_balancing '1'

config global_rules
	option auto_update '1'
	option chnlist_update '1'
	option chnroute_update '1'
	option chnroute6_update '0'
	option gfwlist_update '0'
	option geosite_update '0'
	option geoip_update '0'
	list gfwlist_url 'https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt'
	option v2ray_location_asset '/usr/share/v2ray/'
	option geoip_url 'https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat'
	option geosite_url 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
	option geo2rule '0'
	option enable_geoview '0'
	option week_update '8'
	option interval_update '1'
	list chnroute_url 'https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/ipchik.lst'
	list chnroute_url 'https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/ipchik.lst'
	list chnroute_url 'https://storage.yandexcloud.net/234588/ipchik.lst'
	list chnlist_url 'https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/domenchik.lst'
	list chnlist_url 'https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/domenchik.lst'
	list chnlist_url 'http://origin.all-streams-24.ru/domenchik.lst'
	list chnlist_url 'https://storage.yandexcloud.net/234588/domenchik.lst'

config global_app
	option sing_box_file '/usr/bin/sing-box'
	option xray_file '/usr/bin/xray'
	option hysteria_file '/usr/bin/hysteria'

config global_subscribe
	option filter_keyword_mode '2'
	option ss_type 'xray'
	option trojan_type 'xray'
	option vmess_type 'xray'
	option vless_type 'xray'
	list filter_keep_list 'Router_'
	option hysteria2_type 'xray'

config subscribe_list
	option remark 'AtlantaRouter'
	option url 'https://example.invalid/replace-me'
	option allowInsecure '0'
	option filter_keyword_mode '5'
	option ss_type 'global'
	option trojan_type 'global'
	option vmess_type 'global'
	option vless_type 'global'
	option domain_strategy 'global'
	option auto_update '1'
	option week_update '8'
	option interval_update '1'
	option user_agent 'passwall'
	# md5 будет пересчитан самим PassWall при обновлении, не хардкодим

config nodes 'fNDZDacw'
	option remarks 'AtlantaSwitch'
	option type 'Xray'
	option protocol '_balancing'
	option balancingStrategy 'leastLoad'
	option useCustomProbeUrl '1'
	option probeUrl 'https://www.gstatic.com/generate_204'
	option probeInterval '5m'
	option enable '1'
	option expected '2'
	list balancing_node '9X7EAQOg'
	list balancing_node 'H0yWVYVU'
	list balancing_node 'TEocNNhs'
	list balancing_node 'aIx6oGBj'
	list balancing_node 'bO4yp7lK'
	list balancing_node 'e8UwYV8E'
	list balancing_node 'el7HxDCT'

config nodes 'H0yWVYVU'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'AtlantaRouter'
	option port '443'
	option remarks 'Router_Finland_1'
	option add_mode '2'
	option tls_allowInsecure '0'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'random'
	option tls '1'
	option reality '1'
	option tls_serverName 'quiz-1.atlanta-router.ru'
	option reality_publicKey 'wE_dgNXu00g3cFCinoRj8Y3wD4VX3IJY_lQhsfTF9gs'
	option address 'quiz-5.atlanta-router.ru'
	option uuid '6eccda9f-1de9-4698-b58d-ef9f3a3455ad'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes '9X7EAQOg'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'AtlantaRouter'
	option port '443'
	option remarks 'Router_Finland_2'
	option add_mode '2'
	option tls_allowInsecure '0'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'random'
	option tls '1'
	option reality '1'
	option tls_serverName 'quiz-1.atlanta-router.ru'
	option reality_publicKey 'wE_dgNXu00g3cFCinoRj8Y3wD4VX3IJY3wD4VX3IJY_lQhsfTF9gs'
	option address 'quiz-3.atlanta-router.ru'
	option uuid '6eccda9f-1de9-4698-b58d-ef9f3a3455ad'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'bO4yp7lK'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'AtlantaRouter'
	option port '443'
	option remarks 'Router_Netherlands_1'
	option add_mode '2'
	option tls_allowInsecure '0'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'random'
	option tls '1'
	option reality '1'
	option tls_serverName 'quiz-1.atlanta-router.ru'
	option reality_publicKey 'wE_dgNXu00g3cFCinoRj8Y3wD4VX3IJY_lQhsfTF9gs'
	option address 'quiz-4.atlanta-router.ru'
	option uuid '6eccda9f-1de9-4698-b58d-ef9f3a3455ad'
	option encryption 'none'
	option utls '1'
	option transport 'raw'
EOF

# --- force set subscription url via UCI ---
say "${YELLOW}[Atlanta] Проставляю URL подписки в конфиг...${NC}"
uci -q set passwall.@subscribe_list[0].remark='AtlantaRouter' || true
uci -q set passwall.@subscribe_list[0].url="$SUB_URL" || true
uci -q delete passwall.@subscribe_list[0].md5 2>/dev/null || true
uci -q commit passwall || true

# --- apply direct_host list (your file can be swapped here) ---
say "${YELLOW}[Atlanta] Обновляю direct_host...${NC}"
mkdir -p /etc/passwall /etc/passwall/rules 2>/dev/null || true

DIRECT_HOST_CONTENT="$(cat <<'EOF'
2ip.ru
example.com
youtube.com
www.youtube.com
m.youtube.com
music.youtube.com
youtu.be
googlevideo.com
ytimg.com
youtubei.googleapis.com
EOF
)"

echo "$DIRECT_HOST_CONTENT" >/etc/passwall/direct_host
echo "$DIRECT_HOST_CONTENT" >/etc/passwall/rules/direct_host

# --- update subscription (best-effort) ---
update_subscribe() {
  # common locations across passwall builds
  for f in \
    /usr/share/passwall/subscribe.lua \
    /usr/share/passwall/subscribe/subscribe.lua \
    /usr/share/passwall/subscribe.lua.new \
    /usr/share/passwall/subscribe.lua.bak
  do
    [ -f "$f" ] || continue
    if command -v lua >/dev/null 2>&1; then
      say "${YELLOW}[Atlanta] Обновляю подписку (lua $f)...${NC}"
      lua "$f" 2>/tmp/atlanta_subscribe.err || true
      return 0
    fi
  done

  # fallback: some builds expose /usr/bin/passwall or init action
  if [ -x /usr/bin/passwall ]; then
    say "${YELLOW}[Atlanta] Обновляю подписку (/usr/bin/passwall subscribe)...${NC}"
    /usr/bin/passwall subscribe 2>/tmp/atlanta_subscribe.err || true
    return 0
  fi

  say "${YELLOW}[Atlanta] Не нашёл subscribe.lua — пропускаю принудительное обновление (PassWall обновит по расписанию/в GUI).${NC}"
  return 0
}

update_subscribe

# --- restart services ---
say "${YELLOW}[Atlanta] Перезапуск PassWall + DNS/Firewall...${NC}"
/etc/init.d/passwall enable 2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || /etc/init.d/passwall start 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

say "${GREEN}[Atlanta] Готово. Подписка применена и обновление запрошено.${NC}"
say "${CYAN}Проверка:${NC}  uci -q get passwall.@subscribe_list[0].url ; /etc/init.d/passwall status"
say "${CYAN}Логи:${NC}      logread -e passwall | tail -n 120 ; cat /tmp/atlanta_subscribe.err 2>/dev/null | tail -n 80"
