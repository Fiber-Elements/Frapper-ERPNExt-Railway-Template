# Use the official Frappe Docker image as a base
FROM frappe/erpnext:v15.18.0

# The base image doesn't have nc, so we need to install it.
# We switch to root to install packages, then back to frappe.
USER root
RUN apt-get update && apt-get install -y netcat-openbsd && rm -rf /var/lib/apt/lists/*

# Copy the entrypoint script and give it the necessary permissions
COPY --chown=frappe:frappe entrypoint.sh /home/frappe/entrypoint.sh
RUN chmod +x /home/frappe/entrypoint.sh

# Switch back to the frappe user
USER frappe

# Set the entrypoint to our custom script
ENTRYPOINT ["/home/frappe/entrypoint.sh"]
