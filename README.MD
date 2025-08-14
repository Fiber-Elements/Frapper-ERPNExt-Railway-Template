# **Frappe ERPNext with Docker (Local) and Google Cloud Run**

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

- `Dockerfile` — container image builder (pinned versions)
- `resources/` — entrypoints, templates, `apps.txt`, `Procfile`
- `run-local.ps1` — local Docker Compose helper (creates `.env` if missing)
- Cloud Run is deployed using `gcloud` (no cloudbuild.yaml required). See "Google Cloud Run Deployment" below.

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

## Google Cloud Run Deployment

### Prerequisites

- Google Cloud project with billing enabled
- gcloud CLI installed and configured: `gcloud auth login && gcloud config set project <PROJECT_ID>`
- Optional: Artifact Registry repository (or use GCR)

### Build and deploy (example using GCR)

```bash
# From repo root
gcloud builds submit --tag gcr.io/<PROJECT_ID>/erpnext:latest

# Deploy to Cloud Run (fully managed)
gcloud run deploy erpnext \
  --image gcr.io/<PROJECT_ID>/erpnext:latest \
  --platform managed \
  --region <REGION> \
  --allow-unauthenticated \
  --set-env-vars PORT=8080 \
  --set-env-vars FRAPPE_SITE_NAME_HEADER=<your-hostname-or-run.app-host> \
  --set-env-vars DATABASE_URL="<mysql|postgres>://user:pass@host:port/dbname" \
  --set-env-vars REDIS_QUEUE_URL="redis://:pass@host:port" \
  --set-env-vars REDIS_CACHE_URL="redis://:pass@host:port" \
  --set-env-vars AUTO_BOOTSTRAP=1 \
  --set-env-vars BOOTSTRAP_SITE=<site_name> \
  --set-env-vars BOOTSTRAP_ADMIN_PASSWORD=<strong_password>

# Increase request/startup timeout if first boot is slow
gcloud run services update erpnext --region <REGION> --timeout 300
```

Notes:

- The image binds to the Cloud Run-provided `PORT` automatically (defaults to 8080 if not set).
- `AUTO_BOOTSTRAP=1` attempts to create the site on first boot using the DB credentials from `DATABASE_URL`.
- Cloud Run has an ephemeral filesystem; persistent volumes for `sites/` are not supported. For production, consider GKE or a VM.

---

## How It Works (Important)

- Container ENTRYPOINT is `resources/docker-entrypoint.sh`.
- ENTRYPOINT parses `DATABASE_URL`, sets `REDIS_CACHE`/`REDIS_QUEUE`, and sets `REDIS_SOCKETIO` from queue by default.
- ENTRYPOINT ensures `/home/frappe/frappe-bench/sites/apps.txt` exists by copying from image on first boot and `cd`s into `sites`.
- The container runs Gunicorn and binds to `${PORT}` (Cloud Run sets this; default 8080).
- Workers/scheduler/websocket patterns exist in `resources/Procfile` for reference, but Cloud Run only runs a single container process.

---

## Troubleshooting & Debugging

### Google Cloud Run

- **View logs**

  - Console: Cloud Run service > Logs
  - CLI example:

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="erpnext"' --limit=100 --format=json
```

- **Container failed to start or not listening on port**
  - Ensure the image binds to `${PORT}` (Dockerfile CMD uses `--bind=0.0.0.0:${PORT:-8080}`).
  - Increase startup timeout: `gcloud run services update erpnext --timeout 300`.

- **Crash: OSError './apps.txt' Not Found**
  - ENTRYPOINT seeds `apps.txt` into `sites/` on first boot.
  - Ensure `resources/apps.txt` exists in the image (Dockerfile copies it).

- **Redis tries 127.0.0.1**
  - Set `REDIS_CACHE_URL` and `REDIS_QUEUE_URL` env vars.
  - ENTRYPOINT exports `REDIS_SOCKETIO` from queue URL unless explicitly provided.

- **Database or auth errors**
  - Verify `DATABASE_URL` and that Cloud Run can reach your DB/Redis (public endpoints or VPC connector).

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

- Build (GCR): `gcloud builds submit --tag gcr.io/<PROJECT_ID>/erpnext:latest`
- Deploy: `gcloud run deploy erpnext --image gcr.io/<PROJECT_ID>/erpnext:latest --region <REGION> --allow-unauthenticated`
- Logs (CLI): `gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="erpnext"' --limit=100`
- Local up/down/logs/ps: `./run-local.ps1 up|down|logs|ps`
- Set admin password (Cloud Run exec into a debug container or use bench inside a local container with same DB):

```powershell
# Example (local):
docker compose exec backend bench --site <site> set-admin-password <pwd>
```

---

## Notes

- `.env` is for local only. Cloud Run uses environment variables configured on the service.
- `Procfile` exists for reference/local `bench start` patterns; Cloud Run runs a single container process.
- Cloud Run has an ephemeral filesystem; ERPNext typically needs persistent `sites/`. For production, prefer GKE or a VM.
