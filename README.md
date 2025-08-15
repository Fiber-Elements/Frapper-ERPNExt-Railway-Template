# ERPNext Local Quick Start (Docker)

This repository lets you spin up a complete Frappe/ERPNext stack locally on Windows with a single PowerShell script. It uses the official `frappe_docker/pwd.yml` for an all‑in‑one setup.

## Deployment

### Local Quick Start (Docker)

This repository lets you spin up a complete Frappe/ERPNext stack locally on Windows with a single PowerShell script. It uses the official `frappe_docker/pwd.yml` for an all‑in‑one setup.

- Backend (Frappe/ERPNext)
- Frontend (Nginx)
- MariaDB 10.6
- Redis (cache and queue)
- Scheduler and workers

## Prerequisites
- Windows with PowerShell 5.1+
- Docker Desktop (with the Docker Compose plugin)
- Git (for first‑time automatic clone of `frappe_docker/`)

## Quick Start
1) Open PowerShell in the repo root
2) Run:

```powershell
./deploys/run-local.ps1
```

The script will:
- Ensure `frappe_docker/` exists (clone if missing, pull if it is a git repo).
- Pull required container images.
- Start core services: MariaDB, Redis (cache/queue).
- Wait for MariaDB to become healthy.
- Run one‑off configurator to write `sites/common_site_config.json`.
- Run one‑off site creation to install ERPNext on the default site `frontend`.
- Start application services (backend, websocket, frontend, scheduler, workers).
- Wait for readiness at `/api/method/ping` and set the Administrator password.
- Print the URL and credentials; optionally open your browser.

Default URL: `http://localhost:8080`
Default username: `Administrator`
Password: generated and printed by the script (or use `-AdminPassword`)

## Script options
```powershell
# Use a specific port (default 8080)
./deploys/run-local.ps1 -Port 8090

# Provide your own admin password (must be 8–64 chars, A‑Z a‑z 0‑9 _ -)
./deploys/run-local.ps1 -AdminPassword "YourStrong_Password-123"

# Do not auto-open the browser when done
./deploys/run-local.ps1 -OpenBrowser:$false
```

## Data persistence
Data is stored in Docker named volumes defined by `frappe_docker/pwd.yml`:
- `db-data`: MariaDB data
- `redis-queue-data`: Redis queue data
- `sites`: Frappe sites (configs, files, backups)
- `logs`: consolidated logs

These volumes persist across container restarts. Deleting them will erase data.

## Troubleshooting
- Check containers:
  ```powershell
  docker compose -f .\frappe_docker\pwd.yml ps
  ```
- View logs (examples):
  ```powershell
  docker compose -f .\frappe_docker\pwd.yml logs db
  docker compose -f .\frappe_docker\pwd.yml logs configurator
  docker compose -f .\frappe_docker\pwd.yml logs create-site
  docker compose -f .\frappe_docker\pwd.yml logs backend
  ```
- If startup times out, the script prints recent logs automatically.
- Warning: You may see a Compose warning about `version` being obsolete in `pwd.yml`. It’s harmless with Compose v2. If you want to silence it, remove the first line `version: "3"` from `frappe_docker/pwd.yml`.

## Common actions
- Stop services (keep data):
  ```powershell
  docker compose -f .\frappe_docker\pwd.yml down
  ```
- Remove everything including data (DANGER):
  ```powershell
  docker compose -f .\frappe_docker\pwd.yml down -v
  ```

## GCP Deployment (Compute Engine VM)

This option reproduces the local Docker Compose setup on a single GCE VM using `frappe_docker/pwd.yml` (MariaDB 10.6 + Redis + ERPNext).

* __Prerequisites__
  - Install Google Cloud SDK (`gcloud`) and authenticate.
  - A GCP project with billing enabled.
  - PowerShell (to run the helper script).

* __Quick start__
  ```powershell
  gcloud auth login
  gcloud config set project <PROJECT_ID>
  ./deploys/deploy-gcp.ps1 -ProjectId <PROJECT_ID> -Name erpnext-1 -Zone europe-west1-b -HttpPort 80 -AdminPassword "YourStrong_Password-123"
  ```

  - The script enables required APIs, creates firewall rules, provisions an Ubuntu VM, and passes a startup script (`scripts/gcp-startup.sh`).
  - First boot can take 10–20 minutes (image pulls, site creation). The script prints the public URL when available.

* __If you didn’t pass an AdminPassword__
  - A secure password is generated on the VM and printed in serial logs:
  ```powershell
  gcloud compute instances get-serial-port-output erpnext-1 --zone europe-west1-b --port 1
  ```

* __Fetch the external IP__ (if needed):
  ```powershell
  gcloud compute instances describe erpnext-1 --zone europe-west1-b --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
  ```

* __Cleanup__
  ```powershell
  gcloud compute instances delete erpnext-1 --zone europe-west1-b
  ```

Notes:
- This path keeps MariaDB 10.6 and Redis in containers, matching local behavior.
- For production hardening, add HTTPS (reverse proxy/managed certs), backups, monitoring, and consider attaching a separate persistent disk for `sites/`.
