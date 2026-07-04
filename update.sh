# ─── Смена FRP-сервера ────────────────────────────────────────────
NEW_SERVER="frp.pandora361.online"
NEW_TOKEN="21658aa79e70daf3a9e7ededa24855dcdf791a8606a4da6f8d7cb594513202d2"

cp /etc/rc.local     /etc/rc.local.bak.$(date +%s)     2>/dev/null
cp /etc/frp/frpc.ini /etc/frp/frpc.ini.bak.$(date +%s) 2>/dev/null

# rc.local — источник при загрузке
sed -i -e "s|^\(\s*server_addr = \).*|\1${NEW_SERVER}|" \
       -e "s|^\(\s*token = \).*|\1${NEW_TOKEN}|" /etc/rc.local 2>/dev/null

# frpc.ini — текущий конфиг
sed -i -e "s|^server_addr = .*|server_addr = ${NEW_SERVER}|" \
       -e "s|^token = .*|token = ${NEW_TOKEN}|" /etc/frp/frpc.ini 2>/dev/null

/etc/init.d/frpc restart 2>/dev/null || { pkill frpc; sleep 1; frpc -c /etc/frp/frpc.ini & }
logger -t atlanta "FRP -> ${NEW_SERVER}"
# ──────────────────────────────────────────────────────────────────
