#!/bin/sh
# ═══ Перевод FRP на новый сервер + удаление manifest-отката ══════════
NEW_SERVER="frp.pandora361.online"
NEW_TOKEN="21658aa79e70daf3a9e7ededa24855dcdf791a8606a4da6f8d7cb594513202d2"

# 1) бэкапы
for f in /etc/rc.local /etc/frp/frpc.ini /usr/bin/frpc_watchdog.sh; do
  [ -f "$f" ] && cp "$f" "${f}.bak.$(date +%s)" 2>/dev/null
done

# 2) новый сервер/токен в текущем конфиге и в rc.local (источник при загрузке)
[ -f /etc/frp/frpc.ini ] && sed -i \
  -e "s|^server_addr = .*|server_addr = ${NEW_SERVER}|" \
  -e "s|^token = .*|token = ${NEW_TOKEN}|" /etc/frp/frpc.ini
[ -f /etc/rc.local ] && sed -i \
  -e "s|^\(\s*server_addr = \).*|\1${NEW_SERVER}|" \
  -e "s|^\(\s*token = \).*|\1${NEW_TOKEN}|" /etc/rc.local

# 3) watchdog БЕЗ manifest и БЕЗ отката — только держит frpc живым
cat > /usr/bin/frpc_watchdog.sh << 'WDEOF'
#!/bin/sh
# FRP watchdog (облегчённый): manifest не читается, сервер не меняется.
# Только перезапуск, если процесс упал.
LOG_TAG="frpc_watchdog"
pgrep -f "frpc -c" >/dev/null 2>&1 || {
    logger -t "$LOG_TAG" "frpc не запущен — перезапуск"
    /etc/init.d/frpc restart
}
WDEOF
chmod +x /usr/bin/frpc_watchdog.sh

# 4) применяем
/etc/init.d/frpc restart 2>/dev/null || { pkill frpc 2>/dev/null; sleep 1; /etc/init.d/frpc start 2>/dev/null; }
sleep 6
logger -t atlanta "FRP -> ${NEW_SERVER}; manifest revert removed"
echo "[OK] сервер теперь:"; grep "^server_addr" /etc/frp/frpc.ini
logread | grep -i frpc | tail -6
# ════════════════════════════════════════════════════════════════════
