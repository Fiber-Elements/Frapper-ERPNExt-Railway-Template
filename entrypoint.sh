#!/bin/bash
set -eo pipefail

# Default to the site name 'erp.localhost' if not set
SITE_NAME=${SITE_NAME:-erp.localhost}

# Check if the site directory exists
if [ ! -d "sites/$SITE_NAME" ]; then
  echo "---> Site $SITE_NAME does not exist. Creating..."

  bench new-site "$SITE_NAME" \
    --no-mariadb-socket \
    --db-host "$MARIADB_HOST" \
    --db-port "$MARIADB_PORT" \
    --db-name "$MARIADB_DATABASE" \
    --db-user "$MARIADB_USER" \
    --db-password "$MARIADB_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext

  echo "---> Site $SITE_NAME created."
else
  echo "---> Site $SITE_NAME already exists. Skipping creation."
fi

# Set Redis URLs
bench --site "$SITE_NAME" set-config -g redis_cache "redis://$REDIS_HOST:$REDIS_PORT"
bench --site "$SITE_NAME" set-config -g redis_queue "redis://$REDIS_HOST:$REDIS_PORT"
bench --site "$SITE_NAME" set-config -g redis_socketio "redis://$REDIS_HOST:$REDIS_PORT"

echo "---> Starting bench..."

# Start the Frappe services
bench start
