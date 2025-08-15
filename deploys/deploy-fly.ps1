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

function Get-Redis-Url($redisName) {
    $maxRetries = 15
    $retryDelaySeconds = 10 # Total wait time up to 150 seconds
    for ($i = 0; $i -lt $maxRetries; $i++) {
        Write-Info "Attempting to get Redis URL for '$redisName' (Attempt $($i+1)/$maxRetries)..."
        try {
            $status = & flyctl redis status $redisName 2>$null
            $endpointMatch = $status | Select-String 'Endpoint\s+(.+)'
            $passwordMatch = $status | Select-String 'Password\s+(.+)'

            if ($endpointMatch -and $passwordMatch) {
                $endpoint = $endpointMatch.Matches[0].Groups[1].Value.Trim()
                $password = $passwordMatch.Matches[0].Groups[1].Value.Trim()
                $url = "redis://:$($password)@$($endpoint)"
                Write-Success "Found Redis URL for '$redisName'"
                return $url
            }
        } catch {
            # Ignore errors and retry
        }
        Write-Info "Redis details not available yet. Waiting ${retryDelaySeconds}s..."
        Start-Sleep -Seconds $retryDelaySeconds
    }
    throw "Could not retrieve Redis URL for '$redisName' after $maxRetries attempts."
}

function Deploy-MariaDB($AppName, $Region) {
    $dbAppName = "$AppName-db"
    Write-Info "Deploying MariaDB app: $dbAppName"

    try {
        & flyctl apps create $dbAppName --org personal 2>$null
        Write-Success "MariaDB app created: $dbAppName"
    } catch {
        Write-Info "MariaDB app might already exist, continuing..."
    }

    try {
        & flyctl volumes create mariadb_data --app $dbAppName --region $Region --size 10 -y
        Write-Success "MariaDB volume created."
    } catch {
        Write-Info "MariaDB volume might already exist, continuing..."
    }

    $dbRootPassword = New-RandomPassword 20
    Write-Info "Setting MariaDB root password secret..."
    & flyctl secrets set --app $dbAppName "MARIADB_ROOT_PASSWORD=$dbRootPassword"

    # Update the mariadb.toml with the correct app name and region
    $mariaTomlPath = Join-Path $PSScriptRoot 'mariadb.toml'
    if (-not (Test-Path $mariaTomlPath)) {
        throw "mariadb.toml not found at $mariaTomlPath"
    }
    $mariaConfig = Get-Content $mariaTomlPath -Raw
    $mariaConfig = "app = `"$dbAppName`"`nprimary_region = `"$Region`"`n`n" + $mariaConfig
    $tempMariaTomlPath = Join-Path $env:TEMP "fly-mariadb-temp.toml"
    Set-Content -Path $tempMariaTomlPath -Value $mariaConfig -Encoding UTF8

    Write-Info "Deploying MariaDB container..."
    try {
        & flyctl deploy --app $dbAppName --config $tempMariaTomlPath --ha=false
        Write-Success "MariaDB deployed successfully."
    } finally {
        Remove-Item $tempMariaTomlPath -ErrorAction SilentlyContinue
    }

    return @{ Host = "$dbAppName.internal"; Port = 3306; Password = $dbRootPassword }
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
    $flyConfig = $flyConfig -replace 'app\s*=\s*"[^"]+"', "app = `"$AppName`""
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

        # Create the ERPNext app (if it doesn't exist)
        Write-Info "Creating Fly.io app: $AppName"
        try {
            & flyctl apps create $AppName --org personal 2>$null
            Write-Success "App created: $AppName"
        } catch {
            Write-Info "App might already exist, continuing..."
        }

        # Deploy MariaDB
        $dbInfo = Deploy-MariaDB -AppName $AppName -Region $Region

        # Check for and create Redis instances if they don't exist
        Write-Info "Checking for existing Redis instances..."
        $redisList = & flyctl redis list
        $redisCacheName = "$AppName-redis-cache"
        $redisQueueName = "$AppName-redis-queue"

        if ($redisList -like "*$redisCacheName*") {
            Write-Info "Redis cache '$redisCacheName' already exists, skipping creation."
        } else {
            Write-Info "Creating Redis cache instance..."
            & flyctl redis create --name $redisCacheName --region $Region --org personal
            Write-Success "Redis cache created: $redisCacheName"
        }

        if ($redisList -like "*$redisQueueName*") {
            Write-Info "Redis queue '$redisQueueName' already exists, skipping creation."
        } else {
            Write-Info "Creating Redis queue instance..."
            & flyctl redis create --name $redisQueueName --region $Region --org personal
            Write-Success "Redis queue created: $redisQueueName"
        }

        # Get Redis URLs
        $redisCacheUrl = Get-Redis-Url -redisName $redisCacheName
        $redisQueueUrl = Get-Redis-Url -redisName $redisQueueName

        # Set application secrets
        Write-Info "Setting application secrets..."
        $secrets = @(
            "DB_HOST=$($dbInfo.Host)",
            "DB_PORT=$($dbInfo.Port)",
            "DB_PASSWORD=$($dbInfo.Password)",
            "REDIS_CACHE_URL=$redisCacheUrl",
            "REDIS_QUEUE_URL=$redisQueueUrl",
            "REDIS_SOCKETIO_URL=$redisCacheUrl",
            "BOOTSTRAP_ADMIN_PASSWORD=$AdminPassword"
        )
        & flyctl secrets set --app $AppName $secrets
        Write-Success "Application secrets configured."

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

        # Get app URL
        $appUrl = "https://$AppName.fly.dev"
        
        Write-Host ""
        Write-Success "ERPNext deployment completed!"
        Write-Host "==========================================" -ForegroundColor Yellow
        Write-Host "URL:              $appUrl" -ForegroundColor Green
        Write-Host "Username:         Administrator" -ForegroundColor Green
        Write-Host "Password:         $AdminPassword" -ForegroundColor Green
        Write-Host "" 
        Write-Host "Database App:     $($AppName)-db" -ForegroundColor Cyan
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
