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

Set environment variables on the service:
- `DB_HOST`, `DB_PORT=3306`
- `REDIS_QUEUE`, `REDIS_CACHE`
- Optional: `FRAPPE_SITE_NAME_HEADER=<your-site-name>`

Note: The container has a healthcheck for `GET /api/method/ping` via nginx on port 8080.

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
