#!/bin/bash
set -eo pipefail

# Default to the official entrypoint
ENTRYPOINT_CMD="/usr/local/bin/docker-entrypoint.sh"

# If the site doesn't exist, we need to bootstrap it
if [ ! -d "sites/${FRAPPE_SITE_NAME_HEADER}" ]; then
  echo "INFO: Site ${FRAPPE_SITE_NAME_HEADER} not found. Starting bootstrap..."

  # Use Railway's provided service variables
  : "${MARIADB_HOST:?MARIADB_HOST is not set}"
  : "${MARIADB_PORT:?MARIADB_PORT is not set}"
  : "${MARIADB_USER:?MARIADB_USER is not set}"
  : "${MARIADB_PASSWORD:?MARIADB_PASSWORD is not set}"
  : "${MARIADB_DATABASE:?MARIADB_DATABASE is not set}"
  : "${REDIS_HOST:?REDIS_HOST is not set}"
  : "${REDIS_PORT:?REDIS_PORT is not set}"
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is not set}"
  : "${FRAPPE_SITE_NAME_HEADER:?FRAPPE_SITE_NAME_HEADER is not set}"

  # Configure the database and Redis connections
  bench set-config -g db_host "${MARIADB_HOST}"
  bench set-config -g db_port "${MARIADB_PORT}"
  bench set-config -g redis_cache "redis://${REDIS_HOST}:${REDIS_PORT}"
  bench set-config -g redis_queue "redis://${REDIS_HOST}:${REDIS_PORT}"
  bench set-config -g redis_socketio "redis://${REDIS_HOST}:${REDIS_PORT}"

  # Create the new site
  bench new-site "${FRAPPE_SITE_NAME_HEADER}" \
    --db-name "${MARIADB_DATABASE}" \
    --mariadb-root-username "${MARIADB_USER}" \
    --mariadb-root-password "${MARIADB_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --install-app erpnext \
    --set-default

  echo "INFO: Bootstrap complete. Site created."
else
  echo "INFO: Site ${FRAPPE_SITE_NAME_HEADER} already exists."
fi

# Execute the original entrypoint with any provided arguments
echo "INFO: Starting Frappe services..."
exec "$ENTRYPOINT_CMD" "$@"
