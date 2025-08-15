# Dockerfile for Frappe/ERPNext on Railway

# --- Builder Stage ---
# This stage installs the applications specified in apps.json
ARG FRAPPE_VERSION=v15.28.0
FROM frappe/frappe-worker:${FRAPPE_VERSION} as builder

# 1. Install git, which is required to fetch apps
USER root
RUN apt-get update && \
    apt-get install -y git && \
    rm -rf /var/lib/apt/lists/*
USER frappe

# 2. Copy apps.json and install apps
WORKDIR /home/frappe/frappe-bench
COPY --chown=frappe:frappe apps.json .
RUN bench get-app erpnext https://github.com/frappe/erpnext --branch version-15 && \
    bench build --app erpnext

# --- Final Stage ---
# This stage creates the final, lean image
FROM frappe/frappe-worker:${FRAPPE_VERSION}

# Copy the installed apps from the builder stage
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/sites /home/frappe/frappe-bench/sites
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/apps/erpnext /home/frappe/frappe-bench/apps/erpnext
