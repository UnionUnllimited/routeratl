cat <<'EOF' > /tmp/install_atlanta_panel_full_lan14.sh
#!/bin/sh
set -eu

CGI_DIR="/www/cgi-bin"
PANEL="$CGI_DIR/panel"
CONF="/etc/config/atl_panel"

LAN_IP="192.168.14.1"
LAN_MASK="255.255.255.0"

WIFI_SSID_24="Atlanta 2.4Ghz"
WIFI_SSID_5="Atlanta 5Ghz"
WIFI_KEY="11111111"

mkdir -p "$CGI_DIR"
mkdir -p /etc/config

[ -f "$CONF" ] || cat >"$CONF" <<'UCI'
config atl_panel 'main'
  option user 'admin'
  option pass 'admin'
  option upd_version_url 'https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/version.txt'
  option upd_script_url 'https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/update.sh'
  option youtube_mode 'main'
UCI

cat >"$PANEL" <<'PANELFILE'
#!/bin/sh
set -eu

LINK_SUB="https://t.me/AtlantaVPN_bot"
LINK_SUPPORT="https://t.me/AtlantaVPNSUPPORT_bot"

CONF="/etc/config/atl_panel"
LOG="/tmp/atl_panel_passwall_update.log"
UPD_LOG="/tmp/atl_panel_update.log"
UPD_STATE="/etc/atl_panel_update_state"
LOCK="/tmp/atl_panel_update.lock"
OPKG_LOG="/tmp/atl_panel_opkg.log"
L2TP_LOCK="/tmp/atl_panel_l2tp_install.lock"
PPTP_LOCK="/tmp/atl_panel_pptp_install.lock"

touch "$LOG" "$UPD_LOG" "$OPKG_LOG" 2>/dev/null || true
chmod 666 "$LOG" "$UPD_LOG" "$OPKG_LOG" 2>/dev/null || true

[ -f "$CONF" ] || {
  mkdir -p /etc/config
  cat > "$CONF" <<'UCI'
config atl_panel 'main'
  option user 'admin'
  option pass 'admin'
  option upd_version_url 'https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/version.txt'
  option upd_script_url 'https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/update.sh'
  option youtube_mode 'main'
UCI
}

getcfg(){ uci -q get atl_panel.main."$1" 2>/dev/null || true; }
setcfg(){ uci -q set atl_panel.main."$1"="$2" 2>/dev/null || true; }
commitcfg(){ uci -q commit atl_panel 2>/dev/null || true; }

html_escape(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
strip_newlines(){ tr -d '\r\n'; }
trim_spaces(){ awk '{gsub(/^[ \t]+|[ \t]+$/,""); print}'; }

is_ascii(){ printf "%s" "$1" | LC_ALL=C grep -q '^[ -~]*$'; }
is_ascii_nospace(){ printf "%s" "$1" | LC_ALL=C grep -q '^[!-~]*$'; }
len_ge_5(){ [ "$(printf "%s" "$1" | wc -c | tr -d ' ')" -ge 5 ]; }
len_ge_8(){ [ "$(printf "%s" "$1" | wc -c | tr -d ' ')" -ge 8 ]; }

is_ipv4(){
  printf "%s" "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])$'
}

urldecode(){
  sed 's/+/ /g' | awk '
    BEGIN{ ORS=""; }
    {
      while (match($0, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
        hex = substr($0, RSTART+1, 2)
        pre = substr($0, 1, RSTART-1)
        post = substr($0, RSTART+3)
        printf "%s", pre
        printf "%c", strtonum("0x" hex)
        $0 = post
      }
      print $0
    }'
}

qenc(){
  printf "%s" "$1" | sed \
    -e 's/%/%25/g' \
    -e 's/&/%26/g' \
    -e 's/?/%3F/g' \
    -e 's/=/%3D/g' \
    -e 's/+/%2B/g' \
    -e 's/ /%20/g'
}

redir(){
  msg="$(qenc "${1:-}")"
  err="$(qenc "${2:-}")"
  upd="$(qenc "${3:-}")"
  echo "Status: 303 See Other"
  echo "Location: /cgi-bin/panel?m=$msg&e=$err&u=$upd"
  echo ""
  exit 0
}

fetch(){
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 120 "$url"
  else
    wget -qO- --timeout=120 "$url"
  fi
}

apply_update_script(){
  script_url="$1"
  tmp="/tmp/atl_update.sh"
  echo "=== $(date) manual update start ===" >> "$UPD_LOG"
  if fetch "$script_url" > "$tmp" 2>>"$UPD_LOG"; then
    chmod +x "$tmp"
    sh "$tmp" >> "$UPD_LOG" 2>&1 || true
  fi
  echo "=== $(date) manual update end ===" >> "$UPD_LOG"
}

MAC="$(cat /sys/class/net/br-lan/address 2>/dev/null | tr '[:lower:]' '[:upper:]' || echo N/A)"

detect_wan_iface(){
  if uci -q show firewall >/dev/null 2>&1; then
    IFACE="$(uci -q show firewall | awk -F"'" '
      BEGIN{z=0}
      /^config zone/{z=0}
      /option name '\''wan'\''/{z=1}
      z==1 && /list network/{print $2; exit}
    ')"
    [ -n "${IFACE:-}" ] && { echo "$IFACE"; return 0; }
  fi
  echo "wan"
}

ensure_wan_zone_has_iface(){
  _iface="${1:-wan}"
  idx="$(uci -q show firewall | awk '
    $1=="config" && $2=="zone" {i++}
    $1=="option" && $2=="name" && $3=="'\''wan'\''" {print i-1; exit}
  ' 2>/dev/null || true)"
  [ -n "${idx:-}" ] || return 0
  if uci -q show firewall.@zone["$idx"].network 2>/dev/null | grep -qw "$_iface"; then
    return 0
  fi
  uci -q add_list firewall.@zone["$idx"].network="$_iface" || true
  uci -q commit firewall >/dev/null 2>&1 || true
}

has_l2tp(){ [ -f /lib/netifd/proto/l2tp.sh ]; }
has_pptp(){ [ -f /lib/netifd/proto/pptp.sh ]; }

l2tp_install_bg_once(){
  has_l2tp && return 0
  command -v opkg >/dev/null 2>&1 || return 0
  now="$(date +%s)"
  if [ -f "$L2TP_LOCK" ]; then
    ts="$(cat "$L2TP_LOCK" 2>/dev/null || echo 0)"
    age=$((now - ts))
    [ "$age" -ge 0 ] && [ "$age" -lt 1800 ] && return 0
  fi
  echo "$now" > "$L2TP_LOCK" 2>/dev/null || true
  chmod 666 "$L2TP_LOCK" 2>/dev/null || true
  (
    {
      echo "=== $(date) L2TP install (bg) ==="
      opkg update || true
      for p in luci-proto-l2tp xl2tpd ppp ppp-mod-pppol2tp kmod-pppol2tp kmod-l2tp; do
        opkg install "$p" || true
      done
      echo "=== done ==="
    } >>"$OPKG_LOG" 2>&1
  ) >/dev/null 2>&1 &
}

pptp_install_bg_once(){
  has_pptp && return 0
  command -v opkg >/dev/null 2>&1 || return 0
  now="$(date +%s)"
  if [ -f "$PPTP_LOCK" ]; then
    ts="$(cat "$PPTP_LOCK" 2>/dev/null || echo 0)"
    age=$((now - ts))
    [ "$age" -ge 0 ] && [ "$age" -lt 1800 ] && return 0
  fi
  echo "$now" > "$PPTP_LOCK" 2>/dev/null || true
  chmod 666 "$PPTP_LOCK" 2>/dev/null || true
  (
    {
      echo "=== $(date) PPTP install (bg) ==="
      opkg update || true
      for p in luci-proto-ppp ppp ppp-mod-pptp kmod-gre kmod-ppp kmod-pppox; do
        opkg install "$p" || true
      done
      echo "=== done ==="
    } >>"$OPKG_LOG" 2>&1
  ) >/dev/null 2>&1 &
}

l2tp_install_bg_once || true
pptp_install_bg_once || true

pw_exists(){
  [ -f /etc/config/passwall ]
}

normalize_server_label(){
  s="$1"
  s="${s#Router_}"
  s="${s#router_}"
  printf "%s" "$s"
}

pw_current_node(){
  uci -q get passwall.@global[0].tcp_node 2>/dev/null || true
}

pw_node_label(){
  node="$1"
  [ -n "$node" ] || return 0
  label="$(uci -q get passwall."$node".remarks 2>/dev/null || true)"
  [ -n "$label" ] || label="$(uci -q get passwall."$node".address 2>/dev/null || true)"
  [ -n "$label" ] || label="$node"
  case "$label" in
    AtlantaSwitch|ATLANTASWITCH|atlantaswitch) label="Авто (балансер)" ;;
  esac
  case "$node" in
    *AtlantaSwitch*|*ATLANTASWITCH*|*atlantaswitch*) label="Авто (балансер)" ;;
  esac
  normalize_server_label "$label"
}

pw_nodes_list(){
  uci -q show passwall 2>/dev/null | awk -F"[.=']" '
    /\.remarks=/{
      sec=$2; val=$0;
      sub(/^.*='\''/,"",val); sub(/'\''$/,"",val);
      rem[sec]=val;
    }
    /\.address=/{
      sec=$2; val=$0;
      sub(/^.*='\''/,"",val); sub(/'\''$/,"",val);
      if(!(sec in rem) || rem[sec]=="") rem[sec]=val;
    }
    END{
      for (k in rem) {
        if (k ~ /^@global/ || k ~ /^@acl/ || k ~ /^@rules/ || k ~ /^@balancing/ || k ~ /^@balancer/) continue;
        print k "\t" rem[k];
      }
    }' | sort
}

pw_apply_node(){
  node="$1"
  [ -n "$node" ] || return 1
  uci -q set passwall.@global[0].tcp_node="$node" 2>/dev/null || true
  uci -q set passwall.@global[0].udp_node="$node" 2>/dev/null || true
  uci -q commit passwall >/dev/null 2>&1 || true
  /etc/init.d/passwall restart >/dev/null 2>&1 || true
}

get_direct_file(){
  for f in \
    /usr/share/passwall/rules/direct_host \
    /etc/passwall/direct_host \
    /usr/share/passwall/rules/direct_host_v2 \
    /tmp/dnsmasq.d/direct_host
  do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  mkdir -p /usr/share/passwall/rules 2>/dev/null || true
  touch /usr/share/passwall/rules/direct_host 2>/dev/null || true
  echo /usr/share/passwall/rules/direct_host
}

yt_domains(){
  cat <<DOMAINS
youtube.com
www.youtube.com
m.youtube.com
youtu.be
youtubei.googleapis.com
youtube.googleapis.com
googlevideo.com
ytimg.com
youtube-nocookie.com
yt3.ggpht.com
i.ytimg.com
DOMAINS
}

direct_add_youtube(){
  f="$(get_direct_file)"
  tmp="/tmp/atl_direct_youtube.$$"
  touch "$f"
  cp "$f" "$tmp" 2>/dev/null || true
  yt_domains | while IFS= read -r d; do
    [ -n "$d" ] || continue
    grep -qxF "$d" "$tmp" 2>/dev/null || echo "$d" >> "$tmp"
  done
  awk 'NF && !seen[$0]++' "$tmp" > "$f"
  rm -f "$tmp"
}

direct_remove_youtube(){
  f="$(get_direct_file)"
  tmp="/tmp/atl_direct_youtube.$$"
  touch "$f"
  cp "$f" "$tmp" 2>/dev/null || true
  grep -vxF -f /dev/stdin "$tmp" > "$f" <<DOMAINS
youtube.com
www.youtube.com
m.youtube.com
youtu.be
youtubei.googleapis.com
youtube.googleapis.com
googlevideo.com
ytimg.com
youtube-nocookie.com
yt3.ggpht.com
i.ytimg.com
DOMAINS
  rm -f "$tmp"
}

zapret_start(){
  [ -x /etc/init.d/zapret ] && {
    /etc/init.d/zapret enable >/dev/null 2>&1 || true
    /etc/init.d/zapret restart >/dev/null 2>&1 || /etc/init.d/zapret start >/dev/null 2>&1 || true
    return 0
  }
  pgrep -f nfqws >/dev/null 2>&1 && return 0
  return 0
}

zapret_stop(){
  [ -x /etc/init.d/zapret ] && {
    /etc/init.d/zapret stop >/dev/null 2>&1 || true
    /etc/init.d/zapret disable >/dev/null 2>&1 || true
  }
  killall nfqws 2>/dev/null || true
}

bypass_state(){
  pw=0
  zp=0
  [ -x /etc/init.d/passwall ] && /etc/init.d/passwall enabled >/dev/null 2>&1 && pw=1 || true
  pgrep -f '[n]fqws' >/dev/null 2>&1 && zp=1 || true
  if [ "$pw" = "1" ] || [ "$zp" = "1" ]; then
    echo "on"
  else
    echo "off"
  fi
}

passwall_reload_soft(){
  [ -x /etc/init.d/passwall ] && /etc/init.d/passwall reload >/dev/null 2>&1 || true
  [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
}

main_mode_start(){
  direct_add_youtube
  zapret_start
  setcfg youtube_mode main
  uci -q commit atl_panel >/dev/null 2>&1 || true
  passwall_reload_soft
}

backup_mode_start(){
  direct_remove_youtube
  zapret_stop
  setcfg youtube_mode backup
  uci -q commit atl_panel >/dev/null 2>&1 || true
  passwall_reload_soft
}

bypass_enable_all(){
  [ -x /etc/init.d/passwall ] && {
    /etc/init.d/passwall enable >/dev/null 2>&1 || true
    /etc/init.d/passwall start >/dev/null 2>&1 || /etc/init.d/passwall restart >/dev/null 2>&1 || true
  }
  zapret_start
  passwall_reload_soft
}

bypass_disable_all(){
  [ -x /etc/init.d/passwall ] && {
    /etc/init.d/passwall stop >/dev/null 2>&1 || true
    /etc/init.d/passwall disable >/dev/null 2>&1 || true
  }
  zapret_stop
}

apply_panel_auth(){
  nu="$1"; np="$2"
  if setcfg user "$nu" && setcfg pass "$np" && commitcfg; then
    sync 2>/dev/null || true
    return 0
  fi
  tmp="/tmp/atl_panel.$$.$RANDOM"
  cat >"$tmp" <<UCI
config atl_panel 'main'
  option user '$nu'
  option pass '$np'
  option upd_version_url '$(getcfg upd_version_url)'
  option upd_script_url '$(getcfg upd_script_url)'
  option youtube_mode '$(getcfg youtube_mode)'
UCI
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONF"
  sync 2>/dev/null || true
  uci -q revert atl_panel 2>/dev/null || true
  return 0
}

QS="${QUERY_STRING:-}"
GET_M="$(printf "%s" "$QS" | tr '&' '\n' | sed -n 's/^m=//p' | head -n1 | urldecode 2>/dev/null || true)"
GET_E="$(printf "%s" "$QS" | tr '&' '\n' | sed -n 's/^e=//p' | head -n1 | urldecode 2>/dev/null || true)"
GET_U="$(printf "%s" "$QS" | tr '&' '\n' | sed -n 's/^u=//p' | head -n1 | urldecode 2>/dev/null || true)"

MSG="${GET_M:-}"
ERR="${GET_E:-}"
UPD_STATUS=""
UPD_COLOR=""

if [ -n "${GET_U:-}" ]; then
  case "$GET_U" in
    ok)  UPD_STATUS="✅ Обновление выполнено успешно."; UPD_COLOR="ok" ;;
    bad) UPD_STATUS="❌ Не удалось выполнить обновление. Если проблема повторяется — напишите в поддержку."; UPD_COLOR="bad" ;;
  esac
fi

FORM_action=""
FORM_user=""
FORM_pass=""
FORM_new_user=""
FORM_new_pass=""
FORM_wan_proto=""
FORM_pppoe_user=""
FORM_pppoe_pass=""
FORM_l2tp_server=""
FORM_l2tp_user=""
FORM_l2tp_pass=""
FORM_pptp_server=""
FORM_pptp_user=""
FORM_pptp_pass=""
FORM_static_ip=""
FORM_static_mask=""
FORM_static_gw=""
FORM_static_dns1=""
FORM_static_dns2=""
FORM_ssid_24=""
FORM_key_24=""
FORM_ssid_5=""
FORM_key_5=""
FORM_pw_node=""
FORM_yt_mode=""

if [ "${REQUEST_METHOD:-}" = "POST" ]; then
  len="${CONTENT_LENGTH:-0}"
  if [ "$len" -gt 0 ]; then
    if read -r -n "$len" POST_DATA 2>/dev/null; then :; else POST_DATA="$(dd bs=1 count="$len" 2>/dev/null)"; fi
    POST_DATA="$(printf "%s" "$POST_DATA" | tr '\r\n' '  ')"
    OLDIFS="$IFS"; IFS="&"; set -- $POST_DATA; IFS="$OLDIFS"
    for pair in "$@"; do
      k="${pair%%=*}"
      v="${pair#*=}"
      [ -n "$k" ] || continue
      v_dec="$(printf "%s" "${v:-}" | urldecode | strip_newlines)"
      case "$k" in
        action) FORM_action="$v_dec" ;;
        user) FORM_user="$v_dec" ;;
        pass) FORM_pass="$v_dec" ;;
        new_user) FORM_new_user="$v_dec" ;;
        new_pass) FORM_new_pass="$v_dec" ;;
        wan_proto) FORM_wan_proto="$v_dec" ;;
        pppoe_user) FORM_pppoe_user="$v_dec" ;;
        pppoe_pass) FORM_pppoe_pass="$v_dec" ;;
        l2tp_server) FORM_l2tp_server="$v_dec" ;;
        l2tp_user) FORM_l2tp_user="$v_dec" ;;
        l2tp_pass) FORM_l2tp_pass="$v_dec" ;;
        pptp_server) FORM_pptp_server="$v_dec" ;;
        pptp_user) FORM_pptp_user="$v_dec" ;;
        pptp_pass) FORM_pptp_pass="$v_dec" ;;
        static_ip) FORM_static_ip="$v_dec" ;;
        static_mask) FORM_static_mask="$v_dec" ;;
        static_gw) FORM_static_gw="$v_dec" ;;
        static_dns1) FORM_static_dns1="$v_dec" ;;
        static_dns2) FORM_static_dns2="$v_dec" ;;
        ssid_24) FORM_ssid_24="$v_dec" ;;
        key_24) FORM_key_24="$v_dec" ;;
        ssid_5) FORM_ssid_5="$v_dec" ;;
        key_5) FORM_key_5="$v_dec" ;;
        pw_node) FORM_pw_node="$v_dec" ;;
        yt_mode) FORM_yt_mode="$v_dec" ;;
      esac
    done
  fi
fi

need_auth=1

if [ "${FORM_action:-}" = "login" ]; then
  CUR_USER_CFG="$(getcfg user)"
  CUR_PASS_CFG="$(getcfg pass)"
  u_in="$(printf "%s" "$FORM_user" | trim_spaces)"
  p_in="$(printf "%s" "$FORM_pass" | strip_newlines)"
  if [ "$u_in" = "$CUR_USER_CFG" ] && [ "$p_in" = "$CUR_PASS_CFG" ]; then
    sid="$(date +%s)$$"
    echo "$sid" > /tmp/atl_panel_sid 2>/dev/null || true
    chmod 600 /tmp/atl_panel_sid 2>/dev/null || true
    echo "Status: 303 See Other"
    echo "Set-Cookie: ATLSESS=$sid; Path=/; HttpOnly"
    echo "Location: /cgi-bin/panel"
    echo ""
    exit 0
  else
    ERR="Неверный логин или пароль. Проверьте раскладку и попробуйте ещё раз."
  fi
fi

COOKIE="${HTTP_COOKIE:-}"
SID_COOKIE="$(printf "%s" "$COOKIE" | tr ';' '\n' | sed -n 's/^[[:space:]]*ATLSESS=//p' | head -n1 | strip_newlines)"
SID_FILE="$(cat /tmp/atl_panel_sid 2>/dev/null || true)"

if [ -n "$SID_COOKIE" ] && [ -n "$SID_FILE" ] && [ "$SID_COOKIE" = "$SID_FILE" ]; then
  need_auth=0
fi

if [ "${FORM_action:-}" = "logout" ]; then
  rm -f /tmp/atl_panel_sid 2>/dev/null || true
  echo "Status: 303 See Other"
  echo "Set-Cookie: ATLSESS=deleted; Path=/; Max-Age=0"
  echo "Location: /cgi-bin/panel"
  echo ""
  exit 0
fi

if [ "$need_auth" = "1" ]; then
  echo "Content-type: text/html; charset=utf-8"
  echo ""
  ES_ERR="$(printf "%s" "${ERR:-}" | html_escape)"
  ES_MSG="$(printf "%s" "${MSG:-}" | html_escape)"
  ES_MAC="$(printf "%s" "$MAC" | html_escape)"
  cat <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Atlanta Панель • Вход</title>
<style>
:root{--bg:#05070d;--txt:#eaf3ff;--mut:rgba(234,243,255,.62);--acc:#2fe6ff;--acc2:#2a7bff;--acc3:#7b5cff;--bad:#ff6b6b;--ok:#57f287}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 700px at 18% 12%, rgba(0,176,255,.22), transparent 60%),radial-gradient(1000px 520px at 85% 18%, rgba(96,71,255,.18), transparent 58%),linear-gradient(180deg,#05070d,#070b14);color:var(--txt);font:14px/1.4 system-ui,-apple-system,Segoe UI,Roboto}
.wrap{max-width:520px;margin:0 auto;padding:26px}
.card{margin-top:42px;background:linear-gradient(180deg,rgba(255,255,255,.07),rgba(255,255,255,.03));border:1px solid rgba(255,255,255,.10);border-radius:18px;padding:16px;box-shadow:0 20px 60px rgba(0,0,0,.45)}
h1{margin:0 0 8px;font-size:18px;text-align:center}
.sub{color:var(--mut);font-size:12px;margin-bottom:12px;text-align:center}
label{display:block;color:var(--mut);font-size:12px;margin:10px 0 6px}
input{width:100%;background:rgba(0,0,0,.28);border:1px solid rgba(255,255,255,.12);color:var(--txt);padding:12px;border-radius:14px;min-height:44px;font-size:16px}
.btn{border:0;border-radius:14px;padding:12px 14px;font-weight:950;color:#041018;background:linear-gradient(90deg,var(--acc),var(--acc2),var(--acc3));cursor:pointer;min-height:44px;width:100%;margin-top:12px}
.btn.secondary{background:rgba(255,255,255,.08);color:var(--txt);border:1px solid rgba(255,255,255,.12)}
.err{margin-top:12px;padding:10px 12px;border-radius:14px;border:1px solid rgba(255,107,107,.25);background:rgba(255,107,107,.08)}
.msg{margin-top:12px;padding:10px 12px;border-radius:14px;border:1px solid rgba(87,242,135,.25);background:rgba(87,242,135,.08)}
.hint{margin-top:10px;color:var(--mut);font-size:12px;text-align:center}
.copywrap{display:grid;grid-template-columns:auto auto auto;gap:10px;align-items:center;justify-content:center;margin-top:10px}
.copyid{font-weight:900;letter-spacing:.3px}
.copybtn{border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.06);color:var(--txt);border-radius:12px;padding:8px 10px;cursor:pointer;min-height:38px}
.toast{display:inline-block;margin-left:6px;color:var(--ok);font-weight:900;opacity:0;transition:opacity .2s}
.toast.on{opacity:1}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
.row .btn{width:auto;flex:1;display:flex;align-items:center;justify-content:center;text-align:center}
@media (max-width: 900px), (hover: none) and (pointer: coarse){
  input,select,textarea{font-size:16px !important}
}
</style>
<script>
async function copyText(id){
  const el=document.getElementById(id);
  const t=el ? el.textContent.trim() : "";
  if(!t) return;
  try{ await navigator.clipboard.writeText(t); }
  catch(e){
    const ta=document.createElement('textarea');
    ta.value=t; document.body.appendChild(ta);
    ta.select(); document.execCommand('copy');
    ta.remove();
  }
  const toast=document.getElementById('copied');
  if(toast){
    toast.classList.add('on');
    setTimeout(()=>toast.classList.remove('on'),1200);
  }
}
</script>
</head>
<body>
<div class="wrap">
  <div class="card">
    <h1>Atlanta Панель</h1>
    <div class="sub">Введите логин и пароль для входа в панель управления.</div>

    <div class="copywrap">
      <span style="color:var(--mut);font-size:12px">MAC</span>
      <span id="mac" class="copyid">${ES_MAC}</span>
      <button class="copybtn" type="button" onclick="copyText('mac')">📋 Копировать</button>
      <span id="copied" class="toast">✅</span>
    </div>

    ${MSG:+<div class="msg">✅ ${ES_MSG}</div>}
    ${ERR:+<div class="err">❌ ${ES_ERR}</div>}

    <form method="POST" action="/cgi-bin/panel">
      <input type="hidden" name="action" value="login">
      <label>Логин</label>
      <input name="user" autocomplete="username">
      <label>Пароль</label>
      <input name="pass" type="password" autocomplete="current-password">
      <button class="btn" type="submit">Войти</button>
    </form>

    <div class="row">
      <a class="btn secondary" href="${LINK_SUPPORT}" target="_blank" rel="noopener">🎧 Поддержка (Telegram)</a>
      <a class="btn secondary" href="${LINK_SUB}" target="_blank" rel="noopener">💎 Подписка</a>
    </div>

    <div class="hint">Данные доступа по умолчанию: <b>admin / admin</b>. После входа откройте «Доступ к панели» и измените логин и пароль.</div>
  </div>
</div>
</body>
</html>
HTML
  exit 0
fi

case "${FORM_action:-}" in
  change_auth)
    nu="$(printf "%s" "${FORM_new_user:-}" | strip_newlines | trim_spaces)"
    np="$(printf "%s" "${FORM_new_pass:-}" | strip_newlines)"
    [ -z "$nu" ] && redir "" "Логин не может быть пустым." ""
    is_ascii_nospace "$nu" || redir "" "Логин: только латиница, без пробелов." ""
    len_ge_5 "$nu" || redir "" "Логин: минимум 5 символов." ""
    len_ge_8 "$np" || redir "" "Пароль: минимум 8 символов." ""
    is_ascii_nospace "$np" || redir "" "Пароль: только латиница, без пробелов." ""
    apply_panel_auth "$nu" "$np" || redir "" "Не удалось сохранить доступ." ""
    rm -f /tmp/atl_panel_sid 2>/dev/null || true
    echo "Status: 303 See Other"
    echo "Set-Cookie: ATLSESS=deleted; Path=/; Max-Age=0"
    echo "Location: /cgi-bin/panel?m=$(qenc "Доступ сохранён. Войдите заново.")"
    echo ""
    exit 0
    ;;
  reboot)
    echo "Content-type: text/html; charset=utf-8"
    echo ""
    echo "<html><body style='font-family:sans-serif'>Роутер перезагружается…</body></html>"
    reboot >/dev/null 2>&1 &
    exit 0
    ;;
  restart_inet)
    {
      echo "=== $(date) : restart inet ==="
      /etc/init.d/network restart 2>/dev/null || true
      /etc/init.d/dnsmasq restart 2>/dev/null || true
      [ -x /etc/init.d/passwall ] && /etc/init.d/passwall restart 2>/dev/null || true
      echo "=== done ==="
    } >>"$LOG" 2>&1 &
    redir "Команда отправлена. Интернет перезапускается…" "" ""
    ;;
  bypass_enable)
    bypass_enable_all
    redir "Обходы включены." "" ""
    ;;
  bypass_disable)
    bypass_disable_all
    redir "Обходы отключены." "" ""
    ;;
  update_wan)
    proto="$(printf "%s" "${FORM_wan_proto:-dhcp}" | strip_newlines)"
    IFACE="$(detect_wan_iface)"
    uci -q get network."$IFACE" >/dev/null 2>&1 || uci -q set network."$IFACE"=interface
    uci -q delete network."$IFACE".dns 2>/dev/null || true
    case "$proto" in
      dhcp)
        uci -q set network."$IFACE".proto="dhcp"
        uci -q delete network."$IFACE".username 2>/dev/null || true
        uci -q delete network."$IFACE".password 2>/dev/null || true
        uci -q delete network."$IFACE".server 2>/dev/null || true
        uci -q delete network."$IFACE".peeraddr 2>/dev/null || true
        uci -q delete network."$IFACE".ipaddr 2>/dev/null || true
        uci -q delete network."$IFACE".netmask 2>/dev/null || true
        uci -q delete network."$IFACE".gateway 2>/dev/null || true
        ;;
      static)
        ip="$(printf "%s" "${FORM_static_ip:-}" | trim_spaces)"
        mask="$(printf "%s" "${FORM_static_mask:-}" | trim_spaces)"
        gw="$(printf "%s" "${FORM_static_gw:-}" | trim_spaces)"
        d1="$(printf "%s" "${FORM_static_dns1:-}" | trim_spaces)"
        d2="$(printf "%s" "${FORM_static_dns2:-}" | trim_spaces)"
        is_ipv4 "$ip"   || redir "" "Статический IP: неверный IP-адрес." ""
        is_ipv4 "$mask" || redir "" "Статический IP: неверная маска." ""
        [ -n "$gw" ] && ! is_ipv4 "$gw" && redir "" "Статический IP: неверный шлюз." ""
        [ -n "$d1" ] && ! is_ipv4 "$d1" && redir "" "DNS 1: неверный адрес." ""
        [ -n "$d2" ] && ! is_ipv4 "$d2" && redir "" "DNS 2: неверный адрес." ""
        uci -q set network."$IFACE".proto="static"
        uci -q set network."$IFACE".ipaddr="$ip"
        uci -q set network."$IFACE".netmask="$mask"
        [ -n "$gw" ] && uci -q set network."$IFACE".gateway="$gw" || uci -q delete network."$IFACE".gateway 2>/dev/null || true
        [ -n "$d1" ] && uci -q add_list network."$IFACE".dns="$d1" || true
        [ -n "$d2" ] && uci -q add_list network."$IFACE".dns="$d2" || true
        uci -q delete network."$IFACE".username 2>/dev/null || true
        uci -q delete network."$IFACE".password 2>/dev/null || true
        uci -q delete network."$IFACE".server 2>/dev/null || true
        uci -q delete network."$IFACE".peeraddr 2>/dev/null || true
        ;;
      pppoe)
        u="$(printf "%s" "${FORM_pppoe_user:-}" | strip_newlines)"
        p="$(printf "%s" "${FORM_pppoe_pass:-}" | strip_newlines)"
        is_ascii "$u" || redir "" "PPPoE логин: только латиница." ""
        is_ascii "$p" || redir "" "PPPoE пароль: только латиница." ""
        uci -q set network."$IFACE".proto="pppoe"
        uci -q set network."$IFACE".username="$u"
        uci -q set network."$IFACE".password="$p"
        uci -q delete network."$IFACE".server 2>/dev/null || true
        uci -q delete network."$IFACE".peeraddr 2>/dev/null || true
        uci -q delete network."$IFACE".ipaddr 2>/dev/null || true
        uci -q delete network."$IFACE".netmask 2>/dev/null || true
        uci -q delete network."$IFACE".gateway 2>/dev/null || true
        ;;
      l2tp)
        srv="$(printf "%s" "${FORM_l2tp_server:-}" | strip_newlines | trim_spaces)"
        u="$(printf "%s" "${FORM_l2tp_user:-}" | strip_newlines)"
        p="$(printf "%s" "${FORM_l2tp_pass:-}" | strip_newlines)"
        [ -z "$srv" ] && redir "" "L2TP: укажите сервер (IP или домен)." ""
        is_ascii "$srv" || redir "" "L2TP сервер: только латиница." ""
        is_ascii "$u" || redir "" "L2TP логин: только латиница." ""
        is_ascii "$p" || redir "" "L2TP пароль: только латиница." ""
        uci -q set network."$IFACE".proto="l2tp"
        uci -q set network."$IFACE".server="$srv" 2>/dev/null || true
        uci -q set network."$IFACE".peeraddr="$srv" 2>/dev/null || true
        uci -q set network."$IFACE".username="$u"
        uci -q set network."$IFACE".password="$p"
        ;;
      pptp)
        srv="$(printf "%s" "${FORM_pptp_server:-}" | strip_newlines | trim_spaces)"
        u="$(printf "%s" "${FORM_pptp_user:-}" | strip_newlines)"
        p="$(printf "%s" "${FORM_pptp_pass:-}" | strip_newlines)"
        [ -z "$srv" ] && redir "" "PPTP: укажите сервер (IP или домен)." ""
        is_ascii "$srv" || redir "" "PPTP сервер: только латиница." ""
        is_ascii "$u" || redir "" "PPTP логин: только латиница." ""
        is_ascii "$p" || redir "" "PPTP пароль: только латиница." ""
        uci -q set network."$IFACE".proto="pptp"
        uci -q set network."$IFACE".server="$srv" 2>/dev/null || true
        uci -q set network."$IFACE".peeraddr="$srv" 2>/dev/null || true
        uci -q set network."$IFACE".username="$u"
        uci -q set network."$IFACE".password="$p"
        ;;
      *)
        redir "" "Неизвестный протокол WAN." ""
        ;;
    esac
    uci -q commit network >/dev/null 2>&1 || true
    ensure_wan_zone_has_iface "$IFACE"
    /etc/init.d/network reload >/dev/null 2>&1 || /etc/init.d/network restart >/dev/null 2>&1 || true
    ifdown "$IFACE" >/dev/null 2>&1 || true
    ifup "$IFACE" >/dev/null 2>&1 || true
    redir "Настройки Интернета сохранены." "" ""
    ;;
  my_wifi)
    ss24_raw="$(printf "%s" "${FORM_ssid_24:-}" | strip_newlines)"
    ss24_chk="$(printf "%s" "$ss24_raw" | trim_spaces)"
    [ -z "$ss24_chk" ] && redir "" "SSID 2.4 ГГц не может быть пустым." ""
    is_ascii "$ss24_raw" || redir "" "SSID: латиница (пробелы разрешены)." ""
    ss5_raw="$(printf "%s" "${FORM_ssid_5:-}" | strip_newlines)"
    ss5_chk="$(printf "%s" "$ss5_raw" | trim_spaces)"
    if [ -n "$ss5_chk" ]; then
      is_ascii "$ss5_raw" || redir "" "SSID: латиница (пробелы разрешены)." ""
    fi
    k24="$(printf "%s" "${FORM_key_24:-}" | strip_newlines)"
    k5="$(printf "%s" "${FORM_key_5:-}" | strip_newlines)"
    if [ -n "$k24" ]; then
      len_ge_8 "$k24" || redir "" "Пароль 2.4 ГГц: минимум 8 символов." ""
      is_ascii_nospace "$k24" || redir "" "Пароль 2.4 ГГц: латиница, без пробелов." ""
    fi
    if [ -n "$k5" ]; then
      len_ge_8 "$k5" || redir "" "Пароль 5 ГГц: минимум 8 символов." ""
      is_ascii_nospace "$k5" || redir "" "Пароль 5 ГГц: латиница, без пробелов." ""
    fi
    uci -q set wireless.default_radio0.ssid="$ss24_raw"
    uci -q set wireless.default_radio0.encryption="psk2"
    uci -q set wireless.default_radio0.key="$k24"
    uci -q set wireless.default_radio0.disabled="0" 2>/dev/null || true
    if uci -q get wireless.radio1.type >/dev/null 2>&1; then
      [ -n "$ss5_chk" ] && uci -q set wireless.default_radio1.ssid="$ss5_raw"
      uci -q set wireless.default_radio1.encryption="psk2"
      uci -q set wireless.default_radio1.key="$k5"
      uci -q set wireless.default_radio1.disabled="0" 2>/dev/null || true
    fi
    uci -q commit wireless >/dev/null 2>&1 || true
    wifi reload >/dev/null 2>&1 || true
    redir "Wi-Fi сохранён. Если вы подключены по Wi-Fi — переподключитесь к новой сети." "" ""
    ;;
  passwall_update)
    pw_exists || redir "" "PassWall не найден. Убедитесь, что установлен luci-app-passwall." ""
    NOW="$(date +%s)"
    if [ -f "$LOCK" ]; then
      TS="$(cat "$LOCK" 2>/dev/null || echo 0)"
      AGE=$((NOW - TS))
      [ "$AGE" -ge 0 ] && [ "$AGE" -lt 300 ] && redir "" "Обновление уже выполняется. Подождите немного." ""
    fi
    echo "$NOW" > "$LOCK" 2>/dev/null || true
    chmod 666 "$LOCK" 2>/dev/null || true
    lua /usr/share/passwall/rule_update.lua >>"$LOG" 2>&1; R1=$?
    lua /usr/share/passwall/subscribe.lua >>"$LOG" 2>&1; R2=$?
    if [ -x /usr/bin/youtube_strategy_autoselect.sh ]; then
      SYNC_ALL_DIRECT_FILES=1 PASSWALL_RELOAD_AFTER_DIRECT=1 /usr/bin/youtube_strategy_autoselect.sh >>"$LOG" 2>&1 || true
    fi
    rm -f "$LOCK" 2>/dev/null || true
    [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ] && redir "" "" "ok"
    redir "" "" "bad"
    ;;
  router_update_now)
    SU="$(getcfg upd_script_url)"
    VU="$(getcfg upd_version_url)"
    [ -n "${SU:-}" ] || redir "" "URL update.sh не задан." ""
    apply_update_script "$SU"
    if [ -n "${VU:-}" ]; then
      REMOTE_NOW="$(fetch "$VU" 2>/dev/null | tr -d '\r\n' | head -n1 || true)"
      [ -n "${REMOTE_NOW:-}" ] && echo "$REMOTE_NOW" > "$UPD_STATE" 2>/dev/null || true
    fi
    redir "Скрипт обновления запущен." "" ""
    ;;
  pw_change_node)
    pw_exists || redir "" "PassWall не найден." ""
    [ -n "${FORM_pw_node:-}" ] || redir "" "Не выбран сервер." ""
    pw_apply_node "$FORM_pw_node"
    redir "Сервер изменён." "" ""
    ;;
  yt_mode_apply)
    case "${FORM_yt_mode:-}" in
      main) main_mode_start ;;
      backup) backup_mode_start ;;
      *) redir "" "Не выбран режим YouTube." "" ;;
    esac
    redir "Режим YouTube сохранён." "" ""
    ;;
esac

MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
HOST="$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo OpenWrt)"
ROUTER_NAME="${MODEL:-$HOST}"

LOAD="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0.00)"
MEM_T="$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 0)"
MEM_U="$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo 0)"
MEM_P=0
[ "$MEM_T" -gt 0 ] && MEM_P=$(( (MEM_U*100)/MEM_T ))

WAN_IFACE="$(detect_wan_iface)"
CUR_WAN="$(uci -q get network.${WAN_IFACE}.proto 2>/dev/null || echo "dhcp")"
CUR_USER="$(uci -q get network.${WAN_IFACE}.username 2>/dev/null || echo "")"
CUR_PASS="$(uci -q get network.${WAN_IFACE}.password 2>/dev/null || echo "")"
CUR_SERVER="$(uci -q get network.${WAN_IFACE}.server 2>/dev/null || uci -q get network.${WAN_IFACE}.peeraddr 2>/dev/null || echo "")"
CUR_IP="$(uci -q get network.${WAN_IFACE}.ipaddr 2>/dev/null || echo "")"
CUR_MASK="$(uci -q get network.${WAN_IFACE}.netmask 2>/dev/null || echo "")"
CUR_GW="$(uci -q get network.${WAN_IFACE}.gateway 2>/dev/null || echo "")"
CUR_DNS="$(uci -q get network.${WAN_IFACE}.dns 2>/dev/null || echo "")"
CUR_DNS1="$(printf "%s" "$CUR_DNS" | awk '{print $1}')"
CUR_DNS2="$(printf "%s" "$CUR_DNS" | awk '{print $2}')"

CUR_24_SSID="$(uci -q get wireless.default_radio0.ssid 2>/dev/null || echo "Atlanta 2.4Ghz")"
CUR_24_KEY="$(uci -q get wireless.default_radio0.key 2>/dev/null || echo "11111111")"
CUR_5_SSID="$(uci -q get wireless.default_radio1.ssid 2>/dev/null || echo "Atlanta 5Ghz")"
CUR_5_KEY="$(uci -q get wireless.default_radio1.key 2>/dev/null || echo "11111111")"

CUR_USER_CFG="$(getcfg user)"
CUR_PASS_CFG="$(getcfg pass)"
CUR_YT_MODE="$(getcfg youtube_mode)"
case "$CUR_YT_MODE" in
  vpn) CUR_YT_MODE="backup" ;;
  zapret) CUR_YT_MODE="main" ;;
esac
[ -n "${CUR_YT_MODE:-}" ] || CUR_YT_MODE="main"

DEFAULT_WARN="0"
[ "$CUR_USER_CFG" = "admin" ] && [ "$CUR_PASS_CFG" = "admin" ] && DEFAULT_WARN="1"

SEL_DHCP=""; SEL_PPPOE=""; SEL_L2TP=""; SEL_PPTP=""; SEL_STATIC=""
case "$CUR_WAN" in
  pppoe) SEL_PPPOE="selected" ;;
  l2tp) SEL_L2TP="selected" ;;
  pptp) SEL_PPTP="selected" ;;
  static) SEL_STATIC="selected" ;;
  *) SEL_DHCP="selected" ;;
esac

YT_MAIN_SEL=""; YT_BACKUP_SEL=""
case "$CUR_YT_MODE" in
  backup) YT_BACKUP_SEL="selected" ;;
  *) YT_MAIN_SEL="selected" ;;
esac

case "$CUR_YT_MODE" in
  backup) YT_MODE_LABEL="Запасной" ;;
  *) YT_MODE_LABEL="Основной" ;;
esac

case "$(bypass_state)" in
  on)
    BYPASS_LABEL="Обходы включены"
    BYPASS_BTN='Отключить обходы'
    BYPASS_ACT='bypass_disable'
    ;;
  *)
    BYPASS_LABEL="Обходы отключены"
    BYPASS_BTN='Включить обходы'
    BYPASS_ACT='bypass_enable'
    ;;
esac

INSTALLED_VER="$(cat "$UPD_STATE" 2>/dev/null | tr -d '\r\n' || true)"
[ -n "${INSTALLED_VER:-}" ] || INSTALLED_VER="Не установлена"

PW_CURRENT="$(pw_current_node)"
[ -n "${PW_CURRENT:-}" ] || PW_CURRENT=""
PW_CURRENT_LABEL="$(pw_node_label "$PW_CURRENT")"

PW_OPTIONS=""
if pw_exists; then
  PW_TMP="$(pw_nodes_list || true)"
  if [ -n "${PW_TMP:-}" ]; then
    echo "$PW_TMP" | while IFS="$(printf '\t')" read -r sec rem; do
      [ -n "${sec:-}" ] || continue
      [ -n "${rem:-}" ] || rem="$sec"

      label="$rem"
      case "$label" in
        AtlantaSwitch|ATLANTASWITCH|atlantaswitch) label="Авто (балансер)" ;;
      esac
      case "$sec" in
        *AtlantaSwitch*|*ATLANTASWITCH*|*atlantaswitch*) label="Авто (балансер)" ;;
      esac
      label="$(normalize_server_label "$label")"

      ES_SEC="$(printf '%s' "$sec" | html_escape)"
      ES_REM="$(printf '%s' "$label" | html_escape)"
      if [ "$PW_CURRENT" = "$sec" ]; then
        printf '<option value="%s" selected>%s</option>\n' "$ES_SEC" "$ES_REM"
      else
        printf '<option value="%s">%s</option>\n' "$ES_SEC" "$ES_REM"
      fi
    done > /tmp/atl_pw_opts.$$ 2>/dev/null || true
    PW_OPTIONS="$(cat /tmp/atl_pw_opts.$$ 2>/dev/null || true)"
    rm -f /tmp/atl_pw_opts.$$ 2>/dev/null || true
  fi
fi

ES_NAME="$(printf '%s' "$ROUTER_NAME" | html_escape)"
ES_MSG="$(printf '%s' "${MSG:-}" | html_escape)"
ES_ERR="$(printf '%s' "${ERR:-}" | html_escape)"
ES_WAN="$(printf '%s' "$CUR_WAN" | html_escape)"
ES_WANIF="$(printf '%s' "$WAN_IFACE" | html_escape)"
ES_MAC="$(printf '%s' "$MAC" | html_escape)"
ES_UPD="$(printf '%s' "$UPD_STATUS" | html_escape)"
ES_USER="$(printf '%s' "$CUR_USER" | html_escape)"
ES_PASS="$(printf '%s' "$CUR_PASS" | html_escape)"
ES_SERVER="$(printf '%s' "$CUR_SERVER" | html_escape)"
ES_IP="$(printf '%s' "$CUR_IP" | html_escape)"
ES_MASK="$(printf '%s' "$CUR_MASK" | html_escape)"
ES_GW="$(printf '%s' "$CUR_GW" | html_escape)"
ES_DNS1="$(printf '%s' "$CUR_DNS1" | html_escape)"
ES_DNS2="$(printf '%s' "$CUR_DNS2" | html_escape)"
ES_24_SSID="$(printf '%s' "$CUR_24_SSID" | html_escape)"
ES_24_KEY="$(printf '%s' "$CUR_24_KEY" | html_escape)"
ES_5_SSID="$(printf '%s' "$CUR_5_SSID" | html_escape)"
ES_5_KEY="$(printf '%s' "$CUR_5_KEY" | html_escape)"
ES_PU="$(printf '%s' "$CUR_USER_CFG" | html_escape)"
ES_PP="$(printf '%s' "$CUR_PASS_CFG" | html_escape)"
ES_INSTALLED_VER="$(printf '%s' "$INSTALLED_VER" | html_escape)"
ES_PW_CURRENT_LABEL="$(printf '%s' "$PW_CURRENT_LABEL" | html_escape)"
ES_YT_MODE="$(printf '%s' "$YT_MODE_LABEL" | html_escape)"
ES_BYPASS_LABEL="$(printf '%s' "$BYPASS_LABEL" | html_escape)"
ES_BYPASS_BTN="$(printf '%s' "$BYPASS_BTN" | html_escape)"
ES_BYPASS_ACT="$(printf '%s' "$BYPASS_ACT" | html_escape)"

echo "Content-type: text/html; charset=utf-8"
echo ""
cat <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Atlanta Панель</title>
<style>
:root{
  --bg:#05070d;
  --bg2:#070b14;
  --txt:#eaf3ff;
  --mut:rgba(234,243,255,.62);
  --acc:#2fe6ff;
  --acc2:#2a7bff;
  --acc3:#7b5cff;
  --ok:#57f287;
  --bad:#ff6b6b;
}
*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0;
  min-height:100vh;
  color:var(--txt);
  font:14px/1.4 system-ui,-apple-system,Segoe UI,Roboto;
  background:
    radial-gradient(1200px 700px at 18% 12%, rgba(0,176,255,.22), transparent 60%),
    radial-gradient(1000px 520px at 85% 18%, rgba(96,71,255,.18), transparent 58%),
    linear-gradient(135deg, rgba(0,120,255,.08), transparent 45%),
    linear-gradient(180deg, var(--bg), var(--bg2));
  overflow-x:hidden;
}
body:before{
  content:"";
  position:fixed;
  inset:0;
  pointer-events:none;
  z-index:0;
  background:
    repeating-linear-gradient(115deg, rgba(255,255,255,.06) 0 1px, transparent 1px 36px),
    repeating-linear-gradient(25deg, rgba(255,255,255,.04) 0 1px, transparent 1px 34px);
  opacity:.18;
}
a{color:inherit;text-decoration:none}
.wrap{
  width:min(1780px,calc(100vw - 48px));
  margin:0 auto;
  padding:18px;
  position:relative;
  z-index:1;
}
.top{
  display:flex;
  align-items:flex-start;
  justify-content:space-between;
  gap:12px;
  margin-bottom:12px;
}
.brand h1{margin:0;font-size:18px}
.chips{
  display:flex;
  gap:10px;
  flex-wrap:wrap;
  justify-content:flex-end;
}
.chip{
  background:rgba(255,255,255,.05);
  border:1px solid rgba(255,255,255,.10);
  border-radius:999px;
  padding:8px 12px;
  display:flex;
  gap:8px;
  align-items:center;
  backdrop-filter:blur(8px);
}
.dot{
  width:8px;height:8px;border-radius:999px;
  background:var(--ok);
  box-shadow:0 0 0 3px rgba(87,242,135,.14);
}
.nav{
  display:flex;
  gap:10px;
  flex-wrap:wrap;
  margin:10px 0 14px;
}
.nav a,.nav button{
  display:inline-flex;
  align-items:center;
  justify-content:center;
  gap:8px;
  padding:10px 12px;
  border-radius:14px;
  border:1px solid rgba(255,255,255,.12);
  background:rgba(255,255,255,.06);
  min-height:44px;
  font-weight:900;
  color:var(--txt);
  cursor:pointer;
}
.nav a.primary,.nav button.primary,.btn{
  background:linear-gradient(90deg,var(--acc),var(--acc2),var(--acc3));
  color:#041018;
  border:0;
}
.msg{
  margin:12px 0;
  padding:10px 12px;
  border-radius:14px;
  border:1px solid rgba(87,242,135,.25);
  background:rgba(87,242,135,.08);
}
.err{
  margin:12px 0;
  padding:10px 12px;
  border-radius:14px;
  border:1px solid rgba(255,107,107,.25);
  background:rgba(255,107,107,.08);
}
.okline{
  margin:12px 0;
  padding:10px 12px;
  border-radius:14px;
  border:1px solid rgba(87,242,135,.25);
  background:rgba(87,242,135,.08);
  font-weight:900;
}
.badline{
  margin:12px 0;
  padding:10px 12px;
  border-radius:14px;
  border:1px solid rgba(255,107,107,.25);
  background:rgba(255,107,107,.08);
  font-weight:900;
}
.windows{
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:16px;
  align-items:start;
}
.window{
  background:linear-gradient(180deg,rgba(255,255,255,.07),rgba(255,255,255,.03));
  border:1px solid rgba(255,255,255,.10);
  border-radius:22px;
  padding:16px;
  box-shadow:0 20px 60px rgba(0,0,0,.45);
}
.window-title{
  font-size:16px;
  font-weight:900;
  margin:0 0 14px;
  color:#dff1ff;
}
.stack{display:grid;gap:14px}
.card{
  background:rgba(255,255,255,.03);
  border:1px solid rgba(255,255,255,.09);
  border-radius:18px;
  padding:14px;
}
.card h2{
  margin:0 0 10px;
  font-size:14px;
  font-weight:900;
  color:#d9ecff;
}
label{
  display:block;
  color:var(--mut);
  font-size:12px;
  margin:10px 0 6px;
}
input,select{
  width:100%;
  background:rgba(0,0,0,.28);
  border:1px solid rgba(255,255,255,.12);
  color:var(--txt);
  padding:12px 14px;
  border-radius:14px;
  outline:none;
  min-height:44px;
  box-shadow:inset 0 1px 0 rgba(255,255,255,.04);
}
select{
  appearance:none;
  -webkit-appearance:none;
  -moz-appearance:none;
  background-image:
    linear-gradient(45deg, transparent 50%, rgba(234,243,255,.92) 50%),
    linear-gradient(135deg, rgba(234,243,255,.92) 50%, transparent 50%),
    linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,.02));
  background-position:
    calc(100% - 20px) calc(50% - 3px),
    calc(100% - 14px) calc(50% - 3px),
    0 0;
  background-size:6px 6px,6px 6px,100% 100%;
  background-repeat:no-repeat;
  padding-right:42px;
  font-weight:800;
}
input:focus,select:focus{
  border-color:rgba(47,230,255,.55);
  box-shadow:0 0 0 3px rgba(47,230,255,.12), inset 0 1px 0 rgba(255,255,255,.04);
}
option{background:#0f1720;color:#eaf3ff;font-weight:700}
.row{display:flex;gap:10px;flex-wrap:wrap}
.btn{
  appearance:none;
  border-radius:14px;
  padding:12px 14px;
  font-weight:950;
  cursor:pointer;
  min-height:44px;
}
.btn.secondary{
  background:rgba(255,255,255,.08);
  color:var(--txt);
  border:1px solid rgba(255,255,255,.12);
}
.btn.danger{
  background:rgba(255,107,107,.14);
  color:#ffd6d6;
  border:1px solid rgba(255,107,107,.24);
}
.hint{
  color:var(--mut);
  padding:10px 12px;
  border-radius:14px;
  border:1px dashed rgba(255,255,255,.14);
  background:rgba(255,255,255,.03);
}
.copywrap{
  display:flex;
  gap:8px;
  align-items:center;
  flex-wrap:wrap;
}
.copyid{font-weight:900;letter-spacing:.3px}
.copybtn{
  border:1px solid rgba(255,255,255,.14);
  background:rgba(255,255,255,.06);
  color:var(--txt);
  border-radius:12px;
  padding:8px 10px;
  cursor:pointer;
  min-height:38px;
}
.toast{
  display:inline-block;
  margin-left:6px;
  color:var(--ok);
  font-weight:900;
  opacity:0;
  transition:opacity .2s;
}
.toast.on{opacity:1}
.hidden{display:none !important}

#mobileMenuBtn{
  display:none;
  position:fixed;
  top:calc(env(safe-area-inset-top) + 12px);
  right:12px;
  z-index:120;
  width:48px;
  height:48px;
  border:1px solid rgba(255,255,255,.12);
  border-radius:16px;
  background:linear-gradient(90deg,var(--acc),var(--acc2),var(--acc3));
  color:#041018;
  font-weight:900;
  font-size:22px;
  box-shadow:0 18px 40px rgba(0,0,0,.35);
}
#mobileMenuOverlay{
  display:none;
  position:fixed;
  inset:0;
  z-index:110;
  background:rgba(2,6,12,.62);
}
#mobileMenuCloseBtn{
  display:none;
  position:fixed;
  top:calc(env(safe-area-inset-top) + 12px);
  right:12px;
  z-index:121;
  width:46px;
  height:46px;
  border-radius:14px;
  border:1px solid rgba(255,255,255,.14);
  background:rgba(10,16,24,.96);
  color:var(--txt);
  align-items:center;
  justify-content:center;
  font-size:20px;
  font-weight:900;
}
@media (max-width: 980px){
  .windows{grid-template-columns:1fr}
}
@media (max-width: 900px), (hover: none) and (pointer: coarse){
  .top{
    flex-direction:column;
    align-items:stretch;
    gap:10px;
    padding-right:70px;
  }
  .chips{justify-content:flex-start}
  input,select,textarea{font-size:16px !important}
  #mobileMenuBtn{
    display:inline-flex;
    align-items:center;
    justify-content:center;
  }
  .nav{
    position:fixed;
    top:0;
    right:0;
    bottom:0;
    left:auto;
    width:min(82vw,330px);
    max-height:none;
    overflow:auto;
    padding:72px 14px 16px;
    display:flex;
    flex-direction:column;
    gap:10px;
    border-radius:22px 0 0 22px;
    background:rgba(8,12,18,.98);
    border-left:1px solid rgba(255,255,255,.10);
    transform:translateX(110%);
    transition:transform .22s ease;
    z-index:115;
    box-shadow:-18px 0 60px rgba(0,0,0,.38);
  }
  .nav.open{transform:translateX(0)}
  .nav a,.nav button{
    width:100%;
    min-height:52px;
  }
  .wrap{padding-bottom:24px !important}
  .btn{width:100%}
}
</style>
<script>
function post(action, extra={}) {
  mobileMenuClose();
  const f=document.createElement('form');
  f.method='POST';
  f.action='/cgi-bin/panel';
  const add=(k,v)=>{
    const i=document.createElement('input');
    i.type='hidden';
    i.name=k;
    i.value=v;
    f.appendChild(i);
  };
  add('action',action);
  for (const [k,v] of Object.entries(extra)) add(k,v);
  document.body.appendChild(f);
  f.submit();
}
function g(id){return document.getElementById(id)}
async function copyText(id){
  const el=g(id);
  const t=el ? el.textContent.trim() : "";
  if(!t) return;
  try{ await navigator.clipboard.writeText(t); }
  catch(e){
    const ta=document.createElement('textarea');
    ta.value=t;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  const toast=g('copied');
  if(toast){
    toast.classList.add('on');
    setTimeout(()=>toast.classList.remove('on'),1200);
  }
}
function closeModal(){ const m=g('modal'); if(m) m.style.display='none'; }
function mobileMenuOpen(){
  const n=g('mainNav');
  const o=g('mobileMenuOverlay');
  const c=g('mobileMenuCloseBtn');
  if(n) n.classList.add('open');
  if(o) o.style.display='block';
  if(c) c.style.display='flex';
}
function mobileMenuClose(){
  const n=g('mainNav');
  const o=g('mobileMenuOverlay');
  const c=g('mobileMenuCloseBtn');
  if(n) n.classList.remove('open');
  if(o) o.style.display='none';
  if(c) c.style.display='none';
}
function menuBlank(link){
  mobileMenuClose();
  window.open(link, '_blank', 'noopener');
}
function updateWanFields(){
  const v = g('wan_proto').value;
  g('pppoe_fields').classList.toggle('hidden', v !== 'pppoe');
  g('l2tp_fields').classList.toggle('hidden', v !== 'l2tp');
  g('pptp_fields').classList.toggle('hidden', v !== 'pptp');
  g('static_fields').classList.toggle('hidden', v !== 'static');
}
window.addEventListener('load', ()=>{
  if(${DEFAULT_WARN}===1){
    const m=g('modal');
    if(m) m.style.display='flex';
  }
  updateWanFields();
});
</script>
</head>
<body>
<button id="mobileMenuBtn" type="button" onclick="mobileMenuOpen()">☰</button>
<div id="mobileMenuOverlay" onclick="mobileMenuClose()"></div>
<button id="mobileMenuCloseBtn" type="button" onclick="mobileMenuClose()">✕</button>

<div id="modal" style="position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:#05070d;z-index:99;padding:16px" onclick="closeModal()">
  <div style="max-width:520px;width:100%;background:#0f1720;border:1px solid rgba(255,255,255,.18);border-radius:18px;padding:16px" onclick="event.stopPropagation()">
    <h3 style="margin:0 0 8px">⚠️ Важно: измените логин и пароль панели</h3>
    <p style="margin:0 0 12px;color:rgba(234,243,255,.62)">Сейчас установлены стандартные данные доступа: <b>admin / admin</b>. Это небезопасно. Перейдите в раздел «Доступ к панели» и задайте свои значения.</p>
    <button class="btn" type="button" onclick="closeModal()">Понял</button>
  </div>
</div>

<div class="wrap">
  <div class="top">
    <div class="brand"><h1>${ES_NAME} • Atlanta Панель</h1></div>
    <div class="chips">
      <div class="chip"><span class="dot"></span><b>Работает</b></div>
      <div class="chip">CPU <b>${LOAD}</b></div>
      <div class="chip">RAM <b>${MEM_P}%</b></div>
      <div class="chip">
        <span class="copywrap">
          <span style="color:var(--mut);font-size:12px">MAC</span>
          <span id="deviceid" class="copyid">${ES_MAC}</span>
          <button class="copybtn" type="button" onclick="copyText('deviceid')">📋 Копировать</button>
          <span id="copied" class="toast">✅</span>
        </span>
      </div>
    </div>
  </div>

  <div class="nav" id="mainNav">
    <a class="primary" href="javascript:void(0)" onclick="menuBlank('${LINK_SUB}')">💎 Подписка</a>
    <a href="javascript:void(0)" onclick="menuBlank('${LINK_SUPPORT}')">🎧 Поддержка</a>
    <a href="javascript:void(0)" onclick="menuBlank('/instruction.html')">📘 Инструкция</a>
    <button type="button" onclick="post('restart_inet')">🔁 Перезапустить интернет</button>
    <button class="primary" type="button" onclick="post('passwall_update')">🔄 Обновить Подписку</button>
    <button type="button" onclick="post('${ES_BYPASS_ACT}')">${ES_BYPASS_BTN}</button>
    <button type="button" onclick="post('router_update_now')">🧩 Обновить роутер</button>
    <button type="button" onclick="post('logout')">🚪 Выйти</button>
  </div>

  ${ERR:+<div class="err">❌ ${ES_ERR}</div>}
  ${MSG:+<div class="msg">✅ ${ES_MSG}</div>}
  ${UPD_STATUS:+<div class="${UPD_COLOR}line">${ES_UPD}</div>}

  <div class="windows">
    <div class="window">
      <div class="window-title">Интернет и Wi-Fi</div>
      <div class="stack">
        <div class="card">
          <h2>🌐 Интернет (WAN)</h2>
          <div class="hint">Выберите тип подключения и нажмите «Сохранить настройки Интернета». Интерфейс WAN: <b>${ES_WANIF}</b></div>

          <label>Тип подключения</label>
          <select id="wan_proto" onchange="updateWanFields()">
            <option value="dhcp" $SEL_DHCP>DHCP (обычно)</option>
            <option value="static" $SEL_STATIC>Статический IP</option>
            <option value="pppoe" $SEL_PPPOE>PPPoE</option>
            <option value="l2tp" $SEL_L2TP>L2TP</option>
            <option value="pptp" $SEL_PPTP>PPTP</option>
          </select>

          <div id="static_fields" class="hidden">
            <label>IP-адрес</label><input id="static_ip" value="${ES_IP}">
            <label>Маска</label><input id="static_mask" value="${ES_MASK}">
            <label>Шлюз</label><input id="static_gw" value="${ES_GW}">
            <label>DNS 1</label><input id="static_dns1" value="${ES_DNS1}">
            <label>DNS 2</label><input id="static_dns2" value="${ES_DNS2}">
          </div>

          <div id="pppoe_fields" class="hidden">
            <label>PPPoE логин (только латиница)</label><input id="pppoe_user" value="${ES_USER}">
            <label>PPPoE пароль (только латиница)</label><input id="pppoe_pass" type="password" value="${ES_PASS}">
          </div>

          <div id="l2tp_fields" class="hidden">
            <label>L2TP сервер (IP или домен)</label><input id="l2tp_server" value="${ES_SERVER}">
            <label>L2TP логин</label><input id="l2tp_user" value="${ES_USER}">
            <label>L2TP пароль</label><input id="l2tp_pass" type="password" value="${ES_PASS}">
            <div class="hint" style="margin-top:10px">Лог автоустановки: <code>/tmp/atl_panel_opkg.log</code></div>
          </div>

          <div id="pptp_fields" class="hidden">
            <label>PPTP сервер (IP или домен)</label><input id="pptp_server" value="${ES_SERVER}">
            <label>PPTP логин</label><input id="pptp_user" value="${ES_USER}">
            <label>PPTP пароль</label><input id="pptp_pass" type="password" value="${ES_PASS}">
            <div class="hint" style="margin-top:10px">Лог автоустановки: <code>/tmp/atl_panel_opkg.log</code></div>
          </div>

          <div class="row" style="margin-top:10px">
            <button class="btn" type="button"
              onclick="post('update_wan',{
                wan_proto:g('wan_proto').value,
                static_ip:g('static_ip')?g('static_ip').value:'',
                static_mask:g('static_mask')?g('static_mask').value:'',
                static_gw:g('static_gw')?g('static_gw').value:'',
                static_dns1:g('static_dns1')?g('static_dns1').value:'',
                static_dns2:g('static_dns2')?g('static_dns2').value:'',
                pppoe_user:g('pppoe_user')?g('pppoe_user').value:'',
                pppoe_pass:g('pppoe_pass')?g('pppoe_pass').value:'',
                l2tp_server:g('l2tp_server')?g('l2tp_server').value:'',
                l2tp_user:g('l2tp_user')?g('l2tp_user').value:'',
                l2tp_pass:g('l2tp_pass')?g('l2tp_pass').value:'',
                pptp_server:g('pptp_server')?g('pptp_server').value:'',
                pptp_user:g('pptp_user')?g('pptp_user').value:'',
                pptp_pass:g('pptp_pass')?g('pptp_pass').value:''
              })">Сохранить настройки Интернета</button>
            <button class="btn danger" type="button" onclick="post('reboot')">🚀 Перезагрузить роутер</button>
          </div>

          <div class="hint" style="margin-top:10px">Текущий тип подключения: <b>${ES_WAN}</b></div>
        </div>

        <div class="card">
          <h2>🏠 Wi-Fi</h2>
          <div class="hint">SSID можно вводить с пробелами. Пароль — минимум 8 символов и без пробелов.</div>

          <label>Название сети 2.4 ГГц</label><input id="ssid_24" value="${ES_24_SSID}">
          <label>Пароль 2.4 ГГц</label><input id="key_24" type="password" value="${ES_24_KEY}">
          <label>Название сети 5 ГГц</label><input id="ssid_5" value="${ES_5_SSID}">
          <label>Пароль 5 ГГц</label><input id="key_5" type="password" value="${ES_5_KEY}">

          <div class="row" style="margin-top:10px">
            <button class="btn" type="button"
              onclick="post('my_wifi',{
                ssid_24:g('ssid_24').value,
                key_24:g('key_24').value,
                ssid_5:g('ssid_5').value,
                key_5:g('key_5').value
              })">Сохранить Wi-Fi</button>
          </div>
        </div>
      </div>
    </div>

    <div class="window">
      <div class="window-title">VPN, YouTube, доступ и обновление</div>
      <div class="stack">
        <div class="card">
          <h2>🛡 Обходы</h2>
          <div class="hint">Состояние: <b>${ES_BYPASS_LABEL}</b></div>
          <div class="row" style="margin-top:10px">
            <button class="btn" type="button" onclick="post('${ES_BYPASS_ACT}')">${ES_BYPASS_BTN}</button>
          </div>
        </div>

        <div class="card">
          <h2>🛰 Выбор сервера</h2>
          <div class="hint">Текущий сервер: <b>${ES_PW_CURRENT_LABEL}</b></div>

          <label>Сервер</label>
          <select id="pw_node">
            ${PW_OPTIONS}
          </select>

          <div class="row" style="margin-top:10px">
            <button class="btn" type="button" onclick="post('pw_change_node',{pw_node:g('pw_node').value})">Применить сервер</button>
          </div>

          <div class="hint" style="margin-top:10px">
            AtlantaSwitch отображается как <b>Авто (балансер)</b>.
          </div>
        </div>

        <div class="card">
          <h2>▶️ YouTube</h2>
          <div class="hint">Текущий режим: <b>${ES_YT_MODE}</b></div>

          <label>Маршрут YouTube</label>
          <select id="yt_mode">
            <option value="main" $YT_MAIN_SEL>Основной</option>
            <option value="backup" $YT_BACKUP_SEL>Запасной</option>
          </select>

          <div class="row" style="margin-top:10px">
            <button class="btn" type="button" onclick="post('yt_mode_apply',{yt_mode:g('yt_mode').value})">Сохранить режим YouTube</button>
          </div>
        </div>

        <div class="card">
          <h2>🔐 Доступ к панели</h2>
          <div class="hint">Логин: латиница, минимум 5 символов, без пробелов.<br>Пароль: латиница, минимум 8 символов, без пробелов.</div>

          <label>Новый логин</label><input id="new_user" value="${ES_PU}">
          <label>Новый пароль</label><input id="new_pass" type="password" value="${ES_PP}">

          <div class="row" style="margin-top:10px">
            <button class="btn" type="button"
              onclick="post('change_auth',{new_user:g('new_user').value,new_pass:g('new_pass').value})">Сохранить доступ</button>
          </div>
        </div>

        <div class="card">
          <h2>🧩 Обновление роутера</h2>
          <div class="hint">
            Установленная версия: <b>${ES_INSTALLED_VER}</b><br>
            Автообновление включено ежедневно в <b>04:00</b>.
          </div>

          <div class="row" style="margin-top:10px">
            <button class="btn secondary" type="button" onclick="post('router_update_now')">Запустить обновление сейчас</button>
            <button class="btn danger" type="button" onclick="post('reboot')">Перезагрузить роутер</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
</body>
</html>
HTML
PANELFILE

chmod 0755 "$PANEL"

uci -q set uhttpd.main.cgi_prefix='/cgi-bin'
uci -q delete uhttpd.main.interpreter 2>/dev/null || true
uci -q add_list uhttpd.main.interpreter='.sh=/bin/sh'
uci -q set uhttpd.main.index_page='cgi-bin/panel'
uci -q commit uhttpd

cat > /www/index.html <<'ROOT'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=/cgi-bin/panel">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Redirect</title>
</head>
<body>
Redirecting… <a href="/cgi-bin/panel">Open</a>
</body>
</html>
ROOT

uci -q set wireless.radio0.disabled='0' 2>/dev/null || true
uci -q set wireless.radio1.disabled='0' 2>/dev/null || true

if ! uci -q get wireless.default_radio0 >/dev/null 2>&1; then
  uci -q set wireless.default_radio0=wifi-iface
  uci -q set wireless.default_radio0.device='radio0'
  uci -q set wireless.default_radio0.network='lan'
  uci -q set wireless.default_radio0.mode='ap'
fi

uci -q set wireless.default_radio0.ssid="$WIFI_SSID_24"
uci -q set wireless.default_radio0.encryption='psk2'
uci -q set wireless.default_radio0.key="$WIFI_KEY"
uci -q set wireless.default_radio0.disabled='0' 2>/dev/null || true

if uci -q get wireless.radio1.type >/dev/null 2>&1; then
  if ! uci -q get wireless.default_radio1 >/dev/null 2>&1; then
    uci -q set wireless.default_radio1=wifi-iface
    uci -q set wireless.default_radio1.device='radio1'
    uci -q set wireless.default_radio1.network='lan'
    uci -q set wireless.default_radio1.mode='ap'
  fi
  uci -q set wireless.default_radio1.ssid="$WIFI_SSID_5"
  uci -q set wireless.default_radio1.encryption='psk2'
  uci -q set wireless.default_radio1.key="$WIFI_KEY"
  uci -q set wireless.default_radio1.disabled='0' 2>/dev/null || true
fi

uci -q commit wireless 2>/dev/null || true

# Меняем LAN IP на 192.168.14.1
uci -q set network.lan.ipaddr="$LAN_IP"
uci -q set network.lan.netmask="$LAN_MASK"
uci -q commit network

wifi reload >/dev/null 2>&1 || wifi up >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/network restart >/dev/null 2>&1 || true

echo "--- OK ---"
echo "LAN IP изменён на: $LAN_IP"
echo "Открой: http://$LAN_IP/"
echo "Панель: /cgi-bin/panel"
echo "Логин/пароль панели: admin / admin"
echo "Wi-Fi 2.4: $WIFI_SSID_24  пароль: $WIFI_KEY"
echo "Wi-Fi 5:   $WIFI_SSID_5  пароль: $WIFI_KEY"
echo "Лог обновления панели: /tmp/atl_panel_update.log"
echo "Лог подписки PassWall: /tmp/atl_panel_passwall_update.log"
echo "Лог автоустановки L2TP/PPTP: /tmp/atl_panel_opkg.log"
EOF

sh /tmp/install_atlanta_panel_full_lan14.sh
