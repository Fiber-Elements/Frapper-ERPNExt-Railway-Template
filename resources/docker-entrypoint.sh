#!/usr/bin/env bash
set -euo pipefail

BENCH_HOME="/home/frappe/frappe-bench"
SITES_DIR="$BENCH_HOME/sites"
APPS_TXT_IMAGE="$BENCH_HOME/apps.txt"
APPS_TXT_SITES="$SITES_DIR/apps.txt"

# Ensure working directories exist
mkdir -p "$SITES_DIR"
cd "$SITES_DIR"

# Ensure apps.txt exists in sites (first-boot with empty volume)
if [[ ! -f "$APPS_TXT_SITES" ]]; then
  if [[ -f "$APPS_TXT_IMAGE" ]]; then
    echo "[entrypoint] Seeding sites/apps.txt from image"
    cp "$APPS_TXT_IMAGE" "$APPS_TXT_SITES"
  else
    echo "[entrypoint] WARNING: $APPS_TXT_IMAGE not found; creating minimal apps.txt"
    printf "erpnext\n" > "$APPS_TXT_SITES"
  fi
fi

# Parse DATABASE_URL into DB_* env vars if provided
# Supports mysql:// or postgresql://
if [[ -n "${DATABASE_URL:-}" ]]; then
  proto="${DATABASE_URL%%://*}"
  rest="${DATABASE_URL#*://}"
  creds_host_db="$rest"
  userpass="${creds_host_db%%@*}"
  hostdb="${creds_host_db#*@}"
  dbname="${hostdb#*/}"
  hostport="${hostdb%%/*}"
  dbuser="${userpass%%:*}"
  dbpass="${userpass#*:}"
  dbhost="${hostport%%:*}"
  dbport="${hostport#*:}"
  [[ "$dbport" == "$hostport" ]] && dbport=""

  export DB_TYPE="${proto}"
  export DB_NAME="${DB_NAME:-$dbname}"
  export DB_HOST="${DB_HOST:-$dbhost}"
  if [[ -n "$dbport" ]]; then export DB_PORT="${DB_PORT:-$dbport}"; fi
  export DB_USER="${DB_USER:-$dbuser}"
  export DB_PASSWORD="${DB_PASSWORD:-$dbpass}"

  echo "[entrypoint] Parsed DATABASE_URL: type=$DB_TYPE host=$DB_HOST port=${DB_PORT:-} db=$DB_NAME user=$DB_USER"
fi

# If REDIS_SOCKETIO is not set, derive it from REDIS_QUEUE_URL
if [[ -z "${REDIS_SOCKETIO:-}" && -n "${REDIS_QUEUE_URL:-}" ]]; then
  export REDIS_SOCKETIO="$REDIS_QUEUE_URL"
  echo "[entrypoint] REDIS_SOCKETIO not set; using REDIS_QUEUE_URL=$REDIS_SOCKETIO"
fi

# Optional: AUTO_BOOTSTRAP a site on first boot if requested and variables exist
if [[ "${AUTO_BOOTSTRAP:-0}" == "1" ]]; then
  BOOTSTRAP_SITE_NAME="${BOOTSTRAP_SITE:-}" \
  || BOOTSTRAP_SITE_NAME="${FRAPPE_SITE_NAME_HEADER:-}" || true

  if [[ -n "$BOOTSTRAP_SITE_NAME" && ! -d "$SITES_DIR/$BOOTSTRAP_SITE_NAME" ]]; then
    echo "[entrypoint] AUTO_BOOTSTRAP=1 and site '$BOOTSTRAP_SITE_NAME' not found; attempting creation"

    # Select DB flag
    db_flag=( )
    if [[ "${DB_TYPE:-mysql}" == "mysql" || "${DB_TYPE:-mariadb}" == "mariadb" ]]; then
      db_flag+=("--db-type" "mariadb")
    else
      db_flag+=("--db-type" "postgres")
    fi

    # Create site. Requires DB server to be reachable and user to have privileges.
    bench new-site "$BOOTSTRAP_SITE_NAME" \
      --no-mariadb-socket \
      "${db_flag[@]}" \
      --admin-password "${BOOTSTRAP_ADMIN_PASSWORD:-admin}" \
      --db-name "${DB_NAME:-${BOOTSTRAP_SITE_NAME//./_}}" \
      --db-host "${DB_HOST:-localhost}" \
      ${DB_PORT:+--db-port "$DB_PORT"} \
      --db-user "${DB_USER:-root}" \
      --db-password "${DB_PASSWORD:-}" || {
        echo "[entrypoint] WARNING: Site bootstrap failed; continuing without auto-bootstrap"
      }
  fi
fi

# Exec the passed command (e.g., gunicorn)
exec "$@"
