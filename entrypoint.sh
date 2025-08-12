#!/bin/bash
set -euo pipefail

# URL-encode helper (for passwords in URLs)
urlencode() {
  local LC_ALL=C
  local s="$1"
  local out=""
  local i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'${c}" ;;
    esac
  done
  printf '%s' "$out"
}

# Defaults
SITE_NAME=${SITE_NAME:-${RAILWAY_PUBLIC_DOMAIN:-erp.localhost}}
PORT=${PORT:-8080}

# Map Railway plugin env vars if DB_* not set
# MySQL/MariaDB plugin variables
DB_HOST=${DB_HOST:-${MYSQLHOST:-${MARIADBHOST:-}}}
DB_PORT=${DB_PORT:-${MYSQLPORT:-${MARIADBPORT:-3306}}}
DB_DATABASE=${DB_DATABASE:-${MYSQLDATABASE:-$SITE_NAME}}
DB_USER=${DB_USER:-${MYSQLUSER:-${MARIADBUSER:-}}}
DB_PASSWORD=${DB_PASSWORD:-${MYSQLPASSWORD:-${MARIADBPASSWORD:-}}}

# Redis plugin variables
REDIS_HOST=${REDIS_HOST:-${REDISHOST:-}}
REDIS_PORT=${REDIS_PORT:-${REDISPORT:-6379}}
REDIS_PASSWORD=${REDIS_PASSWORD:-${REDISPASSWORD:-}}

# URL fallbacks: DATABASE_URL / MYSQL_URL
if [ -z "${DB_HOST:-}" ] && [ -n "${DATABASE_URL:-${MYSQL_URL:-}}" ]; then
  DB_URL="${DATABASE_URL:-${MYSQL_URL:-}}"
  rest="${DB_URL#*://}"
  creds="${rest%@*}"
  hostpath="${rest#*@}"
  # username:password
  if [ -n "$creds" ] && [ "$creds" != "$rest" ]; then
    DB_USER=${DB_USER:-"${creds%%:*}"}
    DB_PASSWORD_TMP="${creds#*:}"
    DB_PASSWORD=${DB_PASSWORD:-"${DB_PASSWORD_TMP%%@*}"}
  fi
  hostport="${hostpath%%/*}"
  DB_DATABASE_TMP="${hostpath#*/}"
  DB_DATABASE_TMP="${DB_DATABASE_TMP%%\?*}"
  DB_DATABASE=${DB_DATABASE:-"$DB_DATABASE_TMP"}
  DB_HOST=${DB_HOST:-"${hostport%%:*}"}
  DB_PORT_CAND="${hostport#*:}"
  if [ "$DB_PORT_CAND" = "$hostport" ] || [ -z "$DB_PORT_CAND" ]; then DB_PORT_CAND=3306; fi
  DB_PORT=${DB_PORT:-"$DB_PORT_CAND"}
fi

# URL fallback: REDIS_URL
if [ -z "${REDIS_HOST:-}" ] && [ -n "${REDIS_URL:-}" ]; then
  RU="${REDIS_URL}"
  rest="${RU#*://}"
  if [[ "$rest" == *"@"* ]]; then
    creds="${rest%@*}"
    hostdb="${rest#*@}"
    # creds may be ":password" or "user:password"; we only need password
    if [ -n "$creds" ] && [ "$creds" != "$rest" ]; then
      if [[ "$creds" == *":"* ]]; then
        REDIS_PASSWORD=${REDIS_PASSWORD:-"${creds#*:}"}
      else
        REDIS_PASSWORD=${REDIS_PASSWORD:-"$creds"}
      fi
    fi
  else
    hostdb="$rest"
  fi
  hostport="${hostdb%%/*}"
  REDIS_HOST=${REDIS_HOST:-"${hostport%%:*}"}
  REDIS_PORT_CAND="${hostport#*:}"
  if [ "$REDIS_PORT_CAND" = "$hostport" ] || [ -z "$REDIS_PORT_CAND" ]; then REDIS_PORT_CAND=6379; fi
  REDIS_PORT=${REDIS_PORT:-"$REDIS_PORT_CAND"}
fi

# If password still empty but REDIS_URL provided, extract password regardless of host presence
if [ -z "${REDIS_PASSWORD:-}" ] && [ -n "${REDIS_URL:-}" ]; then
  RU="${REDIS_URL}"
  rest="${RU#*://}"
  if [[ "$rest" == *"@"* ]]; then
    creds="${rest%@*}"
    if [ -n "$creds" ] && [ "$creds" != "$rest" ]; then
      if [[ "$creds" == *":"* ]]; then
        REDIS_PASSWORD="${creds#*:}"
      else
        REDIS_PASSWORD="$creds"
      fi
    fi
  fi
fi

echo "---> Using SITE_NAME=$SITE_NAME"
echo "---> Exposing Nginx on PORT=$PORT"

# Render Nginx config from template
if [ -f /etc/nginx/templates/default.conf.template ]; then
  echo "---> Rendering Nginx config from template"
  export SITE_NAME PORT
  envsubst '${PORT} ${SITE_NAME}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf
fi

# Disable default site if present to avoid port conflicts
rm -f /etc/nginx/sites-enabled/default || true

# Wait for the database to be ready
ATTEMPTS=0
until [ -n "${DB_HOST:-}" ] && [ -n "${DB_PORT:-}" ] || [ "$ATTEMPTS" -ge 10 ]; do
  # Re-evaluate mappings in case plugin vars are late
  DB_HOST=${DB_HOST:-${MYSQLHOST:-${MARIADBHOST:-}}}
  DB_PORT=${DB_PORT:-${MYSQLPORT:-${MARIADBPORT:-3306}}}
  ATTEMPTS=$((ATTEMPTS+1))
  [ -n "${DB_HOST:-}" ] && [ -n "${DB_PORT:-}" ] && break
  echo "---> Waiting for DB env vars to be present (attempt $ATTEMPTS/10)..."
  sleep 1
done
if [ -z "${DB_HOST:-}" ] || [ -z "${DB_PORT:-}" ]; then
  echo "---> ERROR: DB_HOST and/or DB_PORT not set."
  echo "---> Diagnostics: MYSQLHOST='${MYSQLHOST:-}', MYSQLPORT='${MYSQLPORT:-}', MARIADBHOST='${MARIADBHOST:-}', MARIADBPORT='${MARIADBPORT:-}', DATABASE_URL='${DATABASE_URL:-}', MYSQL_URL='${MYSQL_URL:-}'"
  exit 1
fi

echo "---> Waiting for database connection at $DB_HOST:$DB_PORT..."
until nc -z "$DB_HOST" "$DB_PORT"; do
  sleep 1
done
echo "---> Database is ready."

# Optionally wait for Redis
if [ -n "${REDIS_HOST:-}" ] && [ -n "${REDIS_PORT:-}" ]; then
  echo "---> Waiting for Redis at $REDIS_HOST:$REDIS_PORT..."
  until nc -z "$REDIS_HOST" "$REDIS_PORT"; do
    sleep 1
  done
  echo "---> Redis is ready."
fi

cd /home/frappe/frappe-bench

# Create site if not exists
if [ ! -d "sites/$SITE_NAME" ]; then
  # Generate ADMIN_PASSWORD if not provided (template usually sets this)
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
    if [ -z "$ADMIN_PASSWORD" ]; then ADMIN_PASSWORD="Admin$(date +%s)"; fi
    echo "---> Generated ADMIN_PASSWORD for first run: $ADMIN_PASSWORD"
  fi
  echo "---> Creating site $SITE_NAME..."
  su -s /bin/bash -c "bench new-site '$SITE_NAME' \
    --no-mariadb-socket \
    --db-type mariadb \
    --db-host '$DB_HOST' \
    --db-port '$DB_PORT' \
    --db-name '${SITE_DB_NAME:-$SITE_NAME}' \
    --db-root-username '${DB_USER}' \
    --db-root-password '${DB_PASSWORD}' \
    --admin-password '${ADMIN_PASSWORD}'" frappe

  echo "---> Installing ERPNext app..."
  su -s /bin/bash -c "bench --site '$SITE_NAME' install-app erpnext" frappe

  echo "---> Site $SITE_NAME created."
else
  echo "---> Site $SITE_NAME already exists."
fi

# Set Redis URLs if provided
if [ -n "${REDIS_HOST:-}" ] && [ -n "${REDIS_PORT:-}" ]; then
  # Determine scheme and host:port from variables/URL
  SCHEME="redis"
  # Pre-encode password if present for safe URL building
  REDIS_PASSWORD_ENC="${REDIS_PASSWORD:-}"
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    REDIS_PASSWORD_ENC="$(urlencode "${REDIS_PASSWORD}")"
  fi
  if [ -n "${REDIS_URL:-}" ]; then
    # Extract scheme and host:port
    SCHEME="${REDIS_URL%%://*}"
    rest="${REDIS_URL#*://}"
    if [[ "$rest" == *"@"* ]]; then
      # Credentials present; use as-is
      REDIS_URL_CFG="${REDIS_URL}"
    else
      # No creds in URL; build using password if available
      hostdb="${rest}"
      hostport="${hostdb%%/*}"
      H="${hostport%%:*}"
      P_CAND="${hostport#*:}"
      if [ "$P_CAND" = "$hostport" ] || [ -z "$P_CAND" ]; then P_CAND="${REDIS_PORT}"; fi
      if [ -n "${REDIS_PASSWORD:-}" ]; then
        REDIS_URL_CFG="${SCHEME}://:${REDIS_PASSWORD_ENC}@${H}:${P_CAND}"
      else
        REDIS_URL_CFG="${SCHEME}://${H}:${P_CAND}"
      fi
    fi
  else
    # No REDIS_URL; build from host/port
    if [ -n "${REDIS_PASSWORD:-}" ]; then
      REDIS_URL_CFG="${SCHEME}://:${REDIS_PASSWORD_ENC}@${REDIS_HOST}:${REDIS_PORT}"
    else
      REDIS_URL_CFG="${SCHEME}://${REDIS_HOST}:${REDIS_PORT}"
    fi
  fi
  # Write to common_site_config (global) and site_config (site) for compatibility
  su -s /bin/bash -c "bench set-config -g redis_cache '$REDIS_URL_CFG'" frappe
  su -s /bin/bash -c "bench set-config -g redis_queue '$REDIS_URL_CFG'" frappe
  su -s /bin/bash -c "bench set-config -g redis_socketio '$REDIS_URL_CFG'" frappe
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config redis_cache '$REDIS_URL_CFG'" frappe
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config redis_queue '$REDIS_URL_CFG'" frappe
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config redis_socketio '$REDIS_URL_CFG'" frappe

  # Also set per-queue keys that some setups read
  su -s /bin/bash -c "bench set-config -g redis_queue_default '$REDIS_URL_CFG'" frappe || true
  su -s /bin/bash -c "bench set-config -g redis_queue_short '$REDIS_URL_CFG'" frappe || true
  su -s /bin/bash -c "bench set-config -g redis_queue_long '$REDIS_URL_CFG'" frappe || true
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config redis_queue_default '$REDIS_URL_CFG'" frappe || true
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config redis_queue_short '$REDIS_URL_CFG'" frappe || true
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config redis_queue_long '$REDIS_URL_CFG'" frappe || true

  # Ensure RQ ACL auth is disabled when using external managed Redis
  su -s /bin/bash -c "bench set-config -g use_rq_auth 0" frappe || true
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config use_rq_auth 0" frappe || true

  # Log masked URL for troubleshooting
  REDIS_URL_MASKED="$(echo "$REDIS_URL_CFG" | sed -E 's#://[^@]*@#://***@#')"
  echo "---> Configured Redis URL: $REDIS_URL_MASKED"
fi

# Ensure scheduler is enabled
su -s /bin/bash -c "bench --site '$SITE_NAME' enable-scheduler" frappe || true

echo "---> Launching Supervisor"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
