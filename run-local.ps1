Param(
    [ValidateSet('up','down','logs','ps')]
    [string]$Action = 'up'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host $msg -ForegroundColor Red }

$RepoRoot = Split-Path -Parent $PSCommandPath
$EnvPath = Join-Path $RepoRoot '.env'
$EnvTemplatePath = Join-Path $RepoRoot '.env.template'
$ExampleEnvPath = Join-Path $RepoRoot 'frappe_docker\example.env'

# Find a docker compose file
$ComposeCandidates = @(
    (Join-Path $RepoRoot 'docker-compose.yml'),
    (Join-Path $RepoRoot 'compose.yml'),
    (Join-Path $RepoRoot 'frappe_docker\docker-compose.yml'),
    (Join-Path $RepoRoot 'frappe_docker\compose.yml')
)
$ComposeFile = $ComposeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ComposeFile) {
    Write-Err 'Could not find a docker compose file. Looked for docker-compose.yml or compose.yml in root and frappe_docker/.'
    exit 1
}

# Ensure .env exists for local compose
if (-not (Test-Path $EnvPath)) {
    if (Test-Path $EnvTemplatePath) {
        Write-Info 'Creating .env from .env.template...'
        Copy-Item -Path $EnvTemplatePath -Destination $EnvPath -Force
    } elseif (Test-Path $ExampleEnvPath) {
        Write-Info 'Creating .env from frappe_docker/example.env...'
        Copy-Item -Path $ExampleEnvPath -Destination $EnvPath -Force
    } else {
        Write-Warn 'No .env.template or example.env found. Creating a minimal .env.'
        @(
            'ERPNEXT_VERSION=version-15',
            'FRAPPE_VERSION=version-15',
            'SITES_ROOT=./frappe_docker',
            '# Customize any overrides below'
        ) | Set-Content -Path $EnvPath -NoNewline:$false
    }
    Write-Ok ".env created at $EnvPath. Review and adjust values as needed."
}

# Check Docker availability
try {
    docker version | Out-Null
} catch {
    Write-Err 'Docker is not available. Please install Docker Desktop and ensure it is running.'
    exit 1
}

# Helper to build docker compose args
$composeArgs = @('compose','-f', $ComposeFile, '--env-file', $EnvPath)

switch ($Action) {
    'up' {
        Write-Info "Starting local stack using: $ComposeFile"
        & docker @composeArgs up -d --remove-orphans
        Write-Ok 'Containers started.'
        Write-Info 'Common endpoints:'
        Write-Host ' - Web:        http://localhost:8000' -ForegroundColor Gray
        Write-Host ' - Socket.IO:  http://localhost:9000' -ForegroundColor Gray
        Write-Host ' - Traefik/NGINX (if present): http://localhost:8080' -ForegroundColor Gray
        & docker @composeArgs ps
    }
    'down' {
        Write-Info 'Stopping and removing containers...'
        & docker @composeArgs down -v
        Write-Ok 'Local stack stopped.'
    }
    'logs' {
        Write-Info 'Tailing logs (Ctrl+C to stop)...'
        & docker @composeArgs logs -f --tail=200
    }
    'ps' {
        & docker @composeArgs ps
    }
    default {
        Write-Err "Unknown action: $Action"
        exit 1
    }
}
