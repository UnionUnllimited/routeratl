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
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_size_mb='128'
uci commit system
/etc/init.d/zram enable
/etc/init.d/zram start
free -m
cat /proc/swaps
