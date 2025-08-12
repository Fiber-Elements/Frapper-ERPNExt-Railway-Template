# Use the official Frappe Docker image as a base
FROM frappe/erpnext:v15.18.0

# Set the user to root to have the necessary permissions to copy the entrypoint script
USER root

# Copy the entrypoint script and give it the necessary permissions
COPY --chown=frappe:frappe entrypoint.sh /home/frappe/entrypoint.sh
RUN chmod +x /home/frappe/entrypoint.sh

# Set the user back to frappe
USER frappe

# Set the entrypoint to our custom script
ENTRYPOINT ["/home/frappe/entrypoint.sh"]
