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
fi

# Execute the command passed to the script
exec "$@"
