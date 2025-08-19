#!/usr/bin/env bash
set -euo pipefail

# One-time: create ERPNext site and install app
# Required env: SITE_NAME, ADMIN_PASSWORD, DB_HOST, DB_PORT, DB_ROOT_PASSWORD

SITE_NAME=${SITE_NAME:-}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
DB_HOST=${DB_HOST:-}
DB_PORT=${DB_PORT:-3306}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-}

if [[ -z "$SITE_NAME" || -z "$ADMIN_PASSWORD" || -z "$DB_HOST" || -z "$DB_ROOT_PASSWORD" ]]; then
  echo "[ERROR] SITE_NAME, ADMIN_PASSWORD, DB_HOST, DB_ROOT_PASSWORD must be set" >&2
  exit 1
fi

# wait-for-it may exist in the image; try it first, else fallback to bash loop
if command -v wait-for-it >/dev/null 2>&1; then
  wait-for-it -t 180 "${DB_HOST}:${DB_PORT}"
else
  echo "[WARN] wait-for-it not found; falling back to TCP wait loop"
  for i in {1..180}; do
    (echo > \/dev\/tcp\/"$DB_HOST"\/"$DB_PORT") >/dev/null 2>&1 && break || true
    sleep 1
  done
fi

cd /home/frappe/frappe-bench

# Ensure common_site_config.json has DB/Redis configured (configurator should be run first)
if ! grep -hs '^' sites/common_site_config.json | jq -e '.db_host // empty' >/dev/null; then
  echo "[ERROR] sites/common_site_config.json missing db_host; run configurator first" >&2
  exit 1
fi

# Create site
bench new-site \
  --mariadb-user-host-login-scope='%' \
  --admin-password="$ADMIN_PASSWORD" \
  --db-root-username=root \
  --db-root-password="$DB_ROOT_PASSWORD" \
  "$SITE_NAME"

# Install ERPNext
bench --site "$SITE_NAME" install-app erpnext

# Set default site for nginx routing if FRAPPE_SITE_NAME_HEADER isn't used
# Compose setup writes sites/currentsite.txt; mirror that behavior
printf "%s\n" "$SITE_NAME" > sites/currentsite.txt

echo "[OK] Site '$SITE_NAME' created and ERPNext installed"
