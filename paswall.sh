cat >/tmp/atl_pw_auto.sh <<'EOF'
#!/bin/sh
set -eu

PASSWALLX_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh"

# --- Fix broken UCI first ---
cp -f /etc/config/passwall /etc/config/passwall.broken.$(date +%s) 2>/dev/null || true
if [ -f /rom/etc/config/passwall ]; then
  cp -f /rom/etc/config/passwall /etc/config/passwall
else
  cat >/etc/config/passwall <<'EOC'
config global
  option enabled '0'
EOC
fi
uci -q show passwall >/dev/null 2>&1 || { echo "UCI parse error still present"; exit 1; }

# --- Ask subscription URL (tty if possible) ---
EXISTING="$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || true)"
echo "[Atlanta] Paste subscription URL (Enter=keep current): ${EXISTING:-<empty>}"
SUB_URL=""
if [ -r /dev/tty ]; then
  printf "URL> " >/dev/tty
  IFS= read -r SUB_URL </dev/tty || true
else
  printf "URL> "
  IFS= read -r SUB_URL || true
fi
[ -z "${SUB_URL:-}" ] && SUB_URL="$EXISTING"
[ -n "${SUB_URL:-}" ] || { echo "Empty URL"; exit 1; }

# --- Install PassWall via upstream ---
TMP="/tmp/passwallx.sh"
rm -f "$TMP"
if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -O "$TMP" "$PASSWALLX_URL"
else
  wget -O "$TMP" "$PASSWALLX_URL"
fi
chmod +x "$TMP"
sh "$TMP"

# --- Ensure required sections exist ---
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

# --- Apply core settings ---
uci -q set "$GLOBAL.enabled=1"
uci -q set "$GLOBAL.dns_shunt=dnsmasq"
uci -q set "$GLOBAL.dns_mode=xray"
uci -q set "$GLOBAL.remote_dns=8.8.8.8"
uci -q set "$GLOBAL.dns_redirect=1"
uci -q set "$GLOBAL.chn_list=proxy"
uci -q set "$GLOBAL.localhost_proxy=1"
uci -q set "$GLOBAL.client_proxy=1"

uci -q set "$FWD.prefer_nft=1" 2>/dev/null || true

# Rules URLs (твои)
uci -q delete "$RULES.chnlist_url" 2>/dev/null || true
uci -q delete "$RULES.chnroute_url" 2>/dev/null || true
uci -q add_list "$RULES.chnroute_url=https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/ipchik.lst"
uci -q add_list "$RULES.chnroute_url=https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/ipchik.lst"
uci -q add_list "$RULES.chnroute_url=https://storage.yandexcloud.net/234588/ipchik.lst"
uci -q add_list "$RULES.chnlist_url=https://raw.githubusercontent.com/UnionUnllimited/domensrouter/refs/heads/main/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=https://1222.hb.ru-msk.vkcloud-storage.ru/domenchik/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=http://origin.all-streams-24.ru/domenchik.lst"
uci -q add_list "$RULES.chnlist_url=https://storage.yandexcloud.net/234588/domenchik.lst"

# --- Subscribe section: reset + set URL ---
for s in $(uci -q show passwall | sed -n "s/^passwall\.\([^=]*\)=subscribe_list.*/\1/p"); do
  uci -q delete "passwall.$s" 2>/dev/null || true
done
SUBSEC="$(uci -q add passwall subscribe_list)"
uci -q set "passwall.$SUBSEC.remark=AtlantaRouter"
uci -q set "passwall.$SUBSEC.url=$SUB_URL"
uci -q delete "passwall.$SUBSEC.md5" 2>/dev/null || true

uci -q commit passwall

# --- Write rules files visible in LuCI ---
mkdir -p /usr/share/passwall/rules /etc/passwall/rules /etc/passwall 2>/dev/null || true
cat >/usr/share/passwall/rules/direct_host <<'EOL'
#ATLANTA_DIRECT_HOST
youtube.com
googlevideo.com
ytimg.com
youtu.be
EOL
: > /usr/share/passwall/rules/direct_ip

cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/proxy_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_host /usr/share/passwall/rules/route_host 2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/proxy_ip   2>/dev/null || true
cp -f /usr/share/passwall/rules/direct_ip   /usr/share/passwall/rules/route_ip   2>/dev/null || true

# --- Update subscribe now (best-effort) ---
if command -v lua >/dev/null 2>&1 && [ -f /usr/share/passwall/subscribe.lua ]; then
  lua /usr/share/passwall/subscribe.lua >/tmp/atl_subscribe.log 2>&1 || true
fi

# --- Restart services ---
/etc/init.d/passwall restart 2>/dev/null || /etc/init.d/passwall start 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

echo "[Atlanta] Done."
echo "URL=$(uci -q get passwall.@subscribe_list[0].url 2>/dev/null || echo '?')"
echo "Subscribe log: tail -n 60 /tmp/atl_subscribe.log 2>/dev/null || true"
EOF
chmod +x /tmp/atl_pw_auto.sh
sh /tmp/atl_pw_auto.sh
