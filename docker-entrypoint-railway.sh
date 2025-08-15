#!/bin/bash
set -e

# Railway-specific entrypoint for ERPNext
echo "[INFO] Starting ERPNext on Railway..."

# Set dynamic port from Railway
export FRONTEND_PORT=${PORT:-8080}
export BACKEND_PORT=8000
export SOCKETIO_PORT=9000

# Ensure required environment variables
# Use Railway public domain if available, fallback to project name or default
export RAILWAY_PUBLIC_DOMAIN=${RAILWAY_PUBLIC_DOMAIN:-}
if [[ -n "$RAILWAY_PUBLIC_DOMAIN" ]]; then
    # Pass literal $host to Nginx (do not expand in shell)
    export FRAPPE_SITE_NAME_HEADER='\$host'
    export SITE_NAME="$RAILWAY_PUBLIC_DOMAIN"
else
    export FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER:-${RAILWAY_PROJECT_NAME:-frontend}}
    export SITE_NAME=${FRAPPE_SITE_NAME_HEADER}
fi
export BACKEND=${BACKEND:-127.0.0.1:8000}
export SOCKETIO=${SOCKETIO:-127.0.0.1:9000}

# Database configuration - handle both DB_* and MARIADB_* variable names
# Debug MARIADB variables
echo "[DEBUG] MARIADB_HOST value: '${MARIADB_HOST:-not set}'"
echo "[DEBUG] MARIADB_PORT value: '${MARIADB_PORT:-not set}'"
echo "[DEBUG] MARIADB_ROOT_PASSWORD value: '${MARIADB_ROOT_PASSWORD:-not set}'"

export DB_HOST=${DB_HOST:-${MARIADB_HOST:-}}
export DB_PORT=${DB_PORT:-${MARIADB_PORT:-3306}}
export DB_PASSWORD=${DB_PASSWORD:-${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}}

echo "[DEBUG] Final DB_HOST: '$DB_HOST'"
echo "[DEBUG] Final DB_PORT: '$DB_PORT'"

# Redis configuration
export REDIS_CACHE_URL=${REDIS_CACHE_URL:-}
export REDIS_QUEUE_URL=${REDIS_QUEUE_URL:-}
export REDIS_SOCKETIO_URL=${REDIS_SOCKETIO_URL:-$REDIS_CACHE_URL}

# Fallbacks and validation to avoid invalid empty Redis config
if [[ -z "$REDIS_QUEUE_URL" && -n "$REDIS_CACHE_URL" ]]; then
    export REDIS_QUEUE_URL="$REDIS_CACHE_URL"
fi
if [[ -z "$REDIS_CACHE_URL" && -n "$REDIS_QUEUE_URL" ]]; then
    export REDIS_CACHE_URL="$REDIS_QUEUE_URL"
fi
if [[ -z "$REDIS_SOCKETIO_URL" && -n "$REDIS_QUEUE_URL" ]]; then
    export REDIS_SOCKETIO_URL="$REDIS_QUEUE_URL"
fi

# Require at least a queue Redis URL (others will default to it)
if [[ -z "$REDIS_QUEUE_URL" ]]; then
    echo "[ERROR] REDIS_QUEUE_URL is required but not set. Please set REDIS_QUEUE_URL (and optionally REDIS_CACHE_URL, REDIS_SOCKETIO_URL)."
    exit 1
fi

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

# Parse Socket.IO Redis as well
if [[ -n "$REDIS_SOCKETIO_URL" ]]; then
    REDIS_SOCKETIO=$(echo "$REDIS_SOCKETIO_URL" | sed -E 's|redis://([^@]*@)?([^/:]+)(:[0-9]+)?.*|\2\3|')
    if [[ ! "$REDIS_SOCKETIO" =~ :[0-9]+$ ]]; then
        REDIS_SOCKETIO="${REDIS_SOCKETIO}:6379"
    fi
    export REDIS_SOCKETIO
    echo "[DEBUG] Parsed Redis socketio: $REDIS_SOCKETIO from URL: $REDIS_SOCKETIO_URL"
fi

echo "[INFO] Configuration:"
echo "  - Frontend Port: $FRONTEND_PORT"
echo "  - Backend Port: $BACKEND_PORT" 
echo "  - Socket.IO Port: $SOCKETIO_PORT"
echo "  - Database Host: $DB_HOST:$DB_PORT"
echo "  - Redis Cache: $REDIS_CACHE"
echo "  - Redis Queue: $REDIS_QUEUE"
echo "  - Redis SocketIO: $REDIS_SOCKETIO"
echo "  - Site Name Header: $FRAPPE_SITE_NAME_HEADER"

# --- Volume Configuration ---
# Use the predictable volume path defined in the Dockerfile.
VOLUME_PATH="/home/frappe/persistent"

echo "[INFO] Using volume path: $VOLUME_PATH"
echo "[INFO] Volume permissions: $(ls -la "$VOLUME_PATH" 2>/dev/null || echo 'Cannot access volume')"

# Create directory structure in the actual volume
echo "[INFO] Creating directory structure..."
mkdir -p "$VOLUME_PATH/sites" "$VOLUME_PATH/logs"

# Create symbolic links to maintain expected paths
if [[ ! -L sites ]]; then
    rm -rf sites 2>/dev/null || true
    ln -sf "$VOLUME_PATH/sites" sites
fi

if [[ ! -L logs ]]; then
    rm -rf logs 2>/dev/null || true
    ln -sf "$VOLUME_PATH/logs" logs
fi

# Function to extract host:port from a URL
extract_host_port() {
    echo "$1" | sed -e 's;redis://;;' -e 's;/.*$;;'
}

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

# Initialize Frappe sites directory structure
echo "[INFO] Initializing Frappe sites directory..."
ls -1 apps > sites/apps.txt 2>/dev/null || echo "erpnext" > sites/apps.txt

# Create basic common_site_config.json if it doesn't exist
if [[ ! -f "sites/common_site_config.json" ]]; then
    echo "[INFO] Creating initial common_site_config.json..."
    cat > sites/common_site_config.json << EOF
{
 "db_host": "${DB_HOST}",
 "db_port": ${DB_PORT},
 "redis_cache": "${REDIS_CACHE_URL}",
 "redis_queue": "${REDIS_QUEUE_URL}",
 "redis_socketio": "${REDIS_SOCKETIO_URL}",
 "socketio_port": ${SOCKETIO_PORT}
}
EOF
else
    echo "[INFO] Updating existing common_site_config.json..."
    # Update existing configuration
    if [[ -n "$DB_HOST" ]]; then
        bench set-config -g db_host "$DB_HOST"
        bench set-config -gp db_port "$DB_PORT"
    fi

    if [[ -n "$REDIS_CACHE_URL" ]]; then
        bench set-config -g redis_cache "$REDIS_CACHE_URL"
    fi

    if [[ -n "$REDIS_QUEUE_URL" ]]; then
        bench set-config -g redis_queue "$REDIS_QUEUE_URL"
    fi

    if [[ -n "$REDIS_SOCKETIO_URL" ]]; then
        bench set-config -g redis_socketio "$REDIS_SOCKETIO_URL"
    fi

    bench set-config -gp socketio_port "$SOCKETIO_PORT"
fi

echo "[INFO] Frappe configuration completed."

# Check if site exists, create if not
SITE_NAME=${SITE_NAME:-${FRAPPE_SITE_NAME_HEADER:-frontend}}
echo "[INFO] Using site name: $SITE_NAME"
echo "[INFO] Railway public domain: ${RAILWAY_PUBLIC_DOMAIN:-'not set'}"

# Check if site exists or if we should create it
if [[ ! -d "sites/$SITE_NAME" ]]; then
    echo "[INFO] Creating new site: $SITE_NAME"
    
    # Wait for configuration to be written
    sleep 5
    
    # Try to create site, but handle existing database gracefully
    if bench new-site \
        --mariadb-user-host-login-scope='%' \
        --admin-password="${BOOTSTRAP_ADMIN_PASSWORD:-admin}" \
        --db-root-username=root \
        --db-root-password="$DB_PASSWORD" \
        --install-app erpnext \
        --set-default \
        "$SITE_NAME" 2>/dev/null; then
        echo "[INFO] New site created successfully"
    else
        echo "[INFO] Site creation failed (likely database exists), connecting to existing database..."
        # Create site directory structure to connect to existing database
        mkdir -p "sites/$SITE_NAME"
        
        # Create site config to connect to existing database
        # Respect optional DB_NAME/DB_USER env vars; default to sanitized site name and root user
        cat > "sites/$SITE_NAME/site_config.json" << EOF
{
 "db_host": "${DB_HOST}",
 "db_port": ${DB_PORT},
 "db_name": "${DB_NAME:-${MYSQL_DATABASE:-$(echo "$SITE_NAME" | sed 's/\./_/g' | sed 's/-/_/g')}}",
 "db_user": "${DB_USER:-root}",
 "db_password": "${DB_PASSWORD}",
 "encryption_key": "$(openssl rand -base64 32)"
}
EOF
        
        # Set site as default
        bench use "$SITE_NAME" || true
    fi
    
    echo "[INFO] Site setup completed: $SITE_NAME"
else
    echo "[INFO] Site already exists: $SITE_NAME"
    # Ensure site is enabled
    bench use "$SITE_NAME" 2>/dev/null || true
fi

# Enforce DB user if necessary to avoid MySQL username length issues
if [[ -f "sites/$SITE_NAME/site_config.json" ]]; then
    CURRENT_DB_USER=$(jq -r '.db_user // empty' "sites/$SITE_NAME/site_config.json" 2>/dev/null || true)
    NEED_OVERRIDE=false
    if [[ -n "$DB_USER" ]]; then
        NEED_OVERRIDE=true
    elif [[ -z "$CURRENT_DB_USER" ]]; then
        NEED_OVERRIDE=true
    elif [[ ${#CURRENT_DB_USER} -gt 32 ]]; then
        NEED_OVERRIDE=true
    fi
    if [[ "$NEED_OVERRIDE" == "true" ]]; then
        echo "[INFO] Updating site_config.json to use DB user '${DB_USER:-root}' for site $SITE_NAME"
        tmp_cfg=$(mktemp)
        jq \
          --arg db_host "$DB_HOST" \
          --argjson db_port ${DB_PORT:-3306} \
          --arg db_user "${DB_USER:-root}" \
          --arg db_password "$DB_PASSWORD" \
          '.db_host=$db_host | .db_port=$db_port | .db_user=$db_user | .db_password=$db_password' \
          "sites/$SITE_NAME/site_config.json" > "$tmp_cfg" && mv "$tmp_cfg" "sites/$SITE_NAME/site_config.json"
    fi
fi

# Apply migrations and clear cache to ensure workers/websocket have latest schema and config
echo "[INFO] Running bench migrate and clear-cache for site: $SITE_NAME"
bench --site "$SITE_NAME" migrate || true
bench --site "$SITE_NAME" clear-cache || true

# If using Railway public domain, create additional site for the domain
if [[ -n "$RAILWAY_PUBLIC_DOMAIN" && "$RAILWAY_PUBLIC_DOMAIN" != "$SITE_NAME" ]]; then
    echo "[INFO] Creating additional site for Railway domain: $RAILWAY_PUBLIC_DOMAIN"
    if [[ ! -d "sites/$RAILWAY_PUBLIC_DOMAIN" ]]; then
        bench new-site \
            --mariadb-user-host-login-scope='%' \
            --admin-password="${BOOTSTRAP_ADMIN_PASSWORD:-admin}" \
            --db-root-username=root \
            --db-root-password="$DB_PASSWORD" \
            --install-app erpnext \
            "$RAILWAY_PUBLIC_DOMAIN"
        echo "[INFO] Railway domain site created: $RAILWAY_PUBLIC_DOMAIN"
    fi
fi

# Configure environment for Railway HTTP exposure
echo "[INFO] Railway will provide public URL automatically at: https://your-app-name.up.railway.app"

echo "[INFO] Starting all services with supervisord..."

# Start supervisord with all services
if [[ "$1" == "supervisord" ]]; then
    echo "[INFO] Starting supervisord..."
    # Start supervisord in foreground mode
    exec supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
else
    # Execute the provided command
    exec "$@"
fi
