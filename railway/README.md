# ERPNext on Railway — Option A (Single Service with Supervisor)

This folder contains a single Docker image and supervisor config to run all ERPNext processes in one Railway service. This avoids cross-service shared volume issues.

Components run inside one container:
- backend (Gunicorn)
- websocket (Socket.IO)
- scheduler
- workers: short, long
- frontend (nginx)

Shared data path (persistent disk):
- `/home/frappe/frappe-bench/sites`

Image: built from `docker.io/frappe/erpnext:<VERSION>` with `supervisord`.

---

## 1) Prepare Railway managed services

Create on Railway:
- MariaDB 10.6 (or a managed MariaDB). Note `host`, `port=3306`, and `root password`.
- Redis (queue) for RQ and socket.io pub/sub.
- Redis (cache) for cache.

Record connection info:
- `DB_HOST`, `DB_PORT=3306`
- `REDIS_QUEUE=<host>:6379`
- `REDIS_CACHE=<host>:6379`

## 2) Create ERPNext service from this repo

- New Service → Deploy from GitHub repo.
- Build using Dockerfile: `railway/Dockerfile`.
- Attach a persistent volume mounted at: `/home/frappe/frappe-bench/sites`.
- Expose port 8080 (Railway will proxy it as the public URL).

Set environment variables on the service (see also `railway/.env.template` for a ready-to-copy list):
- `DB_HOST`, `DB_PORT=3306`
- `REDIS_QUEUE`, `REDIS_CACHE`
- Optional: `FRAPPE_SITE_NAME_HEADER=<your-site-name>`

Note: The container has a healthcheck for `GET /api/method/ping` via nginx on port 8080.

### Variables to set (copy/paste checklist)

Required on the ERPNext service (persistent):
- `DB_HOST` → host of your Railway MariaDB service
- `DB_PORT=3306`
- `REDIS_QUEUE` → `<redis-queue-host>:6379` or `:<password>@<host>:6379` if Redis auth is enabled
- `REDIS_CACHE` → `<redis-cache-host>:6379` or `:<password>@<host>:6379` if Redis auth is enabled

To reach the site on the generated Railway URL, choose ONE of:
- Set `FRAPPE_SITE_NAME_HEADER` to your public domain value (copy from Railway UI → `RAILWAY_PUBLIC_DOMAIN`). Recommended.
  - Example: `FRAPPE_SITE_NAME_HEADER=my-service.up.railway.app`
- OR leave `FRAPPE_SITE_NAME_HEADER` unset and ensure you create the site with the exact domain as its name in the create-site step (e.g., `SITE_NAME=my-service.up.railway.app`).

One-off variables (only when running `create-site.sh`):
- `SITE_NAME` → your site name. If not using `FRAPPE_SITE_NAME_HEADER`, set this to the public domain.
- `ADMIN_PASSWORD` → Administrator password to set.
- `DB_ROOT_PASSWORD` → MariaDB root password from your DB service.

Optional (nginx tuning):
- `PROXY_READ_TIMEOUT` (default 120)
- `CLIENT_MAX_BODY_SIZE` (default 50m)
- `UPSTREAM_REAL_IP_ADDRESS`, `UPSTREAM_REAL_IP_HEADER`, `UPSTREAM_REAL_IP_RECURSIVE`

Tip: In Railway, use Variable References so values stay in sync:
- `DB_HOST` = reference to MariaDB service `RAILWAY_PRIVATE_DOMAIN`
- `DB_ROOT_PASSWORD` = reference to MariaDB root password (e.g., `MARIADB_ROOT_PASSWORD`)
- `REDIS_*` hosts = reference to Redis service `RAILWAY_PRIVATE_DOMAIN` (and `REDIS_PASSWORD` if auth enabled)
- `FRAPPE_SITE_NAME_HEADER` = reference this service's `RAILWAY_PUBLIC_DOMAIN`

## 3) One-time configuration jobs

Run these as one-off deploys (Command Override) using the same image and mounted volume.

1) Configurator — writes `sites/common_site_config.json`:

Command override:
```
/opt/frappe-scripts/configurator.sh
```
Required env present on the service:
- `DB_HOST`, `DB_PORT`, `REDIS_CACHE`, `REDIS_QUEUE`

2) Create site — creates the site and installs ERPNext:

Add the following env temporarily for this run:
- `SITE_NAME` (e.g., `myerp`)
- `ADMIN_PASSWORD` (new ERPNext Administrator password)
- `DB_ROOT_PASSWORD` (MariaDB root password)

Command override:
```
/opt/frappe-scripts/create-site.sh
```

After success, remove the command override so the service uses the default (supervisord) and keep the env vars set for runtime (you can remove `ADMIN_PASSWORD` and `DB_ROOT_PASSWORD` after creation if desired).

## 4) Runtime

Default command (no override):
- `/usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf`

Supervisor programs:
- `backend` → Gunicorn
- `websocket` → Node Socket.IO server
- `scheduler` → `bench schedule`
- `worker-short` → `bench worker --queue short,default`
- `worker-long` → `bench worker --queue long,default,short`
- `nginx` → `nginx-entrypoint.sh` (uses BACKEND=127.0.0.1:8000 and SOCKETIO=127.0.0.1:9000)

Access ERPNext at the Railway public URL (port 8080).
- Username: `Administrator`
- Password: the one you set during site creation.

## 5) Upgrades and migrations

Run a one-off migration job when updating apps or versions:

Command override:
```
/opt/frappe-scripts/migration.sh
```

## 6) Environment reference

Common variables:
- `DB_HOST`, `DB_PORT=3306`
- `REDIS_CACHE`, `REDIS_QUEUE`
- `FRAPPE_SITE_NAME_HEADER` (optional)
- One-off only: `SITE_NAME`, `ADMIN_PASSWORD`, `DB_ROOT_PASSWORD`

Nginx tuning (optional):
- `PROXY_READ_TIMEOUT`, `CLIENT_MAX_BODY_SIZE`
- `UPSTREAM_REAL_IP_ADDRESS`, `UPSTREAM_REAL_IP_HEADER`, `UPSTREAM_REAL_IP_RECURSIVE`

## Notes

- Ensure the persistent volume is mounted to `/home/frappe/frappe-bench/sites` before running one-off jobs.
- If you prefer host-based site routing, leave `FRAPPE_SITE_NAME_HEADER` unset and create the site with the exact host as its name.

