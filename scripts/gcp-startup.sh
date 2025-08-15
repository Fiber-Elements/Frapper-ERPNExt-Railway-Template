#!/usr/bin/env bash
# ERPNext on GCE VM startup script (Managed DB/Redis version)
# - Installs Docker engine + compose plugin
# - Clones frappe_docker, configures it to use managed Cloud SQL and Memorystore
# - Runs configurator & create-site, starts app services
# - Sets Administrator password and prints public URL hint

set -xeuo pipefail

# -------- Config via metadata / env --------
get_md() {
  curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}

ADMIN_PASSWORD="$(get_md ADMIN_PASSWORD)"
HTTP_PORT="$(get_md HTTP_PORT)"
DOMAIN="$(get_md DOMAIN)"
DB_HOST="$(get_md DB_HOST)"
DB_PORT="$(get_md DB_PORT)"
DB_PASSWORD="$(get_md DB_PASSWORD)"
REDIS_CACHE="$(get_md REDIS_CACHE)"
REDIS_QUEUE="$(get_md REDIS_QUEUE)"
REDIS_SOCKETIO="$(get_md REDIS_SOCKETIO)"

REPO_DIR="/opt/frappe_docker"
OVERRIDE_FILE="/opt/frappe_override.yml"

# --- Log and Validate required config ---
echo "[startup-debug] ADMIN_PASSWORD: ${ADMIN_PASSWORD:0:5}..."
echo "[startup-debug] HTTP_PORT: ${HTTP_PORT}"
echo "[startup-debug] DOMAIN: ${DOMAIN}"
echo "[startup-debug] DB_HOST: ${DB_HOST}"
echo "[startup-debug] DB_PORT: ${DB_PORT}"
echo "[startup-debug] DB_PASSWORD: ${DB_PASSWORD:0:5}..."
echo "[startup-debug] REDIS_CACHE: ${REDIS_CACHE}"
echo "[startup-debug] REDIS_QUEUE: ${REDIS_QUEUE}"
echo "[startup-debug] REDIS_SOCKETIO: ${REDIS_SOCKETIO}"

if [[ -z "$DB_HOST" || -z "$DB_PASSWORD" || -z "$REDIS_CACHE" || -z "$REDIS_QUEUE" || -z "$REDIS_SOCKETIO" ]]; then
  echo "[startup][ERROR] Missing required metadata: DB_HOST, DB_PASSWORD, REDIS_CACHE, REDIS_QUEUE, REDIS_SOCKETIO must be set." >&2
  exit 1
fi

# --- Set defaults for optional config ---
[[ -z "$HTTP_PORT" ]] && HTTP_PORT=80
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 20)
fi
if [[ -n "$DOMAIN" ]]; then
  DOMAIN="${DOMAIN%.}" # strip trailing dot if passed as FQDN
  echo "[startup] Domain requested: $DOMAIN"
fi

echo "[startup] Using HTTP port: $HTTP_PORT"
echo "[startup] Admin password will be set automatically."
echo "[startup] Using Cloud SQL host: $DB_HOST"
echo "[startup] Using Memorystore for Redis (Cache): $REDIS_CACHE"

# -------- Install Docker + compose plugin --------
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git
install -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
source /etc/os-release
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable
EOF
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# -------- Fetch frappe_docker sources --------
if [[ ! -d "$REPO_DIR" ]]; then
  git clone https://github.com/frappe/frappe_docker "$REPO_DIR"
else
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only || true
  fi
fi

COMPOSE_FILE="$REPO_DIR/pwd.yml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[startup][ERROR] Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

# -------- Compose override: Use external DB/Redis & publish port --------
# This removes the db, redis-* services and injects connection info into others.
cat > "$OVERRIDE_FILE" <<YAML
services:
  # Remove services that are now managed externally
  db: null
  redis-cache: null
  redis-queue: null
  redis-socketio: null

  # Inject environment variables into all services that need them
  configurator:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
  create-site:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
  backend:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
  frontend:
    ports:
      - "${HTTP_PORT}:8080"
    command: ["bash","-c","wait-for-it -t 180 backend:8000; /usr/local/bin/nginx-entrypoint.sh"]
  scheduler:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
  websocket:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
  queue-short:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
  queue-long:
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT:-3306}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_CACHE=${REDIS_CACHE}
      - REDIS_QUEUE=${REDIS_QUEUE}
      - REDIS_SOCKETIO=${REDIS_SOCKETIO}
YAML

COMPOSE_ARGS=( -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" )

# -------- Pull images (excluding removed services) --------
echo "[startup] Pulling images ..."
if ! docker compose "${COMPOSE_ARGS[@]}" pull; then
  echo "[startup] Pull failed, continuing (images may be pulled during up)"
fi

# -------- Run configurator --------
echo "[startup] Running configurator ..."
docker compose "${COMPOSE_ARGS[@]}" up --no-deps --exit-code-from configurator configurator

# -------- Create site & install ERPNext --------
echo "[startup] Creating site (create-site) ... this can take several minutes on first run"
docker compose "${COMPOSE_ARGS[@]}" up --no-deps --exit-code-from create-site create-site

# -------- Start app services --------
echo "[startup] Starting app services ..."
docker compose "${COMPOSE_ARGS[@]}" up -d backend websocket frontend scheduler queue-short queue-long

echo "[startup] Checking service status ..."
docker compose "${COMPOSE_ARGS[@]}" ps || true

# -------- Wait for HTTP to respond --------
PING_URL="http://localhost:${HTTP_PORT}/api/method/ping"
echo "[startup] Waiting for ERPNext to respond at ${PING_URL} ..."
end=$((SECONDS+1800))
ready=0
while (( SECONDS < end )); do
  if curl -fsS --max-time 5 "$PING_URL" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done
if (( ready == 0 )); then
  echo "[startup][ERROR] Timed out waiting for ERPNext to become ready." >&2
  docker compose "${COMPOSE_ARGS[@]}" logs --since 10m || true
  exit 1
fi

# -------- Configure site host_name if DOMAIN provided --------
if [[ -n "$DOMAIN" ]]; then
  HOST_URL="http://${DOMAIN}"
  echo "[startup] Setting site host_name to ${HOST_URL} ..."
  docker compose "${COMPOSE_ARGS[@]}" exec -T backend bash -lc "bench --site frontend set-config host_name '${HOST_URL}'" || true
fi

# -------- Set Administrator password --------
echo "[startup] Setting Administrator password ..."
docker compose "${COMPOSE_ARGS[@]}" exec -T backend bash -lc "bench --site frontend set-admin-password '${ADMIN_PASSWORD}'" || true

# -------- Summary --------
EXT_IP=$(curl -fs -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || echo "<VM_EXTERNAL_IP>")
URL="http://${EXT_IP}:${HTTP_PORT}"
echo
echo "Deployment complete!"
echo "URL:        ${URL}"
if [[ -n "$DOMAIN" ]]; then
  echo "Domain URL: http://${DOMAIN}"
fi
echo "Username:   Administrator"
echo "Password:   ${ADMIN_PASSWORD}"
echo "Note: Using managed Cloud SQL for MariaDB and Memorystore for Redis."
