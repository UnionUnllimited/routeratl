cat > /etc/rc.button/reset <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x /etc/rc.button/reset
opkg install zram-swap
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_size_mb='128'
uci commit system
/etc/init.d/zram enable
/etc/init.d/zram start
free -m
cat /proc/swaps
cat >/root/change_lan_frpc.sh <<'EOF'
#!/bin/sh

OLD_IP="192.168.1.1"
NEW_IP="192.168.14.1"

echo "[*] Backup network config..."
cp /etc/config/network /etc/config/network.bak.$(date +%s)

echo "[*] Replace IP in frpc configs..."
find /etc /root /usr -type f \( -name '*frpc*.toml' -o -name '*frpc*.ini' -o -name '*frpc*.conf' -o -name 'frpc.toml' -o -name 'frpc.ini' -o -name 'frpc.conf' \) 2>/dev/null | while read -r f; do
    if grep -q "$OLD_IP" "$f"; then
        echo "  - patched: $f"
        sed -i "s/$OLD_IP/$NEW_IP/g" "$f"
    fi
done

echo "[*] Detect LAN section..."
LAN_SECTION="$(uci show network | sed -n "s/^\(network\.[^.]*\)=interface$/\1/p" | while read -r s; do
    name="$(uci -q get "$s.device")"
    [ -z "$name" ] && name="$(uci -q get "$s.ifname")"
    proto="$(uci -q get "$s.proto")"
    ip="$(uci -q get "$s.ipaddr")"
    case "$s" in
        network.lan) echo "$s"; break ;;
        *)
            [ "$ip" = "$OLD_IP" ] && echo "$s" && break
        ;;
    esac
done | head -n1)"

[ -z "$LAN_SECTION" ] && LAN_SECTION="network.lan"

echo "[*] Set $LAN_SECTION ipaddr to $NEW_IP"
uci set "$LAN_SECTION.ipaddr=$NEW_IP"
uci commit network

echo "[*] Restart network..."
/etc/init.d/network restart

echo "[*] Restart frpc if present..."
/etc/init.d/frpc restart 2>/dev/null || pkill -f '/frpc' 2>/dev/null || true

echo "[*] Done. New router IP: $NEW_IP"
EOF
chmod +x /root/change_lan_frpc.sh
/root/change_lan_frpc.sh
