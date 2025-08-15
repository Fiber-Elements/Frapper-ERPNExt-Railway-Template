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
            $privateUrlMatch = $status | Select-String 'Private URL\s*=\s*(.+)'
            
            if ($privateUrlMatch) {
                $url = $privateUrlMatch.Matches[0].Groups[1].Value.Trim()
                # Ensure the URL has the port if missing
                if ($url -notmatch ':6379$') {
                    $url = $url + ':6379'
                }
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
        & flyctl apps create $dbAppName --org personal 2>$null | Out-Host
        Write-Success "MariaDB app created: $dbAppName"
    } catch {
        Write-Info "MariaDB app might already exist, continuing..."
    }

    try {
        & flyctl volumes create mariadb_data --app $dbAppName --region $Region --size 10 -y | Out-Host
        Write-Success "MariaDB volume created."
    } catch {
        Write-Info "MariaDB volume might already exist, continuing..."
    }

    $dbRootPassword = New-RandomPassword 20
    Write-Info "Setting MariaDB root password secret..."
    try {
        & flyctl secrets set --app $dbAppName "MARIADB_ROOT_PASSWORD=$dbRootPassword" | Out-Host
        Write-Success "MariaDB password secret set."
    } catch {
        Write-Info "Failed to set MariaDB password secret, but continuing..."
    }

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
        & flyctl deploy --app $dbAppName --config $tempMariaTomlPath --ha=false | Out-Host
        Write-Success "MariaDB deployed successfully."
    } catch {
        Write-Info "MariaDB deployment might have had issues, but continuing..."
    } finally {
        Remove-Item $tempMariaTomlPath -ErrorAction SilentlyContinue
    }

    $dbInfo = [pscustomobject]@{ Host = "$dbAppName.internal"; Port = 3306; Password = $dbRootPassword }
    Write-Info "Returning database info: Host=$($dbInfo.Host), Port=$($dbInfo.Port)"
    return $dbInfo
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

        # Coerce to single PSCustomObject if any stray pipeline output slipped through
        if ($dbInfo -is [object[]]) {
            Write-Warn "dbInfo returned an array; selecting the PSCustomObject element."
            $dbInfo = $dbInfo | Where-Object { $_ -is [pscustomobject] } | Select-Object -First 1
        }

        # Validate dbInfo structure before use
        if ($null -eq $dbInfo) {
            Write-Err "Deploy-MariaDB returned null dbInfo"
            throw "Database info is null"
        }
        Write-Info ("dbInfo type: {0}" -f ($dbInfo.GetType().FullName))
        try {
            $null = $dbInfo.Host
            $null = $dbInfo.Port
            $null = $dbInfo.Password
            Write-Info "dbInfo values -> Host=$($dbInfo.Host), Port=$($dbInfo.Port)"
        } catch {
            Write-Err "dbInfo object missing expected properties Host/Port/Password. Raw:" 
            $dbInfo | Format-List * | Out-String | ForEach-Object { Write-Host $_ }
            throw
        }

        # Check for and create Redis instances if they don't exist
        Write-Info "Checking for existing Redis instances..."
        $redisListOutput = & flyctl redis list 2>$null
        $redisCacheName = "$AppName-redis-cache"
        $redisQueueName = "$AppName-redis-queue"

        # Check if cache instance exists
        $cacheExists = $false
        foreach ($line in $redisListOutput) {
            if ($line -like "*$redisCacheName*") {
                $cacheExists = $true
                break
            }
        }

        # Handle Redis cache
        if ($cacheExists) {
            Write-Info "Redis cache '$redisCacheName' already exists, getting URL..."
            $redisCacheUrl = Get-Redis-Url -redisName $redisCacheName
        } else {
            Write-Info "Creating Redis cache instance..."
            $cacheOutput = & flyctl redis create --name $redisCacheName --region $Region --org personal --no-replicas --enable-eviction 2>&1
            Write-Success "Redis cache created: $redisCacheName"
            # Extract URL from creation output
            $cacheUrlMatch = ($cacheOutput | Out-String) -match 'redis://[^\s]+'
            if ($cacheUrlMatch) {
                $redisCacheUrl = $matches[0]
                Write-Info "Extracted Redis cache URL from creation output"
            } else {
                $redisCacheUrl = Get-Redis-Url -redisName $redisCacheName
            }
        }

        # Check if queue instance exists
        $queueExists = $false
        foreach ($line in $redisListOutput) {
            if ($line -like "*$redisQueueName*") {
                $queueExists = $true
                break
            }
        }

        # Handle Redis queue
        if ($queueExists) {
            Write-Info "Redis queue '$redisQueueName' already exists, getting URL..."
            $redisQueueUrl = Get-Redis-Url -redisName $redisQueueName
        } else {
            Write-Info "Creating Redis queue instance..."
            $queueOutput = & flyctl redis create --name $redisQueueName --region $Region --org personal --no-replicas --disable-eviction 2>&1
            Write-Success "Redis queue created: $redisQueueName"
            # Extract URL from creation output
            $queueUrlMatch = ($queueOutput | Out-String) -match 'redis://[^\s]+'
            if ($queueUrlMatch) {
                $redisQueueUrl = $matches[0]
                Write-Info "Extracted Redis queue URL from creation output"
            } else {
                $redisQueueUrl = Get-Redis-Url -redisName $redisQueueName
            }
        }

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
