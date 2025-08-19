# ERPNext on Railway Template

This repository provides a minimal template to run ERPNext locally via Docker (using the official `frappe_docker` single-compose setup) and guidance to deploy it on Railway with MariaDB and Redis provisioned as Railway services.

Key files:
- `deploys/run-local.ps1`: Windows PowerShell script that automates a local ERPNext bring-up using `frappe_docker/pwd.yml`.
- `.env.template`: Example environment variables for overriding defaults.
- `.gitignore`: Ignores local and generated files, including the cloned `frappe_docker/` sources.

References:
- Frappe single-compose docs: https://github.com/frappe/frappe_docker/blob/main/docs/single-compose-setup.md
- ERPNext repo: https://github.com/frappe/erpnext

---

## Local Development (Windows + Docker Desktop)

Prerequisites:
- Docker Desktop installed and running.
- PowerShell 5.1+.
- Git (optional but recommended; the script will clone `frappe_docker`).

Quick start:
1) Open PowerShell in the repo root.
2) Run the script (it will clone/update `frappe_docker`, pull images, configure, create a default site, and start services):

```powershell
# Optional: specify port and admin password. If omitted, a strong safe password will be generated.
# Default HTTP port: 8080

./deploys/run-local.ps1 -Port 8080 -AdminPassword "Your_Admin_Pass_123"
```

What the script does:
- Clones or updates `frappe_docker` into `./frappe_docker/`.
- Uses `frappe_docker/pwd.yml` with a temporary override to ensure startup order and port mapping.
- Starts core deps: `db` (MariaDB 10.6), `redis-cache`, `redis-queue`.
- Runs one-off jobs:
  - `configurator` to populate `sites/common_site_config.json` with DB/Redis hosts.
  - `create-site` to create default site `frontend` and install ERPNext.
- Starts app services: `backend`, `websocket`, `frontend`, `scheduler`, `queue-short`, `queue-long`.
- Waits for `/api/method/ping` to respond and sets the Administrator password on site `frontend`.

Result:
- URL: `http://localhost:<Port>`
- Username: `Administrator`
- Password: as displayed on completion (or the value passed to `-AdminPassword`).

Optional local overrides:
- Copy `.env.template` to `.env` and populate variables if you want to override DB/Redis hosts, proxy timeouts, etc. This is not required for the default local flow.

Cleanup:
- To stop services:
  - Open the same PowerShell and run:
    ```powershell
    docker compose -f ./frappe_docker/pwd.yml down
    ```
- To reset data (DESTRUCTIVE): remove the Docker volumes created by the compose file.

---

## Service Topology (Reference)

The standard single-compose topology from `pwd.yml` includes:
- App containers:
  - `backend`: Gunicorn backend (Frappe/ERPNext).
  - `frontend`: Nginx serving static assets and reverse proxying `backend` and `websocket`.
  - `websocket`: Socket.IO for realtime.
  - `scheduler`: Background scheduler.
  - `queue-short`: Worker for `short` and `default` queues.
  - `queue-long`: Worker for `long` queue.
- One-off jobs:
  - `configurator`: Writes DB/Redis settings to `sites/common_site_config.json`.
  - `create-site`: Creates the default site and installs ERPNext.
- Dependencies:
  - `db`: MariaDB 10.6 with Frappe defaults.
  - `redis-cache`: Redis for cache.
  - `redis-queue`: Redis for RQ queues and pub/sub.
- Shared data:
  - `sites` volume (must be available to all app containers).

Use this topology as the basis for any deployment target (including Railway).

---

## Deploying on Railway

Goal: Run app containers on Railway and provision MariaDB and Redis as Railway services. Ensure all app containers share the same `sites` data and have consistent config.

Important considerations:
- All app containers need the same bench data at `/home/frappe/frappe-bench/sites`.
- You must run the configuration and site-creation steps once before starting the runtime services.
- Your public HTTP endpoint should be served by the `frontend` (nginx) container on port 8080.

### 1) Provision base services on Railway

Create the following Railway services:

- Database (MariaDB 10.6). If Railway does not offer a managed MariaDB, create a service from the Docker image `mariadb:10.6` with a persistent volume and set:
  - `MYSQL_ROOT_PASSWORD` (and/or `MARIADB_ROOT_PASSWORD`) to a strong secret.
  - Expose port `3306` internally.

- Redis (for queues). Use Railway Redis or a Docker image `redis:6.2-alpine` with a persistent volume. Expose port `6379` internally.

- Redis (for cache). You can either:
  - Use a second Redis service for cache, or
  - Use one Redis and separate DB indices; the official setup uses separate containers. For parity with `pwd.yml`, create a second Redis service for cache.

Record connection info:
- `DB_HOST`, `DB_PORT` (3306), and the root password you set.
- `REDIS_QUEUE` host:port.
- `REDIS_CACHE` host:port.

### 2) Create application services on Railway

For each app container create a Railway service using the official image:
- Image: `docker.io/frappe/erpnext:version-15` (or set via env `IMAGE_NAME` + `VERSION`).
- Attach the same persistent volume at mount path `/home/frappe/frappe-bench/sites` to all app services. If your platform cannot share a single volume across services, consider running a single service with a process manager that starts multiple processes; otherwise data will diverge.

Define the following app services and start commands:
- `frontend` (public):
  - Start command: `nginx-entrypoint.sh`
  - Expose HTTP port: `8080` (Railway will proxy this as the public URL)
- `backend`:
  - Default image entrypoint (Gunicorn backend). No command override needed.
- `websocket`:
  - Start command: `node /home/frappe/frappe-bench/apps/frappe/socketio.js`
- `scheduler`:
  - Start command: `bench schedule`
- `queue-short`:
  - Start command: `bench worker --queue short,default`
- `queue-long`:
  - Start command: `bench worker --queue long`

Environment variables for all app services:
- Database/Redis wiring (point to Railway services):
  - `DB_HOST=<your-mariadb-host>`
  - `DB_PORT=3306`
  - `REDIS_CACHE=<your-redis-cache-host>:6379`
  - `REDIS_QUEUE=<your-redis-queue-host>:6379`
- Optional: site routing
  - `FRAPPE_SITE_NAME_HEADER=<your-default-site>`
  - Alternatively leave it unset to default to `$$host` (then the site name must match the incoming Host header).

Expose port only on `frontend` and set any proxy-related variables as needed (see `.env.template`).

### 3) One-time configuration and site creation on Railway

Before starting the runtime app services the first time, run the following as one-off tasks (temporary services using the same image and volume):

- Configurator (writes `common_site_config.json`):

```bash
# Entry command for a temporary service (same image and volume mounted at /home/frappe/frappe-bench/sites)
# Requires DB_HOST/PORT, REDIS_CACHE, REDIS_QUEUE in env
bash -lc '
  bench set-config -g db_host "$DB_HOST";
  bench set-config -gp db_port "$DB_PORT";
  bench set-config -g redis_cache "redis://$REDIS_CACHE";
  bench set-config -g redis_queue "redis://$REDIS_QUEUE";
  bench set-config -g redis_socketio "redis://$REDIS_QUEUE";
  bench set-config -gp socketio_port 9000;
'
```

- Create site (choose your site name; for simplicity set `FRAPPE_SITE_NAME_HEADER` to the same value):

Required env for this job:
- `SITE_NAME=<your-site-name>` (e.g., `myerp`) or set it to your Railway domain if using `$$host` behavior.
- `ADMIN_PASSWORD=<strong-admin-password>` (ERPNext Administrator password).
- `DB_HOST`, `DB_PORT`, and DB root credentials for your MariaDB service:
  - `DB_ROOT_PASSWORD=<your-mariadb-root-password>`

Command:
```bash
bash -lc '
  wait-for-it -t 120 "$DB_HOST:$DB_PORT";
  bench new-site --mariadb-user-host-login-scope="%%" \
    --admin-password="$ADMIN_PASSWORD" \
    --db-root-username=root \
    --db-root-password="$DB_ROOT_PASSWORD" \
    "$SITE_NAME";
  # Install ERPNext
  bench --site "$SITE_NAME" install-app erpnext;
'
```

- (Optional) Set or reset Administrator password later:
```bash
bash -lc 'bench --site "$SITE_NAME" set-admin-password "$ADMIN_PASSWORD"'
```

After these jobs succeed, start the app services listed in step 2.

### 4) First access

- Point your browser to the Railway public URL of the `frontend` service.
- If you set `FRAPPE_SITE_NAME_HEADER` to your site name, nginx will always serve that site regardless of Host header.
- If you rely on `$$host`, ensure your site name in `bench new-site` matches the actual Railway domain.

### 5) Upgrades and migrations

For app upgrades or app table migrations, run a one-off migration job that mirrors the compose `migration` job:

```bash
bash -lc '
  bench --site all set-config -p maintenance_mode 1;
  bench --site all set-config -p pause_scheduler 1;
  bench --site all migrate;
  bench --site all set-config -p maintenance_mode 0;
  bench --site all set-config -p pause_scheduler 0;
'
```

---

## Environment Variables Reference

See `.env.template` for optional overrides. Common variables you will use on Railway:
- `DB_HOST`, `DB_PORT`
- `REDIS_CACHE`, `REDIS_QUEUE`
- `FRAPPE_SITE_NAME_HEADER`
- `ADMIN_PASSWORD` (for one-off create site)
- `DB_ROOT_PASSWORD` (for one-off create site)
- `SITE_NAME`

Optional nginx tuning:
- `PROXY_READ_TIMEOUT`, `CLIENT_MAX_BODY_SIZE`
- `UPSTREAM_REAL_IP_ADDRESS`, `UPSTREAM_REAL_IP_HEADER`, `UPSTREAM_REAL_IP_RECURSIVE`

---

## Troubleshooting

- Health/Readiness:
  - Ensure DB and both Redis services are reachable from app services.
  - The `sites` directory must be shared and persistent across all app containers.
- Wrong site served or 404:
  - Check `FRAPPE_SITE_NAME_HEADER` and that the default site exists in `sites/`.
- Access denied creating site:
  - Verify MariaDB root credentials and that the user can create databases.
- SocketIO or background jobs not running:
  - Confirm `websocket`, `scheduler`, and `queue-*` services are up and logs are clean.

---

## Notes

- This template intentionally does not commit `frappe_docker/` sources; the local script will clone them at runtime.
- The official single-compose (`pwd.yml`) is the canonical reference for service layout. Adapt it faithfully when mapping to Railway or other platforms.
