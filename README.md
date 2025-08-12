# ERPNext on Railway (One‑Click Template)

This repo builds a Railway‑compatible Docker image for ERPNext (Frappe) and runs it with Supervisor + Gunicorn + Nginx, using external MariaDB and Redis services provided by Railway.

- Nginx listens on `$PORT` and proxies to Gunicorn/socket.io.
- Supervisor manages backend, workers, scheduler, socketio, and nginx.
- MariaDB + Redis are linked services; env vars are auto‑mapped in `entrypoint.sh`.

## One‑Click Deploy (Template)

Use a Railway Template to provision App + MariaDB + Redis with a single click.

[![Deploy on Railway](https://railway.app/button.svg)](TEMPLATE_URL_HERE)

Replace `TEMPLATE_URL_HERE` with your Template link after you create it (see below).

## Create the Template (once)

1. Workspace → Templates → Create Template → From Existing Project → pick this project.
2. Add services in Template Composer:
    - MariaDB (or MySQL)
    - Redis
3. App service configuration:
   - Variables:
     - `ADMIN_PASSWORD` = `${{secret(32)}}` (auto‑generated per deploy)
     - Reference variables from MariaDB and Redis so the app receives:
       - MariaDB: `MYSQLHOST`, `MYSQLPORT`, `MYSQLDATABASE`, `MYSQLUSER`, `MYSQLPASSWORD`
       - Redis: EITHER a full URL OR host/port/password
         - Preferred: `REDIS_URL` (or `REDIS_TLS_URL` if Railway provides TLS), e.g.
           - `redis://:PASSWORD@HOST:PORT` or `rediss://:PASSWORD@HOST:PORT`
           - Some providers use a username, e.g. `redis://default:PASSWORD@HOST:PORT`
         - Or map discrete vars: `REDISHOST`, `REDISPORT`, `REDISPASSWORD` (and optionally `REDISUSER`)
     - Optional: `USE_RQ_AUTH=0` (default). Set `1` only if you manage Redis yourself and run `bench create-rq-users`.
   - Networking: Enable Public HTTP, Healthcheck Path `/`.
   - Volume (recommended): attach `/home/frappe/frappe-bench/sites`.
4. Publish the template and copy its link; update the button URL above.

## How it works

- `Dockerfile` installs `nginx`, `supervisor`, and tools, then uses `entrypoint.sh`.
- `entrypoint.sh`:
  - Maps DB vars (or `DATABASE_URL`) and Redis vars (supports `REDIS_URL`/`REDIS_TLS_URL` or `REDISHOST`/`REDISPORT`/`REDISPASSWORD`).
  - Builds a single Redis URL and writes it to `redis_cache`, `redis_queue`, and `redis_socketio` (both global and per‑site config).
  - `USE_RQ_AUTH` toggles RQ ACL auth (defaults to `0` for managed Redis). When `0`, no Redis ACL users are required.
  - Renders nginx, waits for DB/Redis, creates the site if missing, enables scheduler, and starts Supervisor.
- `config/supervisord.conf` runs Gunicorn backend, workers, scheduler, socketio, and nginx.
- `config/nginx.conf` proxies `$PORT` to 127.0.0.1:8000 and socket.io on 127.0.0.1:9000, serves static/user files for the site.
- `railway.json` uses DOCKERFILE builder and a basic healthcheck.

## Environment

- Provided by Railway when services are linked:
  - MariaDB: `MYSQLHOST`, `MYSQLPORT`, `MYSQLDATABASE`, `MYSQLUSER`, `MYSQLPASSWORD`
  - Redis (any of the following work):
    - `REDIS_URL` or `REDIS_TLS_URL` (preferred)
    - or `REDISHOST`, `REDISPORT`, `REDISPASSWORD` (and optional `REDISUSER`)
- App variables (template):
  - `ADMIN_PASSWORD` (auto‑generated with `${{secret(32)}}`)
  - `USE_RQ_AUTH` (default `0`). Set to `1` only for self‑managed Redis with ACL users.
- Optional: `SITE_NAME` (defaults to `RAILWAY_PUBLIC_DOMAIN`), `PORT` (defaults to 8080 inside container; Railway maps externally).

### Minimal working config

- Link MariaDB and Redis services in Railway.
- Ensure one of the Redis options is set:
  - `REDIS_URL` (or `REDIS_TLS_URL`) including password
  - or `REDISHOST` + `REDISPORT` + `REDISPASSWORD`
- Leave `USE_RQ_AUTH=0` (default) for managed Redis.

## Troubleshooting

- __Init delay__: Check logs for DB readiness; env injection can take a few seconds. The script retries and prints diagnostics before failing.
- __NOAUTH / "Wrong credentials used for default user"__:
  - Make sure Redis credentials are provided via `REDIS_URL`/`REDIS_TLS_URL` or `REDISHOST`/`REDISPORT`/`REDISPASSWORD`.
  - Confirm `use_rq_auth` is `0` (default) by running `bench get-config -g use_rq_auth` in the container logs/shell.
  - If you intentionally use self‑managed Redis with ACL: set `USE_RQ_AUTH=1`, run `bench create-rq-users`, then restart.
- __Public access__: Ensure Public HTTP is enabled and Healthcheck Path is `/`.
- __Persistence__: If you didn’t attach a volume, user files won’t persist across deploys.

## License

MIT
