#!/bin/bash
set -e

# Railway-specific entrypoint for ERPNext
echo "[INFO] Starting ERPNext on Railway..."

# Set dynamic port from Railway
export FRONTEND_PORT=${PORT:-8080}
export BACKEND_PORT=8000
export SOCKETIO_PORT=9000

# Ensure required environment variables
export FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER:-frontend}
export BACKEND=${BACKEND:-127.0.0.1:8000}
export SOCKETIO=${SOCKETIO:-127.0.0.1:9000}

# Database configuration
export DB_HOST=${DB_HOST:-}
export DB_PORT=${DB_PORT:-3306}
export DB_PASSWORD=${DB_PASSWORD:-}

# Redis configuration
export REDIS_CACHE_URL=${REDIS_CACHE_URL:-}
export REDIS_QUEUE_URL=${REDIS_QUEUE_URL:-}
export REDIS_SOCKETIO_URL=${REDIS_SOCKETIO_URL:-$REDIS_CACHE_URL}

# Parse Redis URLs to get host:port format
if [[ -n "$REDIS_CACHE_URL" ]]; then
    REDIS_CACHE=$(echo "$REDIS_CACHE_URL" | sed -e 's|redis://||' -e 's|@.*||' -e 's|.*@||' -e 's|/.*||')
    export REDIS_CACHE
fi

if [[ -n "$REDIS_QUEUE_URL" ]]; then
    REDIS_QUEUE=$(echo "$REDIS_QUEUE_URL" | sed -e 's|redis://||' -e 's|@.*||' -e 's|.*@||' -e 's|/.*||')
    export REDIS_QUEUE
fi

echo "[INFO] Configuration:"
echo "  - Frontend Port: $FRONTEND_PORT"
echo "  - Backend Port: $BACKEND_PORT" 
echo "  - Socket.IO Port: $SOCKETIO_PORT"
echo "  - Database Host: $DB_HOST:$DB_PORT"
echo "  - Redis Cache: $REDIS_CACHE"
echo "  - Redis Queue: $REDIS_QUEUE"
echo "  - Site Name Header: $FRAPPE_SITE_NAME_HEADER"

# Create directory structure using single volume mount
# Railway mounts volume at /home/frappe/frappe-bench/persistent
mkdir -p persistent/sites
mkdir -p persistent/logs

# Create symbolic links to maintain expected paths
if [[ ! -L sites ]]; then
    rm -rf sites 2>/dev/null || true
    ln -sf persistent/sites sites
fi

if [[ ! -L logs ]]; then
    rm -rf logs 2>/dev/null || true
    ln -sf persistent/logs logs
fi

# Wait for database and Redis to be available
if [[ -n "$DB_HOST" ]]; then
    echo "[INFO] Waiting for database at $DB_HOST:$DB_PORT..."
    wait-for-it -t 120 "$DB_HOST:$DB_PORT" || {
        echo "[ERROR] Database not available"
        exit 1
    }
fi

if [[ -n "$REDIS_CACHE" ]]; then
    echo "[INFO] Waiting for Redis cache at $REDIS_CACHE..."
    wait-for-it -t 120 "$REDIS_CACHE" || {
        echo "[ERROR] Redis cache not available"
        exit 1
    }
fi

if [[ -n "$REDIS_QUEUE" ]]; then
    echo "[INFO] Waiting for Redis queue at $REDIS_QUEUE..."
    wait-for-it -t 120 "$REDIS_QUEUE" || {
        echo "[ERROR] Redis queue not available"
        exit 1
    }
fi

# Configure Frappe
echo "[INFO] Configuring Frappe..."
ls -1 apps > sites/apps.txt 2>/dev/null || echo "erpnext" > sites/apps.txt

# Set bench configuration
if [[ -n "$DB_HOST" ]]; then
    bench set-config -g db_host "$DB_HOST"
    bench set-config -gp db_port "$DB_PORT"
fi

if [[ -n "$REDIS_CACHE" ]]; then
    bench set-config -g redis_cache "redis://$REDIS_CACHE"
fi

if [[ -n "$REDIS_QUEUE" ]]; then
    bench set-config -g redis_queue "redis://$REDIS_QUEUE"
    bench set-config -g redis_socketio "redis://$REDIS_QUEUE"
fi

bench set-config -gp socketio_port "$SOCKETIO_PORT"

# Check if site exists, create if not
SITE_NAME=${FRAPPE_SITE_NAME_HEADER:-frontend}
if [[ ! -d "sites/$SITE_NAME" ]]; then
    echo "[INFO] Creating new site: $SITE_NAME"
    
    # Wait for configuration to be written
    sleep 5
    
    # Create the site
    bench new-site \
        --mariadb-user-host-login-scope='%' \
        --admin-password="${BOOTSTRAP_ADMIN_PASSWORD:-admin}" \
        --db-root-username=root \
        --db-root-password="$DB_PASSWORD" \
        --install-app erpnext \
        --set-default \
        "$SITE_NAME"
    
    echo "[INFO] Site created successfully: $SITE_NAME"
else
    echo "[INFO] Site already exists: $SITE_NAME"
fi

# Update nginx port configuration to use Railway's PORT
if [[ -n "$PORT" ]]; then
    # Create custom nginx config for Railway port
    cat > /tmp/railway_nginx.conf << EOF
upstream backend {
    server 127.0.0.1:8000 fail_timeout=0;
}

upstream socketio {
    server 127.0.0.1:9000 fail_timeout=0;
}

server {
    listen $PORT;
    server_name \$host;
    
    root /home/frappe/frappe-bench/sites;
    
    location /assets {
        try_files \$uri =404;
    }
    
    location ~ ^/protected/(.*) {
        internal;
        try_files /\$frappe_site_name/\$1 =404;
    }
    
    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Frappe-Site-Name \$frappe_site_name;
        proxy_set_header Origin \$scheme://\$http_host;
        proxy_set_header Host \$host;
        proxy_pass http://socketio;
    }
    
    location / {
        try_files /\$frappe_site_name/public/\$uri @webserver;
    }
    
    location @webserver {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frappe-Site-Name \$frappe_site_name;
        proxy_set_header Host \$host;
        proxy_set_header X-Use-X-Accel-Redirect True;
        proxy_read_timeout ${PROXY_READ_TIMEOUT:-120};
        proxy_redirect off;
        proxy_pass http://backend;
    }
    
    client_max_body_size ${CLIENT_MAX_BODY_SIZE:-50m};
}

map \$http_host \$frappe_site_name {
    default $FRAPPE_SITE_NAME_HEADER;
}
EOF
    export RAILWAY_NGINX_CONF="/tmp/railway_nginx.conf"
fi

echo "[INFO] Starting all services with supervisord..."

# Start supervisord with all services
if [[ "$1" == "supervisord" ]]; then
    # Start services in sequence using supervisorctl after supervisord starts
    exec supervisord -n -c /etc/supervisor/conf.d/supervisord.conf &
    SUPERVISORD_PID=$!
    
    # Wait for supervisord to start
    sleep 5
    
    # Start services in proper order
    echo "[INFO] Starting backend service..."
    supervisorctl start backend
    sleep 10
    
    echo "[INFO] Starting websocket service..."
    supervisorctl start websocket
    sleep 5
    
    echo "[INFO] Starting frontend service..."
    supervisorctl start frontend
    sleep 5
    
    echo "[INFO] Starting background services..."
    supervisorctl start scheduler
    supervisorctl start queue-short
    supervisorctl start queue-long
    
    echo "[INFO] All services started successfully!"
    
    # Wait for supervisord to finish
    wait $SUPERVISORD_PID
else
    # Execute the provided command
    exec "$@"
fi
