#!/bin/bash
set -e

# Parse DATABASE_URL and export individual variables
if [ -n "$DATABASE_URL" ]; then
    # Use regex to extract components from the DATABASE_URL
    # Format: postgres://user:password@host:port/dbname
    if [[ $DATABASE_URL =~ postgres://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+) ]]; then
        export DB_USER="${BASH_REMATCH[1]}"
        export DB_PASSWORD="${BASH_REMATCH[2]}"
        export DB_HOST="${BASH_REMATCH[3]}"
        export DB_PORT="${BASH_REMATCH[4]}"
        export DB_NAME="${BASH_REMATCH[5]}"
        echo "Database variables exported from DATABASE_URL."
    else
        echo "Failed to parse DATABASE_URL."
        exit 1
    fi
fi

# Set Redis connection variables for Frappe from secrets
if [ -n "$REDIS_CACHE_URL" ]; then
    export REDIS_CACHE="$REDIS_CACHE_URL"
    echo "Redis cache configured from REDIS_CACHE_URL secret."
fi

if [ -n "$REDIS_QUEUE_URL" ]; then
    export REDIS_QUEUE="$REDIS_QUEUE_URL"
    echo "Redis queue configured from REDIS_QUEUE_URL secret."
    # Use the same Redis for socketio unless a specific one is provided
    if [ -z "$REDIS_SOCKETIO" ]; then
        export REDIS_SOCKETIO="$REDIS_QUEUE_URL"
        echo "Redis socketio configured from REDIS_QUEUE_URL secret."
    fi
fi

# Generic envs some clients expect
if [ -n "$REDIS_SOCKETIO" ]; then
    export SOCKETIO_REDIS_URL="$REDIS_SOCKETIO"
    export SOCKETIO_REDIS="$REDIS_SOCKETIO"
fi
if [ -n "$REDIS_QUEUE" ]; then
    export REDIS_URL="$REDIS_QUEUE"
fi

# Persist Redis URLs into common_site_config.json so Node socketio reads correct hosts
python3 - <<'PY'
import os, json, re
cfg_path = "/home/frappe/frappe-bench/sites/common_site_config.json"
cfg = {}
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}

changed = False

def norm_db0(url: str | None) -> str | None:
    if not url:
        return url
    # Keep scheme+authority, drop existing /<db>, force /0
    m = re.match(r"^(redis(?:s)?://[^/]+)(?:/\d+)?$", url)
    if m:
        return m.group(1) + "/0"
    return url

def set_if_env(key, env):
    global changed
    val = norm_db0(os.environ.get(env))
    if val and cfg.get(key) != val:
        cfg[key] = val
        changed = True

set_if_env("redis_cache", "REDIS_CACHE")
set_if_env("redis_queue", "REDIS_QUEUE")

# prefer explicit REDIS_SOCKETIO, else fall back to queue
socketio = norm_db0(os.environ.get("REDIS_SOCKETIO") or os.environ.get("REDIS_QUEUE"))
if socketio:
    # set multiple keys for compatibility across versions
    for k in ("redis_socketio", "redis_socketio_url", "socketio_redis_url"):
        if cfg.get(k) != socketio:
            cfg[k] = socketio
            changed = True

# Also export host/port pairs if URL present for older clients
url = socketio or norm_db0(os.environ.get("REDIS_QUEUE") or os.environ.get("REDIS_CACHE"))
if url:
    m = re.match(r"redis:\/\/(?:[^@]+@)?([^:\/]+)(?::(\d+))?", url)
    if m:
        host, port = m.group(1), m.group(2) or "6379"
        if cfg.get("redis_socketio_host") != host:
            cfg["redis_socketio_host"] = host
            changed = True
        if cfg.get("redis_socketio_port") != port:
            cfg["redis_socketio_port"] = port
            changed = True

if changed:
    with open(cfg_path, "w") as f:
        json.dump(cfg, f)
    print("Updated common_site_config.json with Redis URLs.")
else:
    print("common_site_config.json Redis URLs already up-to-date.")
PY

# Ensure apps.txt exists on the mounted sites volume, copy a default if missing
SITES_DIR="/home/frappe/frappe-bench/sites"
if [ ! -f "$SITES_DIR/apps.txt" ]; then
    if [ -f "/home/frappe/frappe-bench/apps.txt" ]; then
        cp "/home/frappe/frappe-bench/apps.txt" "$SITES_DIR/apps.txt"
        echo "Copied default apps.txt into sites volume."
    else
        echo "Warning: apps.txt not found in image; Frappe may fail to start."
    fi
fi

# Switch to the sites directory so Frappe resolves relative paths correctly
cd "$SITES_DIR"

# Execute the command passed to the script
exec "$@"
