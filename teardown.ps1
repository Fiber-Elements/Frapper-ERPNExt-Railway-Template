# teardown.ps1 - Destroys all Fly.io resources for the application.

# Function to get a value from a TOML file (like fly.toml)
function Get-TomlValue($FilePath, $Key) {
    try {
        $Line = Get-Content $FilePath | Select-String -Pattern "^\s*$Key\s*=" | Select-Object -First 1
        if ($Line -ne $null) {
            return $Line.ToString().Split('=')[1].Trim().Trim('"', "'")
        }
    } catch {
        # Ignore errors if file not found, etc.
    }
    return $null
}

# --- Main Script ---

# Read app name from fly.toml to know what to destroy
$AppName = Get-TomlValue -FilePath "fly.toml" -Key "app"

if (-not $AppName) {
    Write-Host "Error: Could not read app name from fly.toml. Aborting teardown." -ForegroundColor Red
    exit 1
}

Write-Host "This script will permanently destroy all Fly.io resources for the app: '$AppName'" -ForegroundColor Yellow
Write-Host "This includes the app, the Postgres database, the Redis instance, and any associated volumes." -ForegroundColor Yellow

# Confirmation prompt
$Confirmation = Read-Host "Are you sure you want to continue? (y/n)"
if ($Confirmation -ne 'y') {
    Write-Host "Teardown aborted by user." -ForegroundColor Green
    exit 0
}

# Define resource names based on the app name
$PostgresAppName = "$AppName-db"
$RedisAppName = "$AppName-redis"

# Destroy the resources
Write-Host "Destroying Fly App: '$AppName'..." -ForegroundColor Cyan
fly apps destroy $AppName --yes

Write-Host "Destroying Postgres Database: '$PostgresAppName'..." -ForegroundColor Cyan
fly apps destroy $PostgresAppName --yes

Write-Host "Destroying Redis Instance: '$RedisAppName'..." -ForegroundColor Cyan
fly redis destroy $RedisAppName --yes

Write-Host "Teardown complete. All specified resources have been destroyed." -ForegroundColor Green
