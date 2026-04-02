#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-bitfsae}"
WEB_ROOT="${WEB_ROOT:-/opt/bitfsae}"
ECOSYSTEM_FILE="${ECOSYSTEM_FILE:-$WEB_ROOT/ecosystem.config.cjs}"
PM2_OWNER="${PM2_OWNER:-${SUDO_USER:-${USER:-}}}"

usage() {
  cat <<'EOF'
Usage:
  site_switch.sh down    # 备案阶段下线站点 (只停 Web, 不停遥测容器)
  site_switch.sh up      # 备案结束后恢复站点

Optional env:
  APP_NAME=bitfsae
  WEB_ROOT=/opt/bitfsae
  ECOSYSTEM_FILE=/opt/bitfsae/ecosystem.config.cjs
  PM2_OWNER=ubuntu
EOF
}

require_pm2() {
  if ! command -v pm2 >/dev/null 2>&1; then
    echo "Error: pm2 not found." >&2
    exit 1
  fi
}

run_pm2() {
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "$PM2_OWNER" ]]; then
    sudo -u "$PM2_OWNER" -H pm2 "$@"
  else
    pm2 "$@"
  fi
}

app_exists_in_pm2() {
  run_pm2 jlist | grep -q '"name":"'"$APP_NAME"'"'
}

do_down() {
  require_pm2

  if app_exists_in_pm2; then
    run_pm2 stop "$APP_NAME"
    run_pm2 save
    echo "[OK] App '$APP_NAME' stopped and PM2 state saved."
  else
    echo "[INFO] App '$APP_NAME' not found in PM2 list, nothing to stop."
  fi

  echo "[CHECK] Current PM2 process list:"
  run_pm2 ls
}

do_up() {
  require_pm2

  if app_exists_in_pm2; then
    run_pm2 start "$APP_NAME"
    run_pm2 save
    echo "[OK] App '$APP_NAME' started and PM2 state saved."
  elif [[ -f "$ECOSYSTEM_FILE" ]]; then
    (
      cd "$WEB_ROOT"
      run_pm2 start "$ECOSYSTEM_FILE" --only "$APP_NAME"
    )
    run_pm2 save
    echo "[OK] Started '$APP_NAME' from ecosystem file and saved PM2 state."
  else
    echo "Error: app '$APP_NAME' not found in PM2 and ecosystem file missing: $ECOSYSTEM_FILE" >&2
    exit 1
  fi

  echo "[CHECK] Local health probe:"
  curl -I --max-time 5 http://127.0.0.1:3000 || true
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    down)
      do_down
      ;;
    up)
      do_up
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Error: invalid action '$1'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
