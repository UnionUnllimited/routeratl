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
