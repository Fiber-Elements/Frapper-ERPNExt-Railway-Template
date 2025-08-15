#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppName,
    [string]$Region = "fra",
    [string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Warning $msg }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }

function Test-Command($name) {
    try { & $name --version *> $null; return $true } catch { return $false }
}

function New-RandomPassword([int]$length = 20) {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789_-'
    $arr = $chars.ToCharArray()
    -join ((1..$length) | ForEach-Object { $arr[(Get-Random -Minimum 0 -Maximum $arr.Length)] })
}

try {
    Write-Info "Starting ERPNext deployment to Fly.io..."
    
    # Preflight checks
    Write-Info "Checking prerequisites..."
    if (-not (Test-Command 'flyctl')) { 
        throw "flyctl is not installed. Install it from: https://fly.io/docs/hands-on/install-flyctl/" 
    }

    # Get app name if not provided
    if (-not $AppName) {
        $AppName = Read-Host "Enter your app name (e.g., my-erpnext)"
        if ([string]::IsNullOrWhiteSpace($AppName)) {
            throw "App name is required"
        }
    }

    # Generate admin password if not provided
    if (-not $AdminPassword) {
        $AdminPassword = New-RandomPassword 16
        Write-Info "Generated admin password: $AdminPassword"
    }

    # Resolve paths
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $ScriptDir
    $FlyTomlPath = Join-Path $RepoRoot 'fly.toml'
    
    if (-not (Test-Path $FlyTomlPath)) {
        throw "fly.toml not found at: $FlyTomlPath"
    }

    # Update fly.toml with app name
    Write-Info "Updating fly.toml with app name: $AppName"
    $flyConfig = Get-Content $FlyTomlPath -Raw
    $flyConfig = $flyConfig -replace 'app = "erpnext-app"', "app = `"$AppName`""
    $flyConfig = $flyConfig -replace 'FRAPPE_SITE_NAME_HEADER = "erpnext-app.fly.dev"', "FRAPPE_SITE_NAME_HEADER = `"$AppName.fly.dev`""
    $flyConfig = $flyConfig -replace 'BOOTSTRAP_SITE = "erpnext-app.fly.dev"', "BOOTSTRAP_SITE = `"$AppName.fly.dev`""
    Set-Content -Path $FlyTomlPath -Value $flyConfig -Encoding UTF8

    # Change to repo root for fly commands
    Push-Location $RepoRoot
    
    try {
        # Check if already authenticated
        Write-Info "Checking Fly.io authentication..."
        try {
            & flyctl auth whoami | Out-Null
            Write-Info "Already authenticated with Fly.io"
        } catch {
            Write-Info "Please authenticate with Fly.io..."
            & flyctl auth login
        }

        # Create the app (if it doesn't exist)
        Write-Info "Creating Fly.io app: $AppName"
        try {
            & flyctl apps create $AppName --org personal 2>$null
            Write-Success "App created: $AppName"
        } catch {
            Write-Info "App might already exist, continuing..."
        }

        # Create PostgreSQL database
        Write-Info "Creating PostgreSQL database..."
        $dbName = "$AppName-db"
        try {
            & flyctl postgres create --name $dbName --region $Region --initial-cluster-size 1 --vm-size shared-cpu-1x --volume-size 10 --org personal
            Write-Success "PostgreSQL database created: $dbName"
        } catch {
            Write-Info "Database might already exist, continuing..."
        }

        # Attach database to app
        Write-Info "Attaching database to app..."
        & flyctl postgres attach $dbName --app $AppName

        # Create Redis instances
        Write-Info "Creating Redis cache instance..."
        $redisCacheName = "$AppName-redis-cache"
        try {
            & flyctl redis create --name $redisCacheName --region $Region --org personal
            Write-Success "Redis cache created: $redisCacheName"
        } catch {
            Write-Info "Redis cache might already exist, continuing..."
        }

        Write-Info "Creating Redis queue instance..."
        $redisQueueName = "$AppName-redis-queue"
        try {
            & flyctl redis create --name $redisQueueName --region $Region --org personal
            Write-Success "Redis queue created: $redisQueueName"
        } catch {
            Write-Info "Redis queue might already exist, continuing..."
        }

        # Get Redis URLs and set as secrets
        Write-Info "Configuring Redis connections..."
        # Get Redis URLs from status output (parsing text output instead of JSON)
        try {
            $redisCacheStatus = & flyctl redis status $redisCacheName 2>$null
            $redisQueueStatus = & flyctl redis status $redisQueueName 2>$null
            
            # Extract private URLs from status output
            $redisCacheUrl = ($redisCacheStatus | Select-String "Private URL:\s*(.+)" | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $redisQueueUrl = ($redisQueueStatus | Select-String "Private URL:\s*(.+)" | ForEach-Object { $_.Matches[0].Groups[1].Value })
            
            if ($redisCacheUrl) { $redisCacheUrl = $redisCacheUrl.Trim() }
            if ($redisQueueUrl) { $redisQueueUrl = $redisQueueUrl.Trim() }
            
            # Validate URLs were extracted
            if (-not $redisCacheUrl -or -not $redisQueueUrl) {
                Write-Warn "Could not extract Redis URLs from status output. Using fallback method..."
                # Fallback: construct URLs manually
                $redisCacheUrl = "redis://$redisCacheName.flycast:6379"
                $redisQueueUrl = "redis://$redisQueueName.flycast:6379"
            }
            
            Write-Info "Redis Cache URL: $redisCacheUrl"
            Write-Info "Redis Queue URL: $redisQueueUrl"
        } catch {
            Write-Warn "Error getting Redis status: $($_.Exception.Message)"
            Write-Info "Using fallback Redis URLs..."
            $redisCacheUrl = "redis://$redisCacheName.flycast:6379"
            $redisQueueUrl = "redis://$redisQueueName.flycast:6379"
        }

        # Set application secrets
        Write-Info "Setting application secrets..."
        & flyctl secrets set --app $AppName "BOOTSTRAP_ADMIN_PASSWORD=$AdminPassword"
        
        if ($redisCacheUrl -and $redisQueueUrl) {
            & flyctl secrets set --app $AppName "REDIS_CACHE_URL=$redisCacheUrl"
            & flyctl secrets set --app $AppName "REDIS_QUEUE_URL=$redisQueueUrl"
            & flyctl secrets set --app $AppName "REDIS_SOCKETIO_URL=$redisCacheUrl"
            Write-Success "Redis connection secrets set successfully"
        } else {
            Write-Warn "Redis URLs not available, skipping Redis secret configuration"
            Write-Info "You may need to manually configure Redis connections after deployment"
        }

        # Create volume for persistent storage
        Write-Info "Creating volume for site files..."
        try {
            & flyctl volumes create frappe_sites --region $Region --size 5 --app $AppName
            Write-Success "Volume created: frappe_sites"
        } catch {
            Write-Info "Volume might already exist, continuing..."
        }

        # Deploy the application
        Write-Info "Deploying ERPNext application..."
        & flyctl deploy --app $AppName --wait-timeout 900

        # Wait for deployment to be ready
        Write-Info "Waiting for application to be ready..."
        Start-Sleep 30

        # Get app URL
        $appUrl = "https://$AppName.fly.dev"
        
        Write-Host ""
        Write-Success "ERPNext deployment completed!"
        Write-Host "==========================================" -ForegroundColor Yellow
        Write-Host "URL:              $appUrl" -ForegroundColor Green
        Write-Host "Username:         Administrator" -ForegroundColor Green
        Write-Host "Password:         $AdminPassword" -ForegroundColor Green
        Write-Host "" 
        Write-Host "Database:         $dbName" -ForegroundColor Cyan
        Write-Host "Redis Cache:      $redisCacheName" -ForegroundColor Cyan
        Write-Host "Redis Queue:      $redisQueueName" -ForegroundColor Cyan
        Write-Host "==========================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Info "Note: First boot may take 5-10 minutes to create the ERPNext site."
        Write-Info "Check deployment logs with: flyctl logs --app $AppName"

    } finally {
        Pop-Location
    }

} catch {
    Write-Err $_.Exception.Message
    Write-Info "Deployment failed. Check the error above and try again."
    Write-Info "You can check logs with: flyctl logs --app $AppName"
    exit 1
}
