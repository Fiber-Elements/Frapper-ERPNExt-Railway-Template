# Use the same base image as the official frappe_docker
ARG F_V=15
ARG P_V=15
FROM frappe/erpnext:v${F_V}.${P_V}

# Copy the custom entrypoint script into the image
COPY --chown=frappe:frappe scripts/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Set the entrypoint to our custom script
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
