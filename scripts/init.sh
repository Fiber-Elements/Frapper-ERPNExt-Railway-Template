#!/bin/bash
# This script ensures that site creation and app installation
# only run once, making the deployment process idempotent.
# The SITES variable is expected to be set in the environment.

# Check if the site's configuration file already exists on the persistent volume.
if [ ! -f "/home/frappe/frappe-bench/sites/${SITES}/site_config.json" ]; then
    echo "Site not found. Running initial setup..."

    # Create the new site non-interactively.
    bench new-site ${SITES} \
        --no-mariadb-socket \
        --admin-password ${ADMIN_PASSWORD} \
        --db-name ${MYSQL_DATABASE} \
        --db-host ${MYSQL_HOST} \
        --db-port ${MYSQL_PORT} \
        --db-password ${MYSQL_ROOT_PASSWORD}

    # Install the erpnext app onto the newly created site.
    bench --site ${SITES} install-app erpnext

    echo "Initial setup complete."
else
    echo "Site already exists. Skipping setup."
fi

# Always run migrations to ensure the database is up-to-date.
bench --site ${SITES} migrate
