# Use the official Frappe Docker image as a base
FROM frappe/erpnext:v15.18.0

# The base image doesn't have nc, so we need to install it.
# We switch to root to install packages, then back to frappe.
USER root
RUN apt-get update && apt-get install -y \
    netcat-openbsd \
    mariadb-client \
    nginx \
    supervisor \
    gettext-base \
  && rm -rf /var/lib/apt/lists/*

# Copy supervisor and nginx configs
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/nginx.conf /etc/nginx/templates/default.conf.template

# Copy the entrypoint script and give it the necessary permissions
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment and exposed port for Railway
ENV PORT=8080
EXPOSE 8080

# Set the entrypoint to our custom script
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
