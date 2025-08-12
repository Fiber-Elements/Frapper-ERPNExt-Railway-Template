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
       - Redis: `REDISHOST`, `REDISPORT`
   - Networking: Enable Public HTTP, Healthcheck Path `/`.
   - Volume (recommended): attach `/home/frappe/frappe-bench/sites`.
4. Publish the template and copy its link; update the button URL above.

## How it works

- `Dockerfile` installs `nginx`, `supervisor`, and tools, then uses `entrypoint.sh`.
- `entrypoint.sh` maps Railway plugin vars (and supports `DATABASE_URL`/`REDIS_URL` fallbacks), renders nginx, waits for DB/Redis, creates the site if missing, enables scheduler, and starts Supervisor.
- `config/supervisord.conf` runs Gunicorn backend, workers, scheduler, socketio, and nginx.
- `config/nginx.conf` proxies `$PORT` to 127.0.0.1:8000 and socket.io on 127.0.0.1:9000, serves static/user files for the site.
- `railway.json` uses DOCKERFILE builder and a basic healthcheck.

## Environment

- Provided by Railway when services are linked:
  - MariaDB: `MYSQLHOST`, `MYSQLPORT`, `MYSQLDATABASE`, `MYSQLUSER`, `MYSQLPASSWORD`
  - Redis: `REDISHOST`, `REDISPORT`
- App variable (template):
  - `ADMIN_PASSWORD` (auto‑generated with `${{secret(32)}}`)
- Optional: `SITE_NAME` (defaults to `RAILWAY_PUBLIC_DOMAIN`), `PORT` (defaults to 8080 inside container; Railway maps externally).

## Troubleshooting

- Stuck on init? Check logs for DB readiness; template may take a few seconds to inject env vars. `entrypoint.sh` retries and prints diagnostics before failing.
- Ensure Public HTTP is enabled and Healthcheck Path is `/`.
- If you didn’t attach a volume, user files won’t persist across deploys.

## License

MIT
