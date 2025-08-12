#!/bin/bash
set -eo pipefail

# Wait for Railway to provide the environment variables
while [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$ADMIN_PASSWORD" ]; do
  echo "Waiting for database and admin credentials to be available..."
  sleep 5
done

# Default to the site name from the public domain, or 'erp.localhost' if not set
SITE_NAME=${RAILWAY_PUBLIC_DOMAIN:-erp.localhost}

# Check if the site directory exists
if [ ! -d "sites/$SITE_NAME" ]; then
  echo "---> Site $SITE_NAME does not exist. Creating..."

  bench new-site "$SITE_NAME" \
    --no-mariadb-socket \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
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

echo "---> Starting bench..."

# Start the Frappe services
bench start
