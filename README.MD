# **A Comprehensive Guide to Self-Hosting Frappe ERPNext with Docker and Fly.io**

## **Local Quick Start Guide**

This section provides a streamlined set of instructions to get a local instance of Frappe ERPNext running quickly.

### **Prerequisites**

*   [Git](https://git-scm.com/downloads)
*   [Docker Desktop](https://www.docker.com/products/docker-desktop/)

### **Setup Steps**

1.  **Clone the `frappe_docker` repository:**
    ```bash
    git clone https://github.com/frappe/frappe_docker
    cd frappe_docker
    ```

2.  **Create the environment configuration file:**
    Copy the example environment file to a new `.env` file. This file contains the default settings for your local instance.
    ```bash
    # For Windows (PowerShell)
    Copy-Item example.env .env

    # For macOS / Linux
    cp example.env .env
    ```

3.  **Start Docker Desktop:**
    Ensure that Docker Desktop is running on your machine before proceeding.

4.  **Launch the ERPNext Stack:**
    Use Docker Compose to start all the required services in the background. This command uses the `pwd.yml` file, which is designed for a "Play with Docker" setup.
    ```bash
    docker compose -f pwd.yml up -d
    ```
    The initial startup may take several minutes as Docker downloads the necessary images and runs the setup for the first time.

5.  **Set the Administrator Password:**
    After a few minutes, the site will be created. To log in, you need to set the Administrator password. Run the following command:
    ```bash
    docker compose -f pwd.yml exec backend bench --site frontend set-admin-password admin
    ```
    You can replace `admin` with any password you choose.

6.  **Access Your ERPNext Site:**
    Your local ERPNext instance is now ready. Open your web browser and navigate to:
    [http://localhost:8080](http://localhost:8080)

    Log in with the following credentials:
    *   **Username:** `Administrator`
    *   **Password:** The password you set in the previous step (e.g., `admin`).

---

# Frappe ERPNext on Fly.io — Automated Deploy + Local Dev

Production-ready automation to build and deploy Frappe/ERPNext to Fly.io, plus a simple way to run it locally with Docker.

## Key Files

- `Dockerfile` — production image builder (pinned versions)
- `fly.toml` — Fly.io app config and process definitions
- `resources/` — entrypoints, templates, `apps.txt`, `Procfile`
- `deploy.ps1` — automated Fly.io provision + deploy (app, Postgres, Redis, volume, secrets)
- `teardown.ps1` — destroy app + managed Postgres + Redis
- `run-local.ps1` — local Docker Compose helper (creates `.env` if missing)

---

## Local Quick Start (Docker)

Use for development only.

### Prerequisites

- Docker Desktop
- PowerShell (Windows)

### Steps

1) Start Docker Desktop.
2) From repo root, run:

```powershell
./run-local.ps1 up
```

This creates `.env` from `.env.template` (or example) if missing and starts docker compose.

3) Inspect / logs:

```powershell
./run-local.ps1 ps
./run-local.ps1 logs
```

4) Open:

- Web: http://localhost:8000
- Socket.IO: http://localhost:9000

5) Set Administrator password (example):

```powershell
docker compose exec backend bench --site frontend set-admin-password admin
```

Stop:

```powershell
./run-local.ps1 down
```

Notes:

- `.env` in repo root is for local only and is auto-created.
- `.env` is ignored by Git.

---

## Fly.io Deployment (Automated)

### Prerequisites

- Fly CLI installed and logged in: `fly auth login`
- Billing enabled on your Fly org

### Deploy

```powershell
./deploy.ps1
```

It will:

- Create/update the Fly app from `fly.toml`
- Provision managed Postgres and Redis
- Create a persistent volume for `sites`
- Extract Redis private URL and set secrets `REDIS_CACHE_URL`, `REDIS_QUEUE_URL`
- Deploy the Docker image

Post-deploy:

- URL: `https://<app>.fly.dev`
- Logs: `fly logs -a <app>`

Set admin password (example):

```powershell
fly ssh console -a <app> -C "bash -lc 'cd /home/frappe/frappe-bench/sites && bench --site <site> set-admin-password <pwd>'"
```

Teardown everything:

```powershell
./teardown.ps1
```

---

## How It Works (Important)

- Container ENTRYPOINT is `resources/docker-entrypoint.sh`.
- ENTRYPOINT parses `DATABASE_URL`, sets `REDIS_CACHE`/`REDIS_QUEUE`, and sets `REDIS_SOCKETIO` from queue by default.
- ENTRYPOINT ensures `/home/frappe/frappe-bench/sites/apps.txt` exists by copying from image on first boot and `cd`s into `sites`.
- `fly.toml` app process uses gunicorn on port `8000` (`http_service.internal_port = 8000`).
- Workers/scheduler/websocket run under the same ENTRYPOINT so they inherit DB/Redis env and working dir.

---

## Troubleshooting & Debugging

### Fly.io

- **View logs**

```bash
fly logs -a <app>
```

- **Crash: OSError './apps.txt' Not Found**
  - First boot with empty volume; ENTRYPOINT now copies `apps.txt` into `sites/` and sets CWD to `sites/`.
  - Ensure `Dockerfile` copies `resources/apps.txt` into image. Re-deploy if needed.

- **Redis tries 127.0.0.1**
  - Ensure secrets `REDIS_CACHE_URL` and `REDIS_QUEUE_URL` are set (the deploy script sets them).
  - ENTRYPOINT exports `REDIS_SOCKETIO` from queue URL unless explicitly provided.

- **Wrong port**
  - App binds to `8000`. Ensure `fly.toml` `http_service.internal_port = 8000`.

- **Volume too small**

```bash
fly vol list -a <app>
fly vol extend <volume_id> --size <GB>
```

- **Exec into machine**

```bash
fly ssh console -a <app>
```

### Local

- `./run-local.ps1 logs` — tail logs
- `./run-local.ps1 ps` — list services
- Edit repo-root `.env` for compose overrides
- Set admin password with `docker compose exec backend bench --site <site> set-admin-password <pwd>`

---

## Reproducibility Checklist

- Use this repo’s Dockerfile and scripts; avoid manual Fly dashboard edits.
- Keep pinned versions (Python/Node/Frappe/ERPNext) in `Dockerfile` args.
- Fresh rebuild:

```powershell
./teardown.ps1
./deploy.ps1
```

If you fork/rename, update `fly.toml` `app`/`primary_region` accordingly.

---

## Command Cheat Sheet

- Deploy: `./deploy.ps1`
- Logs: `fly logs -a <app>`
- Teardown: `./teardown.ps1`
- Local up/down/logs/ps: `./run-local.ps1 up|down|logs|ps`
- Set admin password (Fly):

```powershell
fly ssh console -a <app> -C "bash -lc 'cd /home/frappe/frappe-bench/sites && bench --site <site> set-admin-password <pwd>'"
```

---

## Notes

- `.env` is for local only; Fly uses `fly.toml` + secrets.
- `Procfile` exists for local `bench start` patterns; Fly uses explicit process commands.
