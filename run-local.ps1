#requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Port = 8080,
  [string]$AdminPassword,
  [switch]$OpenBrowser = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Warning $msg }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Command($name) {
  try { & $name --version *> $null; return $true } catch { return $false }
}

function Ensure-FrappeDockerSources([string]$Dir) {
  if (-not (Test-Path $Dir)) {
    if (-not (Test-Command 'git')) { throw "Missing '$Dir' and 'git' not found. Install Git or add the 'frappe_docker' folder." }
    Write-Info "Cloning frappe_docker into $Dir ..."
    & git clone https://github.com/frappe/frappe_docker $Dir | Out-Host
  } else {
    $gitDir = Join-Path $Dir '.git'
    if (Test-Path $gitDir) {
      if (-not (Test-Command 'git')) { Write-Warn "Git not available, skipping pull of $Dir."; return }
      Write-Info "Updating frappe_docker (git pull) ..."
      Push-Location $Dir
      try { & git pull --ff-only | Out-Host } finally { Pop-Location }
    } else {
      Write-Info "Using existing frappe_docker directory (not a git repo)."
    }
  }
}

function New-RandomPassword([int]$length = 20) {
  # Use only shell-safe characters to avoid quoting issues in downstream commands
  $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789_-'
  $arr = $chars.ToCharArray()
  -join ((1..$length) | ForEach-Object { $arr[(Get-Random -Minimum 0 -Maximum $arr.Length)] })
}

function Test-PortFree([int]$Port) {
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $listener.Stop()
    return $true  # bind succeeded => port is free
  } catch {
    return $false # bind failed => port likely in use
  }
}

function Find-FreePort([int]$StartPort) {
  $p = [Math]::Max(1024, $StartPort)
  foreach ($candidate in $p..($p+200)) {
    if (Test-PortFree $candidate) { return $candidate }
  }
  throw "Could not find a free port in range $StartPort-$($StartPort+200)."
}

function Wait-Http([string]$Url, [int]$TimeoutSec = 900) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5 -ErrorAction Stop
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { return $true }
    } catch {
      Start-Sleep -Seconds 3
    }
  }
  return $false
}

try {
  Write-Info 'Preflight checks'
  if (-not (Test-Command 'docker')) { throw 'Docker is not installed or not on PATH. Please install Docker Desktop and try again.' }

  # Resolve paths
  $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  Ensure-FrappeDockerSources -Dir (Join-Path $ScriptDir 'frappe_docker')
  $ComposeFile = Join-Path $ScriptDir 'frappe_docker\pwd.yml'
  if (-not (Test-Path $ComposeFile)) { throw "Compose file not found: $ComposeFile" }

  # Ensure a password (safe characters only to avoid quoting issues): A-Za-z0-9_-
  $safePattern = '^[A-Za-z0-9_-]{8,64}$'
  if ($AdminPassword -and ($AdminPassword -match $safePattern)) {
    # ok
  } else {
    if ($AdminPassword) { Write-Warn 'Provided AdminPassword is unsafe or too short. Generating a safe strong password instead.' }
    $AdminPassword = New-RandomPassword 20
    Write-Info 'Using generated strong Administrator password.'
  }

  # Ensure desired port is free (or pick the next free)
  $ChosenPort = $Port
  if (-not (Test-PortFree $ChosenPort)) {
    $newPort = Find-FreePort ($Port + 1)
    Write-Warn "Port $Port is busy. Using free port $newPort instead."
    $ChosenPort = $newPort
  }

  # Build compose args; only use override if port != 8080
  $ComposeArgsBase = @('-f', $ComposeFile)
  # Always add a temporary override to ensure stable startup ordering and optional port change.
  # This keeps the cloned frappe_docker sources untouched.
  $OverridePath = Join-Path $env:TEMP ("frappe_override_" + [Guid]::NewGuid().ToString('N') + '.yml')
  @"
services:
  frontend:
    ports:
      - "${ChosenPort}:8080"
    depends_on:
      - backend
    command:
      - nginx-entrypoint.sh
  websocket:
    depends_on:
      - redis-queue
    command:
      - node
      - /home/frappe/frappe-bench/apps/frappe/socketio.js
"@ | Set-Content -Encoding UTF8 -Path $OverridePath
  $ComposeArgsBase += @('-f', $OverridePath)
  $UsingOverride = $true
  Write-Info "Using override file: $OverridePath (port ${ChosenPort})"

  # Pull images first (faster subsequent runs)
  Write-Info 'Pulling images (if needed)...'
  & docker compose @ComposeArgsBase 'pull' | Out-Host

  # Start core dependencies first
  Write-Info 'Starting core services: db, redis-cache, redis-queue'
  & docker compose @ComposeArgsBase 'up' '-d' 'db' 'redis-cache' 'redis-queue' | Out-Host

  # Wait for MariaDB health
  Write-Info 'Waiting for MariaDB (db) to become healthy...'
  $dbIdRaw = & docker compose @ComposeArgsBase 'ps' '-q' 'db' 2>$null
  $dbId = if ($null -ne $dbIdRaw) { ($dbIdRaw | Out-String).Trim() } else { '' }
  if ([string]::IsNullOrWhiteSpace($dbId)) {
    Write-Err 'Could not get container ID for db. Printing compose ps and db logs for diagnosis.'
    & docker compose @ComposeArgsBase 'ps' | Out-Host
    & docker compose @ComposeArgsBase 'logs' 'db' | Out-Host
    throw 'Database container not found or not started.'
  }
  $deadline = (Get-Date).AddMinutes(5)
  $healthy = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $status = (& docker inspect -f "{{.State.Health.Status}}" $dbId).Trim()
      if ($status -eq 'healthy') { $healthy = $true; break }
    } catch {}
    Start-Sleep -Seconds 3
  }
  if (-not $healthy) {
    Write-Err 'MariaDB did not become healthy in time.'
    & docker compose @ComposeArgsBase 'logs' 'db' | Out-Host
    throw 'Database not healthy.'
  }

  # Run configurator to create common_site_config.json
  Write-Info 'Configuring common_site_config.json (configurator)...'
  & docker compose @ComposeArgsBase 'up' '--no-deps' '--exit-code-from' 'configurator' 'configurator' | Out-Host

  # Create site and install ERPNext
  Write-Info 'Creating site and installing ERPNext (create-site). This can take several minutes on first run...'
  & docker compose @ComposeArgsBase 'up' '--no-deps' '--exit-code-from' 'create-site' 'create-site' | Out-Host

  # Start application services
  Write-Info 'Starting application services: backend, websocket, frontend, scheduler, queue workers'
  & docker compose @ComposeArgsBase 'up' '-d' 'backend' 'websocket' 'frontend' 'scheduler' 'queue-short' 'queue-long' | Out-Host

  # Basic service status
  Write-Info 'Checking service status...'
  & docker compose @ComposeArgsBase 'ps' | Out-Host

  # Wait for HTTP to respond
  $Url = "http://localhost:$ChosenPort"
  $PingUrl = "$Url/api/method/ping"
  Write-Info "Waiting for ERPNext to respond at $PingUrl (this can take several minutes on first run)..."
  if (-not (Wait-Http -Url $PingUrl -TimeoutSec 1200)) {
    Write-Err 'Timed out waiting for ERPNext to become ready.'
    Write-Host 'Recent logs:' -ForegroundColor Yellow
    & docker compose @ComposeArgsBase 'logs' '--since' '10m' | Out-Host
    throw 'Startup did not complete in time.'
  }

  # Set Administrator password on the default site (created as "frontend" by pwd.yml)
  Write-Info 'Setting Administrator password...'
  $cmd = @('exec','-T','backend','bash','-lc',"bench --site frontend set-admin-password $AdminPassword")
  & docker compose @ComposeArgsBase @cmd

  Write-Host "" -NoNewline
  Write-Host 'Deployment complete!' -ForegroundColor Green
  Write-Host '----------------------------------------'
  Write-Host ("URL:        {0}" -f $Url)
  Write-Host 'Username:   Administrator'
  Write-Host ("Password:   {0}" -f $AdminPassword)
  Write-Host 'Note: Services include MariaDB 10.6 and Redis (queue + cache), started via Docker Compose.'

  if ($OpenBrowser) {
    try { Start-Process $Url } catch {}
  }
}
catch {
  Write-Err $_.Exception.Message
  exit 1
}
finally {
  if ($UsingOverride -and (Test-Path $OverridePath)) { Remove-Item $OverridePath -ErrorAction SilentlyContinue }
}
