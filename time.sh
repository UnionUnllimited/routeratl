uci set system.@system[0].zonename='Europe/Moscow'; uci set system.@system[0].timezone='MSK-3'; uci commit system; printf '20057771925jk\n20057771925jk\n' | passwd root; uci -q delete network.wan6; uci commit network; /etc/init.d/system reload; /etc/init.d/network restart
printf '#!/bin/sh\n' > /www/cgi-bin/stats && cat >> /www/cgi-bin/stats << 'EOF'
printf "Content-Type: application/json\r\n"
printf "Access-Control-Allow-Origin: *\r\n"
printf "\r\n"
cpu1=$(cat /proc/stat | head -1); sleep 0.2; cpu2=$(cat /proc/stat | head -1)
total1=$(echo $cpu1 | awk '{print $2+$3+$4+$5+$6+$7+$8}'); idle1=$(echo $cpu1 | awk '{print $5}')
total2=$(echo $cpu2 | awk '{print $2+$3+$4+$5+$6+$7+$8}'); idle2=$(echo $cpu2 | awk '{print $5}')
dtotal=$((total2-total1)); didle=$((idle2-idle1))
[ "$dtotal" -gt 0 ] && cpu_pct=$(( (dtotal-didle)*100/dtotal )) || cpu_pct=0
mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_free=$(awk '/MemFree/{print $2}' /proc/meminfo)
mem_buf=$(awk '/Buffers/{print $2}' /proc/meminfo)
mem_cache=$(awk '/^Cached/{print $2}' /proc/meminfo)
mem_used=$((mem_total-mem_free-mem_buf-mem_cache)); ram_pct=$((mem_used*100/mem_total))
uptime_sec=$(awk '{print int($1)}' /proc/uptime)
load=$(awk '{print $1}' /proc/loadavg)
wan_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}'); [ -z "$wan_ip" ] && wan_ip="unknown"
rx_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
tx_bytes=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0)
vpn_running=false; [ "$(uci get passwall.@global[0].enabled 2>/dev/null)" = "1" ] && vpn_running=true
bypass_on=false; pgrep -f nfqws >/dev/null 2>&1 && bypass_on=true
wifi_clients=0; for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do n=$(iw dev "$iface" station dump 2>/dev/null | grep -c Station); wifi_clients=$((wifi_clients+n)); done
dhcp_clients=0; [ -f /tmp/dhcp.leases ] && dhcp_clients=$(wc -l < /tmp/dhcp.leases)
temp=null; for f in /sys/class/thermal/thermal_zone*/temp; do [ -f "$f" ] && temp=$(awk '{printf "%.1f",$1/1000}' "$f") && break; done
mac=$(cat /sys/class/net/br-lan/address 2>/dev/null || echo "00:00:00:00:00:00")
fw=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d= -f2 | tr -d "\"'")
board=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
frpc_running=false; pgrep -f frpc >/dev/null 2>&1 && frpc_running=true
printf '{"mac":"%s","board":"%s","fw":"%s","uptime_sec":%s,"load":%s,"cpu_pct":%s,"ram":{"total_kb":%s,"used_kb":%s,"pct":%s},"temp_c":%s,"network":{"wan_ip":"%s","rx_bytes":%s,"tx_bytes":%s},"clients":{"wifi":%s,"dhcp":%s},"vpn_active":%s,"bypass_on":%s,"frpc_running":%s,"ts":%s}\n' \
  "$mac" "$board" "$fw" "$uptime_sec" "$load" "$cpu_pct" "$mem_total" "$mem_used" "$ram_pct" "$temp" "$wan_ip" "$rx_bytes" "$tx_bytes" "$wifi_clients" "$dhcp_clients" "$vpn_running" "$bypass_on" "$frpc_running" "$(date +%s)"
EOF
chmod +x /www/cgi-bin/stats && curl -sk https://localhost/cgi-bin/stats || curl -s http://localhost/cgi-bin/stats
opkg install zram-swap
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_size_mb='128'
uci commit system
/etc/init.d/zram enable
/etc/init.d/zram start
free -m
cat /proc/swaps
cat > /usr/bin/frpc_watchdog.sh << "SCRIPT"
#!/bin/sh
SCRIPT_PATH="/usr/bin/frpc_watchdog.sh"
INITD_PATH="/etc/init.d/frpc_watchdog"
LOGFILE="/tmp/frpc_watchdog.log"
PIDFILE="/tmp/frpc_watchdog.pid"
FRPC_BIN="/usr/bin/frpc"
FRPC_CONF="/etc/frp/frpc.toml"
PING_TARGET="8.8.8.8"
PING_COUNT=2
PING_TIMEOUT=4
CHECK_INTERVAL=30
MAX_LOG_LINES=200

log() {
    local msg="$(date "+%Y-%m-%d %H:%M:%S") $1"
    echo "$msg" >> "$LOGFILE"
    echo "$msg"
    local lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n 100 "$LOGFILE" > "$LOGFILE.tmp"
        mv "$LOGFILE.tmp" "$LOGFILE"
    fi
}

check_internet() {
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1
}

check_frpc() {
    pgrep -x frpc >/dev/null 2>&1
}

start_frpc() {
    [ ! -f "$FRPC_BIN" ] && log "[ERROR] frpc not found: $FRPC_BIN" && return 1
    [ ! -f "$FRPC_CONF" ] && log "[ERROR] config not found: $FRPC_CONF" && return 1
    killall -9 frpc 2>/dev/null
    sleep 1
    "$FRPC_BIN" -c "$FRPC_CONF" >/dev/null 2>&1 &
    sleep 3
    if check_frpc; then
        log "[OK] frpc started, PID: $(pgrep -x frpc)"
    else
        log "[ERROR] frpc failed to start"
        return 1
    fi
}

run_loop() {
    echo $$ > "$PIDFILE"
    log "[START] Watchdog started, PID: $$, interval: ${CHECK_INTERVAL}s"
    while true; do
        if ! check_internet; then
            log "[WAIT] No internet"
            sleep "$CHECK_INTERVAL"
            continue
        fi
        if ! check_frpc; then
            log "[WARN] frpc is down, internet OK — restarting"
            start_frpc
        fi
        sleep "$CHECK_INTERVAL"
    done
}

case "$1" in
    run) run_loop ;;
    *) echo "Usage: $0 run" ;;
esac
SCRIPT
chmod +x /usr/bin/frpc_watchdog.sh

cat > /etc/init.d/frpc_watchdog << "INITEOF"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/frpc_watchdog.sh run
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}
INITEOF
chmod +x /etc/init.d/frpc_watchdog
/etc/init.d/frpc_watchdog enable
/etc/init.d/frpc_watchdog start
echo "=== FRP Watchdog installed, checking every 30s ==="
