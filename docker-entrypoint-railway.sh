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

# Database configuration - handle both DB_* and MARIADB_* variable names
export DB_HOST=${DB_HOST:-${MARIADB_HOST:-}}
export DB_PORT=${DB_PORT:-${MARIADB_PORT:-3306}}
export DB_PASSWORD=${DB_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}

# Redis configuration
export REDIS_CACHE_URL=${REDIS_CACHE_URL:-}
export REDIS_QUEUE_URL=${REDIS_QUEUE_URL:-}
export REDIS_SOCKETIO_URL=${REDIS_SOCKETIO_URL:-$REDIS_CACHE_URL}

# Parse Redis URLs to get host:port format for Frappe config
if [[ -n "$REDIS_CACHE_URL" ]]; then
    # Handle both redis://host:port and redis://user:pass@host:port formats
    REDIS_CACHE=$(echo "$REDIS_CACHE_URL" | sed -E 's|redis://([^@]*@)?([^/:]+)(:[0-9]+)?.*|\2\3|')
    # If no port specified, add default Redis port
    if [[ ! "$REDIS_CACHE" =~ :[0-9]+$ ]]; then
        REDIS_CACHE="${REDIS_CACHE}:6379"
    fi
    export REDIS_CACHE
    echo "[DEBUG] Parsed Redis cache: $REDIS_CACHE from URL: $REDIS_CACHE_URL"
fi

if [[ -n "$REDIS_QUEUE_URL" ]]; then
    # Handle both redis://host:port and redis://user:pass@host:port formats
    REDIS_QUEUE=$(echo "$REDIS_QUEUE_URL" | sed -E 's|redis://([^@]*@)?([^/:]+)(:[0-9]+)?.*|\2\3|')
    # If no port specified, add default Redis port
    if [[ ! "$REDIS_QUEUE" =~ :[0-9]+$ ]]; then
        REDIS_QUEUE="${REDIS_QUEUE}:6379"
    fi
    export REDIS_QUEUE
    echo "[DEBUG] Parsed Redis queue: $REDIS_QUEUE from URL: $REDIS_QUEUE_URL"
fi

echo "[INFO] Configuration:"
echo "  - Frontend Port: $FRONTEND_PORT"
echo "  - Backend Port: $BACKEND_PORT" 
echo "  - Socket.IO Port: $SOCKETIO_PORT"
echo "  - Database Host: $DB_HOST:$DB_PORT"
echo "  - Redis Cache: $REDIS_CACHE"
echo "  - Redis Queue: $REDIS_QUEUE"
echo "  - Site Name Header: $FRAPPE_SITE_NAME_HEADER"

# Railway volume handling - use the mounted volume path directly
# Railway mounts volume at a dynamic path, use environment or detect
VOLUME_PATH="/home/frappe/frappe-bench/persistent"

# If the expected path doesn't exist, find the actual Railway volume mount
if [[ ! -d "$VOLUME_PATH" ]]; then
    # Look for Railway volume mount patterns
    for possible_path in /var/lib/containers/railwayapp/bind-mounts/*/vol_*; do
        if [[ -d "$possible_path" && -w "$possible_path" ]]; then
            VOLUME_PATH="$possible_path"
            echo "[INFO] Found Railway volume at: $VOLUME_PATH"
            break
        fi
    done
fi

# Ensure we have write permissions and create directory structure
echo "[INFO] Using volume path: $VOLUME_PATH"
echo "[INFO] Volume permissions: $(ls -la "$(dirname "$VOLUME_PATH")" 2>/dev/null || echo 'Cannot access parent dir')"

# Create directory structure in the volume with proper error handling
if mkdir -p "$VOLUME_PATH/sites" "$VOLUME_PATH/logs" 2>/dev/null; then
    echo "[INFO] Successfully created directories in volume"
else
    echo "[ERROR] Failed to create directories in volume. Trying alternative approach..."
    # Fallback: create in /tmp and link if volume creation fails
    mkdir -p /tmp/frappe_sites /tmp/frappe_logs
    VOLUME_PATH="/tmp"
    echo "[WARNING] Using temporary storage - data will not persist across deployments"
fi

# Create symbolic links to maintain expected paths
if [[ ! -L sites ]]; then
    rm -rf sites 2>/dev/null || true
    ln -sf "$VOLUME_PATH/sites" sites
fi

if [[ ! -L logs ]]; then
    rm -rf logs 2>/dev/null || true
    ln -sf "$VOLUME_PATH/logs" logs
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

# Configure environment for Railway HTTP exposure
echo "[INFO] Railway will provide public URL automatically at: https://your-app-name.up.railway.app"

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
