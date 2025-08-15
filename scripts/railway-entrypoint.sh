#!/bin/sh
# railway-entrypoint.sh

# This script is executed by the preDeployCommand in railway.toml.
# It parses the DATABASE_URL and REDIS_URL provided by Railway into the individual
# environment variables that the official Frappe Docker image expects.

set -e

if [ -n "$DATABASE_URL" ]; then
    # Parse DATABASE_URL
    DB_DETAILS=$(echo $DATABASE_URL | sed -e 's/mysql:\/\///g')
    DB_USER=$(echo $DB_DETAILS | cut -d':' -f1)
    DB_PASSWORD=$(echo $DB_DETAILS | cut -d':' -f2 | cut -d'@' -f1)
    DB_HOST=$(echo $DB_DETAILS | cut -d'@' -f2 | cut -d':' -f1)
    DB_PORT=$(echo $DB_DETAILS | cut -d':' -f3 | cut -d'/' -f1)

    # Export variables for Frappe
    export DB_HOST
    export DB_PORT
    export DB_USER
    export DB_PASSWORD

    echo "Database variables exported."
fi

if [ -n "$REDIS_URL" ]; then
    # Parse REDIS_URL
    REDIS_DETAILS=$(echo $REDIS_URL | sed -e 's/redis:\/\///g')

    # Export variables for Frappe
    export REDIS_CACHE="redis://$REDIS_DETAILS"
    export REDIS_QUEUE="redis://$REDIS_DETAILS"

    echo "Redis variables exported."
fi

# The original entrypoint of the Frappe image will be executed after this script.
