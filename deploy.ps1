# PowerShell script to automate the deployment of Frappe ERPNext to Fly.io

# --- Configuration ---
# This script reads configuration directly from your fly.toml file.
# Make sure to set the 'app' and 'primary_region' in fly.toml.

$Org = "personal"          # Change this to your Fly.io organization slug
$PgSize = 10                  # Development Postgres size in GB
$VolumeSize = 10             # Site volume size in GB

# --- Script ---

# Function to read a value from the TOML file
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

Write-Host "Starting ERPNext deployment to Fly.io..." -ForegroundColor Green

# Step 1: Read configuration from fly.toml
$AppName = Get-TomlValue -FilePath ".\fly.toml" -Key "app"
$Region = Get-TomlValue -FilePath ".\fly.toml" -Key "primary_region"

if (-not $AppName) {
    Write-Host "Error: Could not find 'app' name in fly.toml. Please set it." -ForegroundColor Red
    exit 1
}
if (-not $Region) {
    Write-Host "Error: Could not find 'primary_region' in fly.toml. Please set it." -ForegroundColor Red
    exit 1
}

Write-Host "Using configuration from fly.toml: App='$AppName', Region='$Region'" -ForegroundColor Yellow

# Step 2: Log in to Fly.io (opens a browser)
fly auth login

# Step 3: Create the main application if it doesn't exist
if (-not (fly apps list | Select-String -Pattern "^$AppName\s")) {
    Write-Host "Creating main app: $AppName..." -ForegroundColor Cyan
    fly apps create $AppName --org $Org
} else {
    Write-Host "Main app '$AppName' already exists."
}

# Step 4: Create and attach Postgres database
$PgAppName = "$AppName-db"
if (-not (fly apps list | Select-String -Pattern "^$PgAppName\s")) {
    Write-Host "Creating Postgres database: $PgAppName..." -ForegroundColor Cyan
    fly pg create --name $PgAppName --org $Org --region $Region --vm-size "shared-cpu-1x" --volume-size $PgSize --initial-cluster-size 1
} else {
    Write-Host "Postgres app '$PgAppName' already exists."
}
Write-Host "Attaching Postgres to $AppName..." -ForegroundColor Cyan
fly pg attach $PgAppName -a $AppName

# Step 5: Create and attach Redis instance
$RedisAppName = "$AppName-redis"
if (-not (fly redis list | Select-String -Pattern "^$RedisAppName\s")) {
    Write-Host "Creating Redis instance: $RedisAppName..." -ForegroundColor Cyan
    fly redis create --name $RedisAppName --org $Org --no-replicas
} else {
    Write-Host "Redis instance '$RedisAppName' already exists."
}
Write-Host "Attaching Redis to $AppName..." -ForegroundColor Cyan

# Get Redis URL and set it as secrets for cache and queue
Write-Host "Setting Redis secrets..."
$RedisStatusOutput = fly redis status $RedisAppName
$RedisUrl = ($RedisStatusOutput | Select-String -Pattern "Private URL" | ForEach-Object { $_.ToString().Split(':')[1].Trim() + ':' + $_.ToString().Split(':')[2].Trim() }).Trim()

if ($RedisUrl) {
    # The output from the command includes the protocol, so we need to handle it carefully.
    $RedisUrl = "redis:" + $RedisUrl
    # Frappe uses different logical databases on the same Redis instance
    $RedisCacheUrl = "$($RedisUrl)/0"
    $RedisQueueUrl = "$($RedisUrl)/1"
    fly secrets set "REDIS_CACHE_URL=$RedisCacheUrl" "REDIS_QUEUE_URL=$RedisQueueUrl" --app $AppName
    Write-Host "Redis secrets for cache and queue have been set."
} else {
    Write-Host "Could not retrieve Redis URL for '$RedisAppName'. Check if the Redis instance exists and you have access." -ForegroundColor Red
    exit 1
}

# Step 6: Create volumes if they don't exist
if (-not (fly volumes list -a $AppName | Select-String -Pattern "^sites_volume")) {
    Write-Host "Creating 'sites_volume'..." -ForegroundColor Cyan
    fly volumes create sites_volume --size $VolumeSize --app $AppName --region $Region --yes
} else {
    Write-Host "'sites_volume' already exists."
}

# Step 7: Deploy the application
Write-Host "Deploying the application! This may take several minutes..." -ForegroundColor Green
fly deploy -a $AppName

Write-Host "Deployment complete!" -ForegroundColor Green
