cat > /usr/bin/frp_simple_install.sh <<'SH'
#!/bin/sh
set -eu

# =========================
# SIMPLE FRP (frpc) INSTALL + CONFIG (OpenWrt)
# - Downloads frpc from GitHub releases
# - Creates /etc/frp/frpc.ini using YOUR fixed server settings
# - Creates luci<MAC> on port 80 and ssh<MAC> on port 22
# - Installs /etc/init.d/frpc to always run /etc/frp/frpc.ini
# =========================

FRP_VER="0.61.0"

# ==== YOUR FIXED CONFIG ====
SERVER_ADDR="origin.all-streams-24.ru"
SERVER_PORT="8443"
TOKEN="21658aa79e70daf3a9e7ededa24855dcdf791a8606a4da6f8d7cb594513202d2"

# local services
LUCI_PORT="80"
SSH_PORT="22"

log(){ echo "[frp] $*"; }

need(){ command -v "$1" >/dev/null 2>&1; }

# ---- detect arch for frpc tarball ----
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) FRP_TAR="frp_${FRP_VER}_linux_arm64.tar.gz" ;;
  x86_64|amd64)  FRP_TAR="frp_${FRP_VER}_linux_amd64.tar.gz" ;;
  armv7l|armv7*) FRP_TAR="frp_${FRP_VER}_linux_arm.tar.gz" ;;
  i386|i686)     FRP_TAR="frp_${FRP_VER}_linux_386.tar.gz" ;;
  mipsel*)       FRP_TAR="frp_${FRP_VER}_linux_mipsle.tar.gz" ;;
  mips*)         FRP_TAR="frp_${FRP_VER}_linux_mips.tar.gz" ;;
  *) log "Unsupported arch: $ARCH"; exit 1 ;;
esac

# ---- get MAC -> hex (lowercase, no :) ----
get_mac() {
  if [ -r /sys/class/net/br-lan/address ]; then cat /sys/class/net/br-lan/address; return; fi
  if [ -r /sys/class/net/eth0/address ]; then cat /sys/class/net/eth0/address; return; fi
  if need ip; then ip link 2>/dev/null | awk '/link\/ether/{print $2; exit}'; return; fi
  echo "00:00:00:00:00:00"
}
MAC="$(get_mac | head -n1)"
MACHEX="$(echo "$MAC" | tr -d ':' | tr 'A-F' 'a-f')"

LUCINAME="luci${MACHEX}"
SSHNAME="ssh${MACHEX}"

log "MAC: $MAC => $MACHEX"
log "Names: $LUCINAME / $SSHNAME"

# ---- ensure curl or wget ----
DL=""
if need curl; then DL="curl"
elif need wget; then DL="wget"
else
  log "curl/wget not found -> trying opkg install curl"
  opkg update >/dev/null 2>&1 || true
  opkg install curl ca-bundle >/dev/null 2>&1 || true
  need curl || { log "Need curl or wget"; exit 1; }
  DL="curl"
fi

# ---- download & install frpc ----
TMP="/tmp/frp.$$"
mkdir -p "$TMP"
URL="https://github.com/fatedier/frp/releases/download/v${FRP_VER}/${FRP_TAR}"
log "Download: $URL"

if [ "$DL" = "curl" ]; then
  curl -fL --connect-timeout 10 --max-time 180 -o "$TMP/frp.tgz" "$URL"
else
  wget -O "$TMP/frp.tgz" "$URL"
fi

tar -xzf "$TMP/frp.tgz" -C "$TMP"
FRP_DIR="$(find "$TMP" -maxdepth 1 -type d -name "frp_*" | head -n1)"
[ -n "$FRP_DIR" ] && [ -x "$FRP_DIR/frpc" ] || { log "frpc not found after extract"; exit 1; }

cp -f "$FRP_DIR/frpc" /usr/bin/frpc
chmod 0755 /usr/bin/frpc
rm -rf "$TMP"
log "Installed: /usr/bin/frpc ($(/usr/bin/frpc -v 2>/dev/null || true))"

# ---- write config ----
mkdir -p /etc/frp
cat > /etc/frp/frpc.ini <<EOF
[common]
server_addr = ${SERVER_ADDR}
server_port = ${SERVER_PORT}
token = ${TOKEN}

[${LUCINAME}]
type = stcp
role = server
use_encryption = true
use_compression = false
local_ip = 127.0.0.1
local_port = ${LUCI_PORT}
# IMPORTANT: same sk as your setup (if you use stcp)
sk = 27555c1d65fc7d8b4b26f95e6df64ec54b41246bd805fea4e0a96240568ea4fb

[${SSHNAME}]
type = stcp
role = server
use_encryption = true
use_compression = false
local_ip = 127.0.0.1
local_port = ${SSH_PORT}
sk = 27555c1d65fc7d8b4b26f95e6df64ec54b41246bd805fea4e0a96240568ea4fb
EOF
chmod 600 /etc/frp/frpc.ini
log "Wrote: /etc/frp/frpc.ini"

# ---- init.d service (always uses /etc/frp/frpc.ini) ----
cat > /etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/frpc -c /etc/frp/frpc.ini
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}

stop_service() {
  killall -q frpc 2>/dev/null || true
}
EOF
chmod +x /etc/init.d/frpc
/etc/init.d/frpc enable >/dev/null 2>&1 || true
/etc/init.d/frpc restart >/dev/null 2>&1 || /etc/init.d/frpc start >/dev/null 2>&1 || true

log "DONE."
log "LuCI local is assumed on http://127.0.0.1:${LUCI_PORT} (usually also http://192.168.1.1)"
log "FRP sections: ${LUCINAME}, ${SSHNAME}"
log "Last frpc logs:"
logread -e frpc | tail -n 20 || true
SH

chmod +x /usr/bin/frp_simple_install.sh
echo "Run: /usr/bin/frp_simple_install.sh"
/usr/bin/frp_simple_install.sh
