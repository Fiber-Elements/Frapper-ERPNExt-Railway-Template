# Multi-stage ERPNext Dockerfile for Railway deployment
FROM frappe/erpnext:v15.75.1

# Install additional utilities for Railway deployment
USER root
RUN apt-get update && apt-get install -y \
    supervisor \
    wait-for-it \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create supervisord configuration directory
RUN mkdir -p /etc/supervisor/conf.d

# Copy supervisord configuration for multi-service setup
COPY --chown=frappe:frappe supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy entrypoint script
COPY --chown=frappe:frappe docker-entrypoint-railway.sh /home/frappe/docker-entrypoint-railway.sh
RUN chmod +x /home/frappe/docker-entrypoint-railway.sh

# Create single persistent data directory for Railway's single volume limitation
# Create a single, predictable mount point for the volume.
# The user will mount their Railway volume to this path.
RUN mkdir -p /home/frappe/persistent && \
    chown -R frappe:frappe /home/frappe/persistent
VOLUME /home/frappe/persistent

# Create frappe user and set home directory
RUN useradd -ms /bin/bash frappe

ENV HOME /home/frappe
WORKDIR $HOME

# Switch back to frappe user
USER frappe
WORKDIR /home/frappe/frappe-bench

# Expose port for Railway
EXPOSE $PORT

# Set default environment variables
ENV FRAPPE_SITE_NAME_HEADER=frontend
ENV SOCKETIO_PORT=9000
ENV BACKEND_PORT=8000
ENV FRONTEND_PORT=8080

# Use custom entrypoint for Railway
ENTRYPOINT ["/home/frappe/docker-entrypoint-railway.sh"]
CMD ["supervisord"]
