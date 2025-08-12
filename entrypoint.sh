#!/bin/bash
set -euo pipefail

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
    hostdb="${rest#*@}"
  else
    hostdb="$rest"
  fi
  hostport="${hostdb%%/*}"
  REDIS_HOST=${REDIS_HOST:-"${hostport%%:*}"}
  REDIS_PORT_CAND="${hostport#*:}"
  if [ "$REDIS_PORT_CAND" = "$hostport" ] || [ -z "$REDIS_PORT_CAND" ]; then REDIS_PORT_CAND=6379; fi
  REDIS_PORT=${REDIS_PORT:-"$REDIS_PORT_CAND"}
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
    --db-name '${DB_DATABASE:-$SITE_NAME}' \
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
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config -g redis_cache 'redis://$REDIS_HOST:$REDIS_PORT'" frappe
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config -g redis_queue 'redis://$REDIS_HOST:$REDIS_PORT'" frappe
  su -s /bin/bash -c "bench --site '$SITE_NAME' set-config -g redis_socketio 'redis://$REDIS_HOST:$REDIS_PORT'" frappe
fi

# Ensure scheduler is enabled
su -s /bin/bash -c "bench --site '$SITE_NAME' enable-scheduler" frappe || true

echo "---> Launching Supervisor"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
