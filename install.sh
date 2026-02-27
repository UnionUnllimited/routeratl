#!/bin/sh
set -eu

APP_PATH="/usr/bin/gh-script-panel"
TMP_SCRIPT="/tmp/gh_script_installer.sh"

# ------------------------------------------------------------
# Заполните ссылки ниже своими URL (raw github/gist).
# Если ссылка пустая, пункт меню сообщит что нужно заполнить URL.
# ------------------------------------------------------------
PASSWALL_URL="https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/paswall.sh"
ZAPRET_URL="https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/zapret.sh"
FRP_URL="https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/frp.sh"
TIME_URL=""
ADMIN_URL="https://raw.githubusercontent.com/UnionUnllimited/routeratl/refs/heads/main/adminpanel.sh"

usage() {
  cat <<'USAGE'
OpenWrt Button Panel (SSH)

Usage:
  sh openwrt-github-script-panel.sh            # run panel now
  sh openwrt-github-script-panel.sh run        # run panel now
  sh openwrt-github-script-panel.sh install    # install as /usr/bin/gh-script-panel
  sh openwrt-github-script-panel.sh remove     # remove installed command
USAGE
}

is_allowed_url() {
  case "$1" in
    https://raw.githubusercontent.com/*|https://github.com/*|https://gist.githubusercontent.com/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_script_url() {
  NAME="$1"
  URL="$2"

  if [ -z "$URL" ]; then
    echo "[x] Для кнопки '$NAME' ссылка не задана. Откройте скрипт и заполните переменную URL."
    return 1
  fi

  if ! is_allowed_url "$URL"; then
    echo "[x] '$NAME': ссылка не разрешена"
    echo "    Разрешены: github.com, raw.githubusercontent.com, gist.githubusercontent.com"
    return 1
  fi

  rm -f "$TMP_SCRIPT"
  echo "[i] $NAME -> скачивание: $URL"
  if ! wget -O "$TMP_SCRIPT" "$URL"; then
    echo "[x] Ошибка скачивания"
    rm -f "$TMP_SCRIPT"
    return 1
  fi

  chmod +x "$TMP_SCRIPT"
  echo "[i] Запуск: $NAME"
  sh "$TMP_SCRIPT"
  RC=$?
  rm -f "$TMP_SCRIPT"
  echo "[i] Код завершения: $RC"
  return "$RC"
}

show_buttons() {
  echo "========================================"
  echo "        OpenWrt Button Panel (SSH)"
  echo "========================================"
  echo "1) Установить PassWall"
  echo "2) Установить Zapret"
  echo "3) Установить FRP"
  echo "4) Время"
  echo "5) Админ панель"
  echo "6) Свой URL (разово)"
  echo "7) Выход"
}

run_custom_once() {
  printf "Вставьте URL скрипта: "
  read -r URL
  run_script_url "Custom" "$URL"
}

panel() {
  while true; do
    echo
    show_buttons
    printf "Выберите [1-7]: "
    read -r CHOICE

    case "$CHOICE" in
      1) run_script_url "PassWall" "$PASSWALL_URL" || true ;;
      2) run_script_url "Zapret" "$ZAPRET_URL" || true ;;
      3) run_script_url "FRP" "$FRP_URL" || true ;;
      4) run_script_url "Time" "$TIME_URL" || true ;;
      5) run_script_url "Admin" "$ADMIN_URL" || true ;;
      6) run_custom_once || true ;;
      7) echo "Выход."; return 0 ;;
      *) echo "[x] Неверный выбор" ;;
    esac

    printf "Нажмите Enter для продолжения... "
    read -r _
  done
}

install_panel() {
  cp "$0" "$APP_PATH"
  chmod 755 "$APP_PATH"
  echo "[✓] Установлено: $APP_PATH"
  echo "Запуск: gh-script-panel"
}

remove_panel() {
  rm -f "$APP_PATH" "$TMP_SCRIPT"
  echo "[✓] Удалено: $APP_PATH"
}

case "${1:-run}" in
  run) panel ;;
  install) install_panel ;;
  remove) remove_panel ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
