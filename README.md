# ERPNext Local Quick Start (Docker)

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
./run-local.ps1
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
./run-local.ps1 -Port 8090

# Provide your own admin password (must be 8–64 chars, A‑Z a‑z 0‑9 _ -)
./run-local.ps1 -AdminPassword "YourStrong_Password-123"

# Do not auto-open the browser when done
./run-local.ps1 -OpenBrowser:$false
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

## Repo notes
- `run-local.ps1` automates the full local lifecycle.
- `frappe_docker/` is ignored by git and will be cloned/updated as needed.
- `.env.template` is provided for modular/cloud setups; it is not required for the local all‑in‑one flow.

## Security
- The script prints the Administrator password on completion. Store it securely.
- For repeatable credentials, pass `-AdminPassword` explicitly.

## License
This repository leverages the official `frappe_docker` setup. See their repository for license details of the images and compose files.
