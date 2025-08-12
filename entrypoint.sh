#!/bin/bash
set -euo pipefail

# Defaults
SITE_NAME=${SITE_NAME:-${RAILWAY_PUBLIC_DOMAIN:-erp.localhost}}
PORT=${PORT:-8080}

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
if [ -z "${DB_HOST:-}" ] || [ -z "${DB_PORT:-}" ]; then
  echo "---> ERROR: DB_HOST and DB_PORT must be set"
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
  echo "---> Creating site $SITE_NAME..."
  su -s /bin/bash -c "bench new-site '$SITE_NAME' \
    --no-mariadb-socket \
    --db-type mariadb \
    --db-host '$DB_HOST' \
    --db-port '$DB_PORT' \
    --db-name '${DB_DATABASE:-$SITE_NAME}' \
    --mariadb-root-username '${DB_USER}' \
    --mariadb-root-password '${DB_PASSWORD}' \
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
