# Use the official pre-built image that includes Frappe and ERPNext.
# This image is used in the official docker-compose setup (pwd.yml).
ARG FRAPPE_VERSION=v15.75.1
FROM frappe/erpnext:${FRAPPE_VERSION}

# Copy the Railway entrypoint script and make it executable.
# This script is used by the preDeployCommand in railway.toml.
COPY --chown=frappe:frappe scripts/railway-entrypoint.sh /home/frappe/frappe-bench/scripts/railway-entrypoint.sh
RUN chmod +x /home/frappe/frappe-bench/scripts/railway-entrypoint.sh

# The base image already contains ERPNext. If you need to add custom apps
# from an apps.json file, you would need to switch back to a multi-stage build.

# Set our script as the new entrypoint.
# It will configure the environment and then execute the base image's CMD.
ENTRYPOINT ["/home/frappe/frappe-bench/scripts/railway-entrypoint.sh"]
