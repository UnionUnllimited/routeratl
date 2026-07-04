# ═══ Смена FRP-сервера + отвязка watchdog от manifest ═══════════════
NEW_SERVER="frp.pandora361.online"
NEW_TOKEN="21658aa79e70daf3a9e7ededa24855dcdf791a8606a4da6f8d7cb594513202d2"

# 1) бэкапы
cp /etc/rc.local            /etc/rc.local.bak.$(date +%s)            2>/dev/null
cp /etc/frp/frpc.ini        /etc/frp/frpc.ini.bak.$(date +%s)        2>/dev/null
cp /usr/bin/frpc_watchdog.sh /usr/bin/frpc_watchdog.sh.bak.$(date +%s) 2>/dev/null

# 2) новый сервер/токен в rc.local (источник при загрузке) и в текущем конфиге
sed -i -e "s|^\(\s*server_addr = \).*|\1${NEW_SERVER}|" \
       -e "s|^\(\s*token = \).*|\1${NEW_TOKEN}|" /etc/rc.local 2>/dev/null
sed -i -e "s|^server_addr = .*|server_addr = ${NEW_SERVER}|" \
       -e "s|^token = .*|token = ${NEW_TOKEN}|" /etc/frp/frpc.ini 2>/dev/null

# 3) заменяем watchdog на версию БЕЗ manifest — только проверка живости
cat > /usr/bin/frpc_watchdog.sh << 'WDEOF'
#!/bin/sh
# FRP Watchdog — только проверка работы frpc. Manifest НЕ используется,
# сервер НЕ меняется. Задан вручную в /etc/frp/frpc.ini.
LOG_TAG="frpc_watchdog"

# frpc запущен?
if ! pgrep -f "frpc -c" >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "frpc не запущен — перезапускаем"
    /etc/init.d/frpc restart
    exit 0
fi

# Проверяем доступность текущего сервера
server=$(grep "^server_addr" /etc/frp/frpc.ini 2>/dev/null | awk '{print $3}')
if [ -n "$server" ]; then
    curl -s --max-time 10 "http://${server}" >/dev/null 2>&1 && exit 0
    ping -c2 -W3 "$server" >/dev/null 2>&1 && exit 0
fi

logger -t "$LOG_TAG" "FRP недоступен — перезапускаем"
/etc/init.d/frpc restart
WDEOF
chmod +x /usr/bin/frpc_watchdog.sh

# 4) применяем
/etc/init.d/frpc restart 2>/dev/null || { pkill frpc; sleep 1; frpc -c /etc/frp/frpc.ini & }
logger -t atlanta "FRP -> ${NEW_SERVER}; watchdog без manifest"
# ═══════════════════════════════════════════════════════════════════
