# ERPNext Multi-Platform Deployment

This repository provides automated deployment solutions for ERPNext across different platforms. Each deployment automatically provisions databases, Redis instances, and connects them to your ERPNext installation.

## 🚀 Deployment Options

### 1. Fly.io (Cloud - Recommended)

Deploy ERPNext to Fly.io with managed PostgreSQL and Redis services.

**Features:**
- Automatic PostgreSQL database provisioning
- Managed Redis cache and queue instances  
- Global CDN and load balancing
- Automatic SSL certificates
- Built-in monitoring and logging

**Requirements:**
- Fly.io CLI: https://fly.io/docs/hands-on/install-flyctl/
- Fly.io account (free tier available)

**Quick Start:**
```powershell
# Deploy with automatic app name prompt
./deploys/deploy-fly.ps1

# Deploy with custom app name and password
./deploys/deploy-fly.ps1 -AppName "my-erpnext" -AdminPassword "secure123"
```

### 2. Dokploy (Self-Hosted with UI)

Self-hosted deployment with web-based management interface.

**Features:**
- One-click deployment via web UI
- Automatic MariaDB database setup
- Dedicated Redis cache and queue instances
- Automatic SSL with Let's Encrypt
- Built-in backup scheduling

**Requirements:**
- VPS/server running Ubuntu 24.04+
- Dokploy installed on your server
- Optional: Domain name for custom URL

**Quick Start:**
```powershell
# Generate deployment files for your server
./deploys/deploy-dokploy.ps1 -ServerIP "your-server-ip" -DomainName "your-domain.com"
```

### 3. Local Docker (Development)

This repository lets you spin up a complete Frappe/ERPNext stack locally on Windows with a single PowerShell script. It uses the official `frappe_docker/pwd.yml` for an all‑in‑one setup.

- Backend (Frappe/ERPNext)
- Frontend (Nginx)
- MariaDB 10.6
- Redis (cache and queue)
- Scheduler and workers

**Features:**
- Complete local development environment
- MariaDB 10.6 with health checks
- Redis cache and queue instances
- All ERPNext services orchestrated
- Port management and conflict resolution

**Requirements:**
- Windows with PowerShell 5.1+
- Docker Desktop (with Docker Compose plugin)
- Git (for automatic clone of `frappe_docker/`)

**Quick Start:**
```powershell
# Run locally on port 8080
./deploys/run-local.ps1

# Use specific port and custom password
./deploys/run-local.ps1 -Port 9000 -AdminPassword "dev123"

# Don't auto-open browser
./deploys/run-local.ps1 -OpenBrowser:$false
```

## 📊 Platform Comparison

| Platform | Cost | Setup Time | Management | Scalability | Best For |
|----------|------|------------|------------|-------------|----------|
| **Fly.io** | Free tier + usage | 5 minutes | Managed | Auto-scaling | Production, Global |
| **Dokploy** | VPS cost only | 10 minutes | Self-managed UI | Manual scaling | Self-hosted Production |
| **Local** | Free | 2 minutes | Manual | Single instance | Development |

## 🔧 Local Development Details

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
