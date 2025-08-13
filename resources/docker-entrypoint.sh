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

# Parse REDIS_URL and export individual variables
if [ -n "$REDIS_URL" ]; then
    # Format: redis://:password@host:port/db
    if [[ $REDIS_URL =~ redis://:([^@]+)@([^:]+):([0-9]+)/([0-9]+) ]]; then
        export REDIS_PASSWORD="${BASH_REMATCH[1]}"
        export REDIS_HOST="${BASH_REMATCH[2]}"
        export REDIS_PORT="${BASH_REMATCH[3]}"
        export REDIS_DB="${BASH_REMATCH[4]}"
        export REDIS_CACHE="redis://${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}"
        export REDIS_QUEUE="redis://${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}"
        echo "Redis variables exported from REDIS_URL."
    else
        echo "Failed to parse REDIS_URL."
        exit 1
    fi
fi

# Execute the command passed to the script
exec "$@"
