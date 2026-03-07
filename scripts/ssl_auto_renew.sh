#!/usr/bin/env bash
set -Eeuo pipefail

# This script handles both initial issuance and periodic renewal using certbot in Docker.
# It then copies the latest cert/key to host nginx ssl dir and reloads nginx.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOMAIN="${DOMAIN:-bitfsae.xin}"
ALT_DOMAIN="${ALT_DOMAIN:-www.bitfsae.xin}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot:latest}"

LE_DIR="${LE_DIR:-/etc/letsencrypt}"
WEBROOT_HOST="${WEBROOT_HOST:-/var/www/certbot}"
CERT_OUT_DIR="${CERT_OUT_DIR:-/etc/nginx/ssl}"

TARGET_CERT="${TARGET_CERT:-${CERT_OUT_DIR}/${DOMAIN}.pem}"
TARGET_KEY="${TARGET_KEY:-${CERT_OUT_DIR}/${DOMAIN}.key}"
RELOAD_CMD="${RELOAD_CMD:-systemctl reload nginx}"

log() {
  printf '[ssl-auto] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing command: $1"
    exit 1
  fi
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    log "Root privilege required for: $*"
    exit 1
  fi
}

certbot_run() {
  docker run --rm \
    -v "${LE_DIR}:/etc/letsencrypt" \
    -v "${WEBROOT_HOST}:/var/www/certbot" \
    "${CERTBOT_IMAGE}" "$@"
}

sync_cert_files() {
  local live_dir="${LE_DIR}/live/${DOMAIN}"

  if [[ ! -f "${live_dir}/fullchain.pem" || ! -f "${live_dir}/privkey.pem" ]]; then
    log "Expected cert files not found in ${live_dir}"
    exit 1
  fi

  as_root mkdir -p "${CERT_OUT_DIR}"
  as_root install -m 0644 "${live_dir}/fullchain.pem" "${TARGET_CERT}"
  as_root install -m 0600 "${live_dir}/privkey.pem" "${TARGET_KEY}"
  log "Updated ${TARGET_CERT} and ${TARGET_KEY}"
}

reload_nginx() {
  log "Reloading nginx"
  as_root bash -lc "${RELOAD_CMD}"
}

print_acme_hint() {
  log "Make sure host nginx allows ACME challenge on HTTP (port 80), for example:"
  cat <<'EOF'
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
    default_type "text/plain";
    try_files $uri =404;
}
EOF
}

main() {
  require_cmd docker

  if [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
    log "Please set LETSENCRYPT_EMAIL, e.g.:"
    log "LETSENCRYPT_EMAIL=ops@bitfsae.xin $0"
    exit 1
  fi

  as_root mkdir -p "${LE_DIR}" "${WEBROOT_HOST}" "${CERT_OUT_DIR}"

  local domain_args=(-d "${DOMAIN}")
  if [[ -n "${ALT_DOMAIN}" && "${ALT_DOMAIN}" != "${DOMAIN}" ]]; then
    domain_args+=(-d "${ALT_DOMAIN}")
  fi

  if [[ ! -f "${LE_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
    log "No existing cert found, requesting a new certificate"
    print_acme_hint
    certbot_run certonly \
      --webroot -w /var/www/certbot \
      "${domain_args[@]}" \
      --email "${LETSENCRYPT_EMAIL}" \
      --agree-tos \
      --no-eff-email \
      --non-interactive
  else
    log "Existing cert found, running renewal"
    certbot_run renew \
      --webroot -w /var/www/certbot \
      --non-interactive
  fi

  sync_cert_files
  reload_nginx
  log "Done"
}

main "$@"
