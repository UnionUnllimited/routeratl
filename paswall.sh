#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

echo "Running as root..."
sleep 2
clear


/sbin/reload_config


SNNAP=`grep -o SNAPSHOT /etc/openwrt_release | sed -n '1p'`

if [ "$SNNAP" == "SNAPSHOT" ]; then

echo -e "${YELLOW} SNAPSHOT Version Detected ! ${NC}"

rm -f passwalls.sh && wget https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwalls.sh && chmod 777 passwalls.sh && sh passwalls.sh

exit 1

 else
           
echo -e "${GREEN} Updating Packages ... ${NC}"

fi

### Update Packages ###

opkg update

### Add Src ###

wget -O passwall.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub

opkg-key add passwall.pub

>/etc/opkg/customfeeds.conf

read release arch << EOF
$(. /etc/openwrt_release ; echo ${DISTRIB_RELEASE%.*} $DISTRIB_ARCH)
EOF
for feed in passwall_luci passwall_packages passwall2; do
  echo "src/gz $feed https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$release/$arch/$feed" >> /etc/opkg/customfeeds.conf
done

### Install package ###

opkg update
sleep 3
opkg remove dnsmasq
sleep 2
opkg install dnsmasq-full
sleep 3
opkg install unzip
sleep 2
opkg install luci-app-passwall
sleep 3
opkg install ipset
sleep 2
opkg install ipt2socks
sleep 2
opkg install iptables
sleep 2
opkg install iptables-legacy
sleep 2
opkg install iptables-mod-conntrack-extra
sleep 2
opkg install iptables-mod-iprange
sleep 2
opkg install iptables-mod-socket
sleep 2
opkg install iptables-mod-tproxy
sleep 2
opkg install kmod-ipt-nat
sleep 2
opkg install kmod-nft-socket
sleep 2
opkg install kmod-nft-tproxy
sleep 2



####improve

cd /tmp

wget -q https://amir3.space/iam.zip

unzip -o iam.zip -d /

cd

########

sleep 1

RESULT=`ls /etc/init.d/passwall`

if [ "$RESULT" == "/etc/init.d/passwall" ]; then

echo -e "${GREEN} Passwall Installed successfully ! ${NC}"

 else
           
echo -e "${RED} Can not Download Packages ... Check your internet Connection . ${NC}"

exit 1

fi

DNS=`ls /usr/lib/opkg/info/dnsmasq-full.control`

if [ "$DNS" == "/usr/lib/opkg/info/dnsmasq-full.control" ]; then

echo -e "${GREEN} dnsmaq-full Installed successfully ! ${NC}"

 else
           
echo -e "${RED} Package : dnsmasq-full not installed ! (Bad internet connection .) ${NC}"

exit 1

fi




####install_xray
opkg install xray-core


cat <<'EOF' > /usr/bin/pw1-xraybal-sync.sh
#!/bin/sh
# PassWall1: sync "_balancing" from nodes that most likely come from a subscription
# Heuristic: pick the biggest cluster by subscribe_id/subscribe/group/remarks

set -u
NS="passwall"
SUB_KEY="${1:-}"   # optional: force match token (group/remarks/subscribe_id/subscribe)

log(){ echo "[$(date '+%F %T')] $*"; }

# find balancing section
BAL_SEC="$(uci -q show "$NS" | sed -n "s/^$NS\.\([^=]*\)\.protocol='_balancing'.*/\1/p" | head -n1)"
[ -n "$BAL_SEC" ] || { log "NO: balancing section not found"; return 0 2>/dev/null || exit 0; }
BAL_KEY="balancing_node"
log "BAL_SEC=$BAL_SEC"
log "BAL_KEY=$BAL_KEY"

# list node sections
NODE_SECS="$(uci -q show "$NS" | sed -n "s/^$NS\.\([^=]*\)=nodes.*/\1/p")"
[ -n "$NODE_SECS" ] || { log "NO: no nodes sections found"; return 0 2>/dev/null || exit 0; }

getoptq(){ uci -q get "$NS.$1.$2" 2>/dev/null || true; }

# helper: output candidate tag for node
node_tag() {
  s="$1"
  sid="$(getoptq "$s" subscribe_id)"
  sub="$(getoptq "$s" subscribe)"
  grp="$(getoptq "$s" group)"
  rmk="$(getoptq "$s" remarks)"

  # Prefer explicit subscribe_id / subscribe
  if [ -n "$sid" ]; then echo "subscribe_id:$sid"; return; fi
  if [ -n "$sub" ]; then echo "subscribe:$sub"; return; fi
  # Then group/remarks
  if [ -n "$grp" ]; then echo "group:$grp"; return; fi
  if [ -n "$rmk" ]; then echo "remarks:$rmk"; return; fi
  echo ""
}

# If SUB_KEY provided: pick nodes that match it anywhere
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
  if [ -z "$picked" ]; then
    log "NO: SUB_KEY='$SUB_KEY' matched 0 nodes"
    return 0 2>/dev/null || exit 0
  fi
else
  # No SUB_KEY: auto-pick the biggest cluster by tag
  tags_tmp="/tmp/pw_tags.$$"
  : > "$tags_tmp"
  for s in $NODE_SECS; do
    t="$(node_tag "$s")"
    [ -n "$t" ] && echo "$t $s" >> "$tags_tmp"
  done

  if [ ! -s "$tags_tmp" ]; then
    rm -f "$tags_tmp"
    log "NO: cannot classify nodes (no subscribe_id/subscribe/group/remarks found)"
    return 0 2>/dev/null || exit 0
  fi

  # Find most frequent tag
  best_tag="$(awk '{print $1}' "$tags_tmp" | sort | uniq -c | sort -nr | head -n1 | awk '{print $2}')"
  log "AUTO_TAG=$best_tag"

  picked="$(awk -v t="$best_tag" '$1==t {print $2}' "$tags_tmp" | sort -u)"
  rm -f "$tags_tmp"

  [ -n "$picked" ] || { log "NO: auto-picked 0 nodes"; return 0 2>/dev/null || exit 0; }
fi

log "NEW_NODES=$(echo "$picked" | tr '\n' ' ')"

# read old
old="$(uci -q show "$NS" | sed -n "s/^$NS\.$BAL_SEC\.$BAL_KEY='\(.*\)'$/\1/p" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
log "OLD_NODES=$(echo "$old" | tr '\n' ' ')"

if [ "$(echo "$old")" = "$(echo "$picked")" ]; then
  log "OK: no changes"
  return 0 2>/dev/null || exit 0
fi

log "CHANGE: rewriting $NS.$BAL_SEC.$BAL_KEY"
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
echo 'os.execute("/usr/bin/pw1-xraybal-sync.sh >/tmp/pw-xraybal.log 2>&1")' >> /usr/share/passwall/subscribe.lua
cat > /etc/init.d/after_passwall <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
  # Ждем, пока PassWall реально стартанет (короткая пауза безопаснее)
  sleep 3
  /usr/bin/youtube_strategy_autoselect.sh >/tmp/after_passwall.log 2>&1 &
}
EOF

chmod +x /etc/init.d/after_passwall
/etc/init.d/after_passwall enable
/etc/init.d/after_passwall start
opkg install zram-swap
#!/bin/sh
# ============================================================
#  Atlanta Router — PassWall Auto-Installer
#  Автоматически устанавливает конфиг PassWall
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo "${GREEN}[✓]${NC} $1"; }
warn() { echo "${YELLOW}[!]${NC} $1"; }
err()  { echo "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Atlanta Router — PassWall Setup    ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── 1. Проверка PassWall ─────────────────────────────────────
if ! opkg list-installed 2>/dev/null | grep -q 'passwall'; then
    warn "PassWall не найден. Устанавливаем..."
    opkg update && opkg install luci-app-passwall || err "Не удалось установить PassWall"
fi
log "PassWall найден"

# ── 2. Бэкап старого конфига ─────────────────────────────────
if [ -f /etc/config/passwall ]; then
    cp /etc/config/passwall /etc/config/passwall.bak
    log "Старый конфиг сохранён → /etc/config/passwall.bak"
fi

# ── 3. Запись конфига PassWall ───────────────────────────────
log "Записываем конфиг PassWall..."

cat > /etc/config/passwall << 'EOF_PASSWALL'

config global
	option enabled '1'
	option socks_enabled '0'
	option tcp_node_socks_port '1080'
	option dns_shunt 'chinadns-ng'
	option dns_redirect '1'
	option chn_list 'proxy'
	option tcp_proxy_mode 'disable'
	option udp_proxy_mode 'disable'
	option localhost_proxy '1'
	option client_proxy '1'
	option acl_enable '0'
	option log_tcp '1'
	option log_udp '1'
	option loglevel 'debug'
	option trojan_loglevel '4'
	option log_chinadns_ng '1'
	option tcp_node '7usGKVwg'
	option udp_node '7usGKVwg'
	option use_block_list '0'
	option use_gfw_list '0'
	option v2ray_dns_mode 'tcp+doh'
	option filter_proxy_ipv6 '1'
	option remote_dns '1.1.1.1'
	option remote_dns_doh 'https://8.8.8.8/dns-query'
	option remote_fakedns '1'
	option dns_mode 'xray'
	option force_https_soa '1'
	option advanced_log_feature '1'
	option sys_log '1'

config global_haproxy
	option balancing_enable '0'

config global_delay
	option start_daemon '1'
	option start_delay '60'

config global_forwarding
	option tcp_no_redir_ports 'disable'
	option udp_no_redir_ports 'disable'
	option tcp_proxy_drop_ports 'disable'
	option udp_proxy_drop_ports '443'
	option tcp_redir_ports '1:65535'
	option udp_redir_ports '53'
	option accept_icmp '0'
	option use_nft '1'
	option tcp_proxy_way 'tproxy'
	option ipv6_tproxy '1'
	option accept_icmpv6 '0'

config global_xray
	option sniffing_override_dest '1'
	option fragment '0'
	option noise '0'

config global_singbox
	option sniff_override_destination '0'

config global_other
	option auto_detection_time 'tcping'
	option url_test_url 'https://www.google.com/generate_204'

config global_rules
	option auto_update '0'
	option chnlist_update '1'
	option chnroute_update '1'
	option chnroute6_update '1'
	option gfwlist_update '0'
	option geosite_update '0'
	option geoip_update '0'
	option v2ray_location_asset '/usr/share/v2ray/'
	option geoip_url 'https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat'
	option geosite_url 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
	list gfwlist_url 'https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/telegram'
	list chnroute_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/Discord.lst'
	list chnroute_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/Twitter.lst'
	list chnroute_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/cloudflare.lst'
	list chnroute_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/ovh.lst'
	list chnroute_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/telegram.lst'
	list chnroute_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/roblox.lst'
	list chnroute6_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv4/ovh.lst'
	list chnroute6_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Subnets/IPv6/telegram.lst'
	list direct_host 'youtube.com'
	list direct_host 'ytimg.com'
	list direct_host 'yting.com'
	list direct_host 'ggpht.com'
	list direct_host 'googlevideo.com'
	list direct_host 'youtubekids.com'
	list direct_host 'youtu.be'
	list direct_host 'yt.be'
	list direct_host 'youtube-nocookie.com'
	list direct_host 'wide-youtube.l.google.com'
	list direct_host 'ytimg.l.google.com'
	list direct_host 'youtubei.googleapis.com'
	list direct_host 'youtubeembeddedplayer.googleapis.com'
	list direct_host 'youtube-ui.l.google.com'
	list direct_host 'yt-video-upload.l.google.com'
	list direct_host 'instagram.com'
	list direct_host 'ig.me'
	list direct_host 'facebook.com'
	list direct_host 'facebook.net'
	list direct_host 'cdninstagram.com'
	list direct_host 'fbcdn.net'
	list direct_host 'fbsbx.com'
	list direct_host 'internalfb.com'
	list direct_host 'oculus.com'
	list direct_host 'meta.com'
	list direct_host 'threads.net'
	list direct_host 'fb.com'
	list direct_host 'whatsapp.com'
	list direct_host 'whatsapp.net'
	list direct_host 'whatsapp.biz'
	list direct_host 'wa.me'
	list direct_host 'circlecrewpinkcrowd.com'
	list direct_host 'jnn-pa.googleapis.com'
	list direct_host 'returnyoutubedislikeapi.com'
	list direct_host 'yt3.googleusercontent.com'
	option geo2rule '0'
	option enable_geoview '0'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/geoblock.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/google_ai.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/hdrezka.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/discord.lst'
	list chnlist_url 'https://github.com/itdoginfo/allow-domains/blob/main/Services/hetzner.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/roblox.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/tiktok.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/twitter.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/anime.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/block.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/news.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/hodca.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/meta.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/porn.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/cloudflare.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/telegram.lst'
	list chnlist_url 'https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/google_play.lst'

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
	list filter_keep_list 't--8g.atlanta-vpn.com'
	list filter_keep_list 't--8g.atlanta-subs.ru'

config subscribe_list
	option remark 'Atlant'
	option url 'https://t--8g.atlanta-vpn.com/3mh3TXJqrXm31N__'
	option allowInsecure '0'
	option filter_keyword_mode '5'
	option ss_type 'global'
	option trojan_type 'global'
	option vmess_type 'global'
	option vless_type 'global'
	option domain_strategy 'global'
	option auto_update '1'
	option user_agent 'passwall'
	option week_update '8'
	option interval_update '6'
	option md5 '5dc5434e5c00defb4624427323872d72'

config nodes '7usGKVwg'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '⚡️ Авто (самый быстрый)'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address '202.148.53.126'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes '3J0a5OyD'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '🇳🇱 Нидерланды'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'nl-3.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes '5PGe6H1U'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '🇩🇪 Германия 2'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'de-2.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'Nf0aqDvC'
	option tls '0'
	option type 'Xray'
	option protocol 'vless'
	option encryption 'none'
	option group 'Atlant'
	option tls_allowInsecure '0'
	option ws_path '/api'
	option port '449'
	option transport 'ws'
	option address '146.185.208.245'
	option remarks '🇸🇪 Швеция'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option timeout '60'
	option add_mode '2'

config nodes 'YQ02cGf4'
	option tls '0'
	option type 'Xray'
	option protocol 'vless'
	option encryption 'none'
	option group 'Atlant'
	option tls_allowInsecure '0'
	option ws_path '/api'
	option port '449'
	option transport 'ws'
	option address '193.233.132.163'
	option remarks '🇷🇺 Россия 3 (🔥 Новые блокировки)'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option timeout '60'
	option add_mode '2'

config nodes 'qiA5lpON'
	option tls '0'
	option type 'Xray'
	option protocol 'vless'
	option encryption 'none'
	option group 'Atlant'
	option tls_allowInsecure '0'
	option ws_path '/api'
	option port '449'
	option transport 'ws'
	option address '151.245.139.6'
	option remarks '🇫🇮 Финляндия (🔥 Новые блокировки)'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option timeout '60'
	option add_mode '2'

config nodes '6DuqbdMx'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '443'
	option remarks '🇩🇪 Германия'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address '151.243.171.20'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'lYRpmAtd'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '🇫🇷 Франция'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'fr.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'IPJftxol'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '🇷🇺 Россия'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'ru.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'QOouQ8g2'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '🇷🇺 Россия 2'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option tls_allowInsecure '0'
	option fingerprint 'random'
	option reality_shortId 'ffffffffff'
	option reality_spiderX '/'
	option tls '1'
	option tls_serverName 'static.rutube.ru'
	option reality '1'
	option reality_publicKey 'a_LbD81zTm6S8JtU98gY00xqsPOEucV4k0OEx0LOwgQ'
	option address 'third-legend.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'npOWN7nZ'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '8443'
	option remarks '🇵🇱 Польша'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'pl.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'LEY1C7BM'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '443'
	option remarks '🇺🇸 США'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'us.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'WBtGAdJr'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group 'Atlant'
	option port '443'
	option remarks '🇭🇰 Гонконг'
	option add_mode '2'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option tls_allowInsecure '0'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'hk.atlanta-internet.ru'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

config nodes 'G2tpDhJu'
	option tls '0'
	option type 'Xray'
	option protocol 'vless'
	option encryption 'mlkem768x25519plus.native.0rtt.SxcU0cR5hjk4VJeSGIoUE8Y3OEMUA3cUq1MSBrl3f9Cv5FIi0VFMO2ki_NGgOyuAY_swH8m_6XqXOneOUeqmx9kqHaXA_7GLCocrj5gWWVIncRQpI9haQWZVNDi4WgVBipILoDYcB2RjD1kM5hCk1emdJjypPWKcvcSOFHUgWup_8alQAyqD7KBsIOdoz7y7DtcP2TVjvoE3YVNPwGwCLYlMzWwVQXWoJgR2bsoz--G0DgKXBJkSLJN_qRViL-QooQSRgTB0K9FffEZgC4nF9lXPw4ZbwHyFCMmGeKSv8dsBHUuldXsDSKRy7XUrKckCpLaL14g_R8BS8XMvrZIw7VJZwjwYHog3Y2eZAKe6lObEOua6gjI2VmWph3dZS0w9WKZZUqilXZRKJ4BWkwF4eat4wVZ8lOsw_HwxC1vOnkFPfvROvdOa5mKdEINgbblOOCmMIKK9jqURD8gug9sMfQSWf-fO0ka4r6Amo-IC5NpXYlqy3fQmmNQHZlY7tykSiadn6XWGI6i6uQSHj6CzBtubzzeGjnZ-ThCFhlmeRqgpfmhrIQwbySGSkHO1aIw6kEyFoNprQ6Sy-XybqiN1Ols-cyBk10Smnwkz1gAL1lVH4EkoZPhJtRcqwHhfwuq4yENQ6CojPxEwe6w_kIyMkKpM7AQaESnL48EMG1w2UBBLQlSETUJ-m3moL6mQgJCUiujNeSt1OJqHX_aAM0aaSOMZI_FymEuFe4bJreuHV2bBUGkcoVPNOmQfseeDOrsyJbxLtddQR0NzcDDChcsnInxYgrxAP7iDGchMsZmrovgKUDic1cNIc9tbvQrICRdmDPgfNWCV_8QGnWgsSQApJuILFlgEXIEFhSfOPbINXAF0qBmg8OcZz8mYsipfQcVvARkx0KGEqNFjjXlozsqUohrL1iN-TWQC3VAJAqLEzeZ1MRCVbqhcnWE_iMCmuowrYtsY7tez_BCRmKdpLEB06cgXFMA5QSS4dWNqb9J8bEe2m-h-0KiPB5BklyJdI1qr6egv3kVg5-bAlHioMJVAtqhoZlrJMcipVVli1wHIDWUcNdsLCzSTc2OEhYQuzrV40satQWUOFjSvOPcumBKkiscT6yqc3wYekrEO5UJ4xvvNSKojZKUzxUE7c_Q_Rik8JxdZ-LEF4Lw-BijGlcF9H8nBWbuoaPcgu4tZz0QeDzE7vQGaSMOEDeHJJQtzMJUUegsXAshCDjN9VYiAY0mxBPCa4jicxEQG7JwMQFMd0Yibe5unQKnCAnhHBnZNMWyLC-gRl0dvrmtVhsEcz6ZTQVwT5soQxkIjBtZvxtkUHVE39-OPhup7XMhFQXlL7OiJ1DU1fous-bdp6nXKIxEstslxNakIgWlPWpqxVeEpDYLJyYh_3EYDaGVKLyBmpga8DggdxuCCAjeRwGqhqHDPWwAKk8wUBzpJUzlEiwoKmbpOlPyZC9FWdFMCUWtO90xazCXNNvuGa5UogsrCxPtHvmdY_MuSuktC-SOti5IEzzp7n2vHn-AjiNYdEMxen7k05ECcRjFZ_C726HjlwsPvnbM6ktoVaGiVLvdxJTzIfGo'
	option group 'Atlant'
	option tls_allowInsecure '0'
	option ws_path '/api'
	option port '449'
	option transport 'ws'
	option address 'lt.atlanta-internet.ru'
	option remarks '🇱🇹 Литва'
	option uuid 'c6f64738-d8ac-445d-a292-31d333c6edb8'
	option timeout '60'
	option add_mode '2'

config subscribe_list
	option remark '3242'
	option url 'https://t--8g.atlanta-subs.ru/Mpwgs3VPGZPCqa9d'
	option allowInsecure '0'
	option filter_keyword_mode '5'
	option ss_type 'global'
	option trojan_type 'global'
	option vmess_type 'global'
	option vless_type 'global'
	option domain_strategy 'global'
	option auto_update '0'
	option user_agent 'v2rayN/9.99'
	option md5 'db5042d15ab6c44000c157d6e4a8886a'

config nodes 'YI0ygqCI'
	option flow 'xtls-rprx-vision'
	option protocol 'vless'
	option tcp_guise 'none'
	option group '3242'
	option port '443'
	option add_mode '2'
	option tls_allowInsecure '0'
	option type 'Xray'
	option timeout '60'
	option fingerprint 'safari'
	option remark 'test router'
	option tls '1'
	option tls_serverName 'pingless.com'
	option reality '1'
	option reality_publicKey 'FscaEWx0paNBzL7GWHj4Fll7Xc-KxdhKgTthBAnByWI'
	option address 'qq'
	option uuid 'a2f53c42-feb4-419b-96b9-8f80cab0ee63'
	option encryption 'none'
	option utls '1'
	option transport 'raw'

EOF_PASSWALL

# ── 4. Запись конфига PassWall Server ────────────────────────
cat > /etc/config/passwall_server << 'EOF_SERVER'

config global 'global'
	option enable '0'

EOF_SERVER

log "Конфиги записаны"

# ── 5. Применяем и запускаем ─────────────────────────────────
uci commit passwall 2>/dev/null
uci commit passwall_server 2>/dev/null

/etc/init.d/passwall enable 2>/dev/null
/etc/init.d/passwall restart

log "PassWall запущен!"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║        ✅ Установка завершена!       ║"
echo "  ║                                      ║"
echo "  ║  Узлы: Авто / NL / DE / SE / FR      ║"
echo "  ║        RU / PL / US / HK / LT / FI   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
uci commit system
/etc/init.d/zram enable
/etc/init.d/zram start
free -m
cat /proc/swaps
