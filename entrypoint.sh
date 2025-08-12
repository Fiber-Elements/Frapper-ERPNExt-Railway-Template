#!/bin/bash
set -eo pipefail

DB_HOST_ARG=$1
DB_PORT_ARG=$2

if [ -z "$DB_HOST_ARG" ] || [ -z "$DB_PORT_ARG" ]; then
  echo "Error: Database host and port must be provided as arguments." >&2
  exit 1
fi

# Wait for the database to be ready
echo "---> Waiting for database at $DB_HOST_ARG:$DB_PORT_ARG..."
while ! nc -z "$DB_HOST_ARG" "$DB_PORT_ARG"; do
  sleep 1
done
echo "---> Database is ready."

# Default to the site name from the public domain, or 'erp.localhost' if not set
SITE_NAME=${RAILWAY_PUBLIC_DOMAIN:-erp.localhost}

# Check if the site directory exists
if [ ! -d "sites/$SITE_NAME" ]; then
  echo "---> Site $SITE_NAME does not exist. Creating..."

  bench new-site "$SITE_NAME" \
    --no-mariadb-socket \
    --db-host "$DB_HOST_ARG" \
    --db-port "$DB_PORT_ARG" \
    --db-name "$DB_DATABASE" \
    --mariadb-root-username "$DB_USER" \
    --mariadb-root-password "$DB_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD"

  echo "---> Installing ERPNext app..."
  bench --site "$SITE_NAME" install-app erpnext

  echo "---> Site $SITE_NAME created."
else
  echo "---> Site $SITE_NAME already exists. Skipping creation."
fi

# Set Redis URLs
bench --site "$SITE_NAME" set-config -g redis_cache "redis://$REDIS_HOST:$REDIS_PORT"
bench --site "$SITE_NAME" set-config -g redis_queue "redis://$REDIS_HOST:$REDIS_PORT"
bench --site "$SITE_NAME" set-config -g redis_socketio "redis://$REDIS_HOST:$REDIS_PORT"

echo "---> Starting Frappe Bench..."
bench start
