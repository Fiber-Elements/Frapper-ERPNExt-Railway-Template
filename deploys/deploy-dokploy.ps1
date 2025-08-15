#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIP,
    [string]$DomainName,
    [string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Warning $msg }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }

function New-RandomPassword([int]$length = 20) {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789_-'
    $arr = $chars.ToCharArray()
    -join ((1..$length) | ForEach-Object { $arr[(Get-Random -Minimum 0 -Maximum $arr.Length)] })
}

try {
    Write-Info "Starting ERPNext deployment to Dokploy..."
    
    # Generate admin password if not provided
    if (-not $AdminPassword) {
        $AdminPassword = New-RandomPassword 16
        Write-Info "Generated admin password: $AdminPassword"
    }

    # Set domain name
    $siteName = if ($DomainName) { $DomainName } else { "$ServerIP.traefik.me" }
    
    Write-Info "Deployment Configuration:"
    Write-Host "  Server IP:    $ServerIP" -ForegroundColor Yellow
    Write-Host "  Site Name:    $siteName" -ForegroundColor Yellow
    Write-Host "  Admin Pass:   $AdminPassword" -ForegroundColor Yellow
    Write-Host ""

    # Create docker-compose configuration for Dokploy
    $composeContent = @"
version: '3.8'

services:
  # Database
  db:
    image: mariadb:10.6
    restart: unless-stopped
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: frappe123
      MYSQL_DATABASE: frappe
      MYSQL_USER: frappe
      MYSQL_PASSWORD: frappe123
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: mysqladmin ping -h localhost --password=frappe123
      interval: 10s
      retries: 5
      start_period: 30s
      timeout: 10s

  # Redis Cache
  redis-cache:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis_cache_data:/data

  # Redis Queue  
  redis-queue:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis_queue_data:/data

  # Configurator (runs once to setup config)
  configurator:
    image: frappe/erpnext:v15.27.0
    restart: "no"
    command:
      - bash
      - -c
      - |
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis-cache:6379;
        wait-for-it -t 120 redis-queue:6379;
        export start=`date +%s`;
        until [[ -n `mysql -h db -u frappe -pfrappe123 -e "SELECT * FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='frappe'"` ]] && [[ `date +%s` -lt `expr $$start + 90` ]];
        do
          echo "Waiting for database to be ready...";
          sleep 3;
        done;
        echo "Database is ready!";
        bench set-config -g db_host db;
        bench set-config -g redis_cache redis://redis-cache:6379;
        bench set-config -g redis_queue redis://redis-queue:6379;
        bench set-config -g redis_socketio redis://redis-cache:6379;
        bench set-config -g socketio_port 3000;
    environment:
      DB_HOST: db
      DB_PORT: 3306
      REDIS_CACHE: redis://redis-cache:6379
      REDIS_QUEUE: redis://redis-queue:6379
      REDIS_SOCKETIO: redis://redis-cache:6379
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      db:
        condition: service_healthy

  # Site Creator (runs once to create ERPNext site)
  create-site:
    image: frappe/erpnext:v15.27.0
    restart: "no"
    command:
      - bash
      - -c
      - |
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis-cache:6379;
        wait-for-it -t 120 redis-queue:6379;
        if [[ ! -d "sites/$siteName" ]]; then
          echo "Creating new ERPNext site: $siteName";
          bench new-site $siteName --no-mariadb-socket --mariadb-root-password frappe123 --install-app erpnext --admin-password '$AdminPassword';
          bench --site $siteName set-config db_host db;
          bench --site $siteName set-config redis_cache 'redis://redis-cache:6379';
          bench --site $siteName set-config redis_queue 'redis://redis-queue:6379';
          bench --site $siteName set-config redis_socketio 'redis://redis-cache:6379';
        else
          echo "Site $siteName already exists, skipping creation";
        fi;
        echo "Site setup completed successfully!";
    environment:
      SITE_NAME: $siteName
      ADMIN_PASSWORD: $AdminPassword
      DB_HOST: db
      DB_PORT: 3306
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      - configurator

  # Backend (Gunicorn)
  backend:
    image: frappe/erpnext:v15.27.0
    restart: unless-stopped
    command:
      - bash
      - -c
      - |
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis-cache:6379;
        wait-for-it -t 120 redis-queue:6379;
        gunicorn --bind 0.0.0.0:8000 --threads 4 --timeout 120 frappe.app:application --preload;
    environment:
      SOCKETIO_PORT: 3000
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      - create-site

  # Frontend (Nginx)
  frontend:
    image: frappe/erpnext:v15.27.0
    restart: unless-stopped
    command:
      - bash  
      - -c
      - |
        wait-for-it -t 180 backend:8000;
        nginx-entrypoint.sh;
    environment:
      BACKEND: backend:8000
      SOCKETIO: websocket:3000
      UPSTREAM_REAL_IP_ADDRESS: 127.0.0.1
      UPSTREAM_REAL_IP_HEADER: X-Forwarded-For
      UPSTREAM_REAL_IP_RECURSIVE: "off"
      FRAPPE_SITE_NAME_HEADER: $siteName
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    ports:
      - "80:8080"
      - "443:8080"
    depends_on:
      - backend
      - websocket

  # WebSocket (Socket.IO)
  websocket:
    image: frappe/erpnext:v15.27.0
    restart: unless-stopped
    command:
      - bash
      - -c
      - |
        wait-for-it -t 120 redis-queue:6379;
        node /home/frappe/frappe-bench/apps/frappe/socketio.js;
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      - redis-queue

  # Scheduler
  scheduler:
    image: frappe/erpnext:v15.27.0
    restart: unless-stopped
    command:
      - bash
      - -c
      - |
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis-cache:6379;
        wait-for-it -t 120 redis-queue:6379;
        bench schedule;
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      - create-site

  # Queue Workers
  queue-short:
    image: frappe/erpnext:v15.27.0
    restart: unless-stopped  
    command:
      - bash
      - -c
      - |
        wait-for-it -t 120 redis-queue:6379;
        bench worker --queue short;
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      - create-site

  queue-long:
    image: frappe/erpnext:v15.27.0
    restart: unless-stopped
    command:
      - bash  
      - -c
      - |
        wait-for-it -t 120 redis-queue:6379;
        bench worker --queue long;
    volumes:
      - sites_data:/home/frappe/frappe-bench/sites
    depends_on:
      - create-site

volumes:
  sites_data:
  db_data:
  redis_cache_data:
  redis_queue_data:
"@

    # Save compose file
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $ScriptDir
    $ComposeFile = Join-Path $RepoRoot 'dokploy-docker-compose.yml'
    
    $composeContent | Set-Content -Path $ComposeFile -Encoding UTF8
    
    Write-Success "Docker Compose file created: dokploy-docker-compose.yml"
    
    # Create deployment instructions
    $instructions = @"
# ERPNext Dokploy Deployment Instructions

## Prerequisites
1. A VPS/server running Ubuntu 24.04
2. Dokploy installed and running
3. Domain name pointed to your server IP (optional but recommended)

## Deployment Steps

### 1. Install Dokploy on your server:
```bash
ssh root@$ServerIP
curl -sSL https://dokploy.com/install.sh | sh
```

### 2. Access Dokploy UI:
Open: http://$ServerIP:3000

### 3. Create Project:
- Click "+ Create Project"
- Name: erpnext-project

### 4. Deploy using Docker Compose:
- Click "+ Create Service" → "Compose"
- Name: erpnext-stack
- Copy the contents from dokploy-docker-compose.yml
- Configure domain (if using custom domain):
  - Go to Domains tab
  - Update Host field to your domain
  - Enable HTTPS with Let's Encrypt

### 5. Deploy:
- Click "Deploy" button
- Wait for deployment to complete (5-10 minutes)

## Post-Deployment

### Access your ERPNext:
- URL: http://$siteName (or https:// if SSL configured)
- Username: Administrator  
- Password: $AdminPassword

### Monitor deployment:
- Check Logs tab in Dokploy for any issues
- Look for "create-site" container logs for site creation progress

## Services Created:
- **Database**: MariaDB 10.6 with automatic setup
- **Cache**: Redis for caching
- **Queue**: Redis for background jobs
- **Application**: ERPNext with all required services

## Backup:
Add these services to your docker-compose.yml for automated backups:
- Database backup to external storage
- Site files backup
- Automated backup scheduling via cron

## Troubleshooting:
- Check container logs in Dokploy UI
- Verify all containers are running
- Ensure domain DNS is properly configured
- Check firewall rules (ports 80, 443, 3000)
"@

    $InstructionsFile = Join-Path $RepoRoot 'DOKPLOY-DEPLOYMENT.md'
    $instructions | Set-Content -Path $InstructionsFile -Encoding UTF8

    Write-Host ""
    Write-Success "Dokploy deployment files created successfully!"
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "Docker Compose:   dokploy-docker-compose.yml" -ForegroundColor Green
    Write-Host "Instructions:     DOKPLOY-DEPLOYMENT.md" -ForegroundColor Green
    Write-Host ""
    Write-Host "Site Configuration:" -ForegroundColor Cyan
    Write-Host "  URL:            http://$siteName" -ForegroundColor Green
    Write-Host "  Username:       Administrator" -ForegroundColor Green  
    Write-Host "  Password:       $AdminPassword" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Yellow
    Write-Host "1. Install Dokploy on your server: $ServerIP" -ForegroundColor White
    Write-Host "2. Access Dokploy UI: http://$ServerIP:3000" -ForegroundColor White
    Write-Host "3. Follow instructions in DOKPLOY-DEPLOYMENT.md" -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Yellow

} catch {
    Write-Err $_.Exception.Message
    Write-Info "Setup failed. Check the error above and try again."
    exit 1
}
