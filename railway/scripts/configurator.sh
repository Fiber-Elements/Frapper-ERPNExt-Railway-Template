#!/usr/bin/env bash
set -euo pipefail

# This script writes common_site_config.json settings for DB and Redis
# Required env: DB_HOST, DB_PORT, REDIS_CACHE, REDIS_QUEUE, SOCKETIO_PORT (default 9000)

DB_HOST=${DB_HOST:-}
DB_PORT=${DB_PORT:-3306}
REDIS_CACHE=${REDIS_CACHE:-}
REDIS_QUEUE=${REDIS_QUEUE:-}
SOCKETIO_PORT=${SOCKETIO_PORT:-9000}

if [[ -z "$DB_HOST" || -z "$REDIS_CACHE" || -z "$REDIS_QUEUE" ]]; then
  echo "[ERROR] DB_HOST, REDIS_CACHE and REDIS_QUEUE must be set" >&2
  exit 1
fi

cd /home/frappe/frappe-bench

# Regenerate apps.txt (optional; mirrors pwd.yml behavior)
ls -1 apps > sites/apps.txt || true

bench set-config -g db_host "$DB_HOST"
bench set-config -gp db_port "$DB_PORT"
bench set-config -g redis_cache "redis://$REDIS_CACHE"
bench set-config -g redis_queue "redis://$REDIS_QUEUE"
bench set-config -g redis_socketio "redis://$REDIS_QUEUE"
bench set-config -gp socketio_port "$SOCKETIO_PORT"

echo "[OK] common_site_config.json updated"
