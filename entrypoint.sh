#!/bin/bash
set -e
set -euo pipefail

# Set core defaults early so SITE_ID derives from a stable host value
# Prefer Railway-provided domain, fallback to a local default
SITE_NAME=${SITE_NAME:-${RAILWAY_PUBLIC_DOMAIN:-erp.localhost}}
PORT=${PORT:-8080}

# Derive a safe SITE_ID (folder/db user base) and SITE_DB_NAME (<=32 for MySQL user)
if [ -z "${SITE_ID:-}" ]; then
  SAFE_ID=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g' | sed -E 's/^_+|_+$//g')
  if [ -z "$SAFE_ID" ]; then SAFE_ID="site"; fi
  SITE_ID="${SAFE_ID:0:30}"
  export SITE_ID
fi
if [ -z "${SITE_DB_NAME:-}" ]; then
  SAFE_DB=$(echo "$SITE_ID" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g' | sed -E 's/^_+|_+$//g')
  if [ -z "$SAFE_DB" ]; then SAFE_DB="site"; fi
  SITE_DB_NAME="${SAFE_DB:0:30}"
  export SITE_DB_NAME
fi

echo "---> Using SITE_NAME (host) = $SITE_NAME"
echo "---> Using SITE_ID (bench) = $SITE_ID"
echo "---> Using SITE_DB_NAME     = $SITE_DB_NAME"

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
REDIS_USERNAME=${REDIS_USERNAME:-${REDISUSER:-}}

# Toggle Redis RQ ACL auth (managed Redis typically doesn't support ACL users)
# 0 = disabled (default/recommended for managed Redis), 1 = enabled (requires bench create-rq-users on self-managed Redis)
USE_RQ_AUTH=${USE_RQ_AUTH:-0}
ALLOW_NEW_SITE=${ALLOW_NEW_SITE:-0}

# If a concrete database name is provided by the platform, prefer it for SITE_DB_NAME
if [ -n "${DB_DATABASE:-}" ]; then
  SITE_DB_NAME="${DB_DATABASE}"
  export SITE_DB_NAME
fi

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

# Re-sync SITE_DB_NAME after possible URL parsing
if [ -n "${DB_DATABASE:-}" ]; then
  SITE_DB_NAME="${DB_DATABASE}"
  export SITE_DB_NAME
fi

# Prefer REDIS_URL; fall back to REDIS_TLS_URL if provided by the platform
if [ -z "${REDIS_URL:-}" ] && [ -n "${REDIS_TLS_URL:-}" ]; then
  REDIS_URL="${REDIS_TLS_URL}"
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

echo "---> Exposing Nginx on PORT=$PORT"
echo "---> DB resolved: host='${DB_HOST}' port='${DB_PORT}' db='${SITE_DB_NAME}' user='${DB_USER:-(bench_default)}'"

# Render Nginx config from template
if [ -f /etc/nginx/templates/default.conf.template ]; then
  echo "---> Rendering Nginx config from template"
  export SITE_NAME PORT SITE_ID
  envsubst '${PORT} ${SITE_NAME} ${SITE_ID}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf
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

# Ensure bench directory and all contents are owned by frappe user
chown -R frappe:frappe /home/frappe/frappe-bench

cd /home/frappe/frappe-bench

# Ensure common_site_config.json exists, as bench commands require it.
if [ ! -f "sites/common_site_config.json" ]; then
  echo "---> sites/common_site_config.json not found. Creating empty config..."
  echo "{}" > sites/common_site_config.json
  chown frappe:frappe sites/common_site_config.json
fi

# If sites/apps.txt does not exist, create it with erpnext
if [ ! -f "sites/apps.txt" ]; then
  echo "---> sites/apps.txt not found. Creating it with default apps..."
  echo -e "frappe\nerpnext" > sites/apps.txt
  chown frappe:frappe sites/apps.txt
fi

# If site exists, configure it. Otherwise, create it.
if [ -d "sites/$SITE_ID" ]; then
  echo "---> Site '$SITE_ID' exists, ensuring configuration is up-to-date."

  # Ensure site_config.json exists, creating an empty one if not.
  if [ ! -f "sites/$SITE_ID/site_config.json" ]; then
    echo "{}" > "sites/$SITE_ID/site_config.json"
    chown frappe:frappe "sites/$SITE_ID/site_config.json"
  fi

  # Unconditionally set current site and update DB config.
  echo "---> Updating DB credentials and setting current site to '$SITE_ID'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench use '$SITE_ID'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_type mariadb"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_host '$DB_HOST'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_port '${DB_PORT:-3306}'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_name '${SITE_DB_NAME}'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_password '$DB_PASSWORD'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_user '$DB_USER'"
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config db_username '$DB_USER'" || true

else
  echo "---> Site '$SITE_ID' does not exist."
  if [ "${ALLOW_NEW_SITE}" != "1" ]; then
    echo "---> ALLOW_NEW_SITE is not '1'. Exiting."
    echo "---> To create a new site on first run, set ALLOW_NEW_SITE=1 and redeploy."
    echo "---> To attach to an existing database, ensure the volume is correctly mounted and contains the site folder."
    exit 1
  fi

  echo "---> Creating new site '$SITE_ID' because ALLOW_NEW_SITE=1."
  # Generate admin password if not provided
  ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(generate_password)}
  echo "---> Admin password will be: $ADMIN_PASSWORD"

  # Create new site
  # Note: --db-root-username is used because bench requires it, but for managed DBs, this is just the standard user.
  su - frappe -c "cd /home/frappe/frappe-bench && bench new-site '$SITE_ID' --force --no-mariadb-socket --db-name '$SITE_DB_NAME' --db-host '$DB_HOST' --db-port '${DB_PORT:-3306}' --db-type mariadb --mariadb-root-username '$DB_USER' --mariadb-root-password '$DB_PASSWORD' --admin-password '$ADMIN_PASSWORD' --install-app erpnext --set-default"

fi

# Always configure RQ ACL auth according to USE_RQ_AUTH (managed Redis -> 0)
su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g use_rq_auth '${USE_RQ_AUTH}'" frappe || true
su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config use_rq_auth '${USE_RQ_AUTH}'" frappe || true

# Set Redis URLs if provided (host/port or direct URL)
if [ -n "${REDIS_HOST:-}" ] && [ -n "${REDIS_PORT:-}" ] || [ -n "${REDIS_URL:-}" ]; then
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
        if [ -n "${REDIS_USERNAME:-}" ]; then
          REDIS_URL_CFG="${SCHEME}://${REDIS_USERNAME}:${REDIS_PASSWORD_ENC}@${H}:${P_CAND}"
        else
          REDIS_URL_CFG="${SCHEME}://:${REDIS_PASSWORD_ENC}@${H}:${P_CAND}"
        fi
      else
        REDIS_URL_CFG="${SCHEME}://${H}:${P_CAND}"
      fi
    fi
  else
    # No REDIS_URL; build from host/port
    if [ -n "${REDIS_PASSWORD:-}" ]; then
      if [ -n "${REDIS_USERNAME:-}" ]; then
        REDIS_URL_CFG="${SCHEME}://${REDIS_USERNAME}:${REDIS_PASSWORD_ENC}@${REDIS_HOST}:${REDIS_PORT}"
      else
        REDIS_URL_CFG="${SCHEME}://:${REDIS_PASSWORD_ENC}@${REDIS_HOST}:${REDIS_PORT}"
      fi
    else
      REDIS_URL_CFG="${SCHEME}://${REDIS_HOST}:${REDIS_PORT}"
    fi
  fi
  # Write to common_site_config (global) and site_config (site) for compatibility
  su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g redis_cache '$REDIS_URL_CFG'" frappe
  su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g redis_queue '$REDIS_URL_CFG'" frappe
  su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g redis_socketio '$REDIS_URL_CFG'" frappe
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config redis_cache '$REDIS_URL_CFG'" frappe
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config redis_queue '$REDIS_URL_CFG'" frappe
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config redis_socketio '$REDIS_URL_CFG'" frappe

  # Also set per-queue keys that some setups read
  su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g redis_queue_default '$REDIS_URL_CFG'" frappe || true
  su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g redis_queue_short '$REDIS_URL_CFG'" frappe || true
  su - frappe -c "cd /home/frappe/frappe-bench && bench set-config -g redis_queue_long '$REDIS_URL_CFG'" frappe || true
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config redis_queue_default '$REDIS_URL_CFG'" frappe || true
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config redis_queue_short '$REDIS_URL_CFG'" frappe || true
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' set-config redis_queue_long '$REDIS_URL_CFG'" frappe || true

  # Log masked URL for troubleshooting
  REDIS_URL_MASKED="$(echo "$REDIS_URL_CFG" | sed -E 's#://[^@]*@#://***@#')"
  echo "---> Configured Redis URL: $REDIS_URL_MASKED"
fi

# Ensure scheduler is enabled only if DB appears initialized
if mysql -N -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$SITE_DB_NAME" -e "SHOW TABLES LIKE 'tabDefaultValue';" >/dev/null 2>&1; then
  su - frappe -c "cd /home/frappe/frappe-bench && bench --site '$SITE_ID' enable-scheduler" frappe || true
else
  echo "---> Skipping enable-scheduler (database '$SITE_DB_NAME' seems empty or inaccessible)"
fi

echo "---> Launching Supervisor"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
