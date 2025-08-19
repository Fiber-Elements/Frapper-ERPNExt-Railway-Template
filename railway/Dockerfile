# Option A: Single-service image running all ERPNext processes via supervisord
# Base on official ERPNext image
ARG VERSION=version-15
FROM docker.io/frappe/erpnext:${VERSION}

USER root

# Install supervisor and essential runtime deps (nginx, node) and create dirs
RUN apt-get update \
    && apt-get install -y --no-install-recommends supervisor ca-certificates curl nginx nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/supervisor /etc/supervisor/conf.d

# Ensure gunicorn available (some images may not ship with the CLI on PATH)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir gunicorn

# Copy supervisor config and helper scripts
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/ /opt/frappe-scripts/
RUN chmod +x /opt/frappe-scripts/*.sh

# Expose nginx port
EXPOSE 8080

# Healthcheck: ERPNext ping via nginx
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -fsS http://127.0.0.1:8080/api/method/ping || exit 1

# Default environment that can be overridden by Railway variables
# In a single-container setup, backend and websocket live on localhost
ENV BACKEND=127.0.0.1:8000 \
    SOCKETIO=127.0.0.1:9000 \
    UPSTREAM_REAL_IP_ADDRESS=127.0.0.1 \
    UPSTREAM_REAL_IP_HEADER=X-Forwarded-For \
    UPSTREAM_REAL_IP_RECURSIVE=off \
    PROXY_READ_TIMEOUT=120 \
    CLIENT_MAX_BODY_SIZE=50m

# Ensure sbin paths are available for non-root user processes (nginx lives in /usr/sbin)
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Ensure sites dir exists (mounted volume should bind here at runtime)
RUN mkdir -p /home/frappe/frappe-bench/sites \
 && chown -R frappe:frappe /home/frappe/frappe-bench

# Runtime entrypoint will fix volume ownership and generate apps.txt, then start supervisord
ENTRYPOINT ["/opt/frappe-scripts/entrypoint.sh"]
