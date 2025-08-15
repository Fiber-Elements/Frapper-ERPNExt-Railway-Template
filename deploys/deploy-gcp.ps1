#Requires -Modules GoogleCloud

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $false)]
    [string]$Region = 'europe-west1',

    [Parameter(Mandatory = $false)]
    [string]$Zone = 'europe-west1-b',

    [Parameter(Mandatory = $false)]
    [string]$InstanceBaseName = "erpnext-$(Get-Random -Minimum 1000 -Maximum 9999)",

    [Parameter(Mandatory = $false)]
    [string]$MachineType = 'e2-standard-4',

    [Parameter(Mandatory = $false)]
    [string]$BootDiskSize = '50GB',

    [Parameter(Mandatory = $false)]
    [string]$SqlTier = 'db-n1-standard-2', # MariaDB

    [Parameter(Mandatory = $false)]
    [string]$RedisTier = 'BASIC', # BASIC or STANDARD_HA

    [Parameter(Mandatory = $false)]
    [string]$RedisSizeGb = '1'
)

# Set project config
Write-Host "Setting gcloud config to project '$ProjectId'"
& gcloud config set project $ProjectId

# --- Resource Names ---
$VmName = "$($InstanceBaseName)-vm"
$SqlInstanceName = "$($InstanceBaseName)-db"
$RedisInstanceName = "$($InstanceBaseName)-redis"
$FirewallRuleName = "$($InstanceBaseName)-allow-http"
$DbRootPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
$AdminPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })

# --- Enable APIs ---
Write-Host "Enabling required GCP APIs (compute, sqladmin, redis, servicenetworking)..."
& gcloud services enable compute.googleapis.com `
    sqladmin.googleapis.com `
    redis.googleapis.com `
    servicenetworking.googleapis.com

# --- Networking for Private Services (Cloud SQL / Redis) ---
Write-Host "Configuring private service access networking..."
# Check for existing peering; create if not found
$peering = & gcloud services vpc-peerings list --service=servicenetworking.googleapis.com --network=default --format="value(peering)" | Where-Object { $_ -eq 'servicenetworking-googleapis-com' }
if (-not $peering) {
    & gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=16 --network=default
    & gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --ranges=google-managed-services-default --network=default
} else {
    Write-Host "VPC peering 'servicenetworking-googleapis-com' already exists."
}

# --- Provision Cloud SQL (MariaDB) ---
Write-Host "Provisioning Cloud SQL for MariaDB instance '$SqlInstanceName'... (This may take 10-15 minutes)"
# For MariaDB compatibility, Cloud SQL uses MYSQL_8_0 as the database version flag.
& gcloud sql instances create $SqlInstanceName --database-version=MYSQL_8_0 --tier=$SqlTier --region=$Region --root-password=$DbRootPassword --network=default --no-assign-ip
# Wait for instance to be RUNNABLE
Write-Host "Waiting for Cloud SQL instance to be ready..."
while ($true) {
    $status = (& gcloud sql instances describe $SqlInstanceName --format="value(state)")
    if ($status -eq 'RUNNABLE') {
        Write-Host "Cloud SQL instance is RUNNABLE."
        break
    }
    if ($status -eq 'FAILED' -or $status -eq 'SUSPENDED') {
        Write-Error "Cloud SQL instance entered a failed state: $status"
        exit 1
    }
    Write-Host "Current status: $status. Waiting 30 seconds..."
    Start-Sleep -Seconds 30
}
$SqlIpAddress = (& gcloud sql instances describe $SqlInstanceName --format="value(ipAddresses.privateIpAddress)")
Write-Host "Cloud SQL instance created with private IP: $SqlIpAddress"

# --- Provision Memorystore (Redis) ---
Write-Host "Provisioning Memorystore for Redis instance '$RedisInstanceName'... (This may take 5-10 minutes)"
& gcloud redis instances create $RedisInstanceName --size=$RedisSizeGb --region=$Region --tier=$RedisTier --redis-version=redis_7_2 --network=default
# Wait for Redis instance to be READY
Write-Host "Waiting for Memorystore instance to be ready..."
while ($true) {
    $status = (& gcloud redis instances describe $RedisInstanceName --region=$Region --format="value(state)")
    if ($status -eq 'READY') {
        Write-Host "Memorystore instance is READY."
        break
    }
    if ($status -like '*FAILED*' -or $status -eq 'SUSPENDING') {
        Write-Error "Memorystore instance entered a failed state: $status"
        exit 1
    }
    Write-Host "Current status: $status. Waiting 15 seconds..."
    Start-Sleep -Seconds 15
}
$RedisIpAddress = (& gcloud redis instances describe $RedisInstanceName --region=$Region --format="value(host)")
Write-Host "Memorystore instance created with host: $RedisIpAddress"

# --- Create Firewall Rule ---
Write-Host "Creating firewall rule '$FirewallRuleName' to allow HTTP traffic..."
if (-not (& gcloud compute firewall-rules list --filter="name=$FirewallRuleName" --format="value(name)")) {
    & gcloud compute firewall-rules create $FirewallRuleName --allow=tcp:80 --network=default --source-ranges=0.0.0.0/0 --target-tags=http-server
} else {
    Write-Host "Firewall rule '$FirewallRuleName' already exists."
}

# --- Create Compute Engine VM ---
$StartupScriptPath = "$PSScriptRoot/../scripts/gcp-startup.sh"
if (-not (Test-Path $StartupScriptPath)) {
    Write-Error "Startup script not found at '$StartupScriptPath'"
    exit 1
}

Write-Host "Creating Compute Engine VM '$VmName'..."
$Metadata = @(
    "ADMIN_PASSWORD=$AdminPassword",
    "DB_HOST=$SqlIpAddress",
    "DB_PORT=3306",
    "DB_PASSWORD=$DbRootPassword",
    "REDIS_CACHE=redis://$($RedisIpAddress):6379/0",
    "REDIS_QUEUE=redis://$($RedisIpAddress):6379/1",
    "REDIS_SOCKETIO=redis://$($RedisIpAddress):6379/2"
)

& gcloud compute instances create $VmName `
    --zone=$Zone `
    --machine-type=$MachineType `
    --image-family=ubuntu-2204-lts `
    --image-project=ubuntu-os-cloud `
    --boot-disk-size=$BootDiskSize `
    --tags=http-server `
    --metadata-from-file=startup-script=$StartupScriptPath `
    --metadata=$($Metadata -join ',')

# --- Output Summary ---
$VmExternalIp = (& gcloud compute instances describe $VmName --zone=$Zone --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

Write-Host "`n--- Deployment Summary ---"
Write-Host "Project ID:         $ProjectId"
Write-Host "Instance Base Name:   $InstanceBaseName"
Write-Host "VM Name:              $VmName ($VmExternalIp)"
Write-Host "Cloud SQL Instance:   $SqlInstanceName ($SqlIpAddress)"
Write-Host "Memorystore Instance: $RedisInstanceName ($RedisIpAddress)"
Write-Host "`nERPNext will be available at: http://$VmExternalIp"
Write-Host "Username:             Administrator"
Write-Host "Password:             $AdminPassword"
Write-Host "(It may take 10-20 minutes for the startup script to complete and the site to be ready.)"

# --- Stream Startup Logs ---
Write-Host "`n--- Streaming startup script logs from '$VmName' ---"
Write-Host "The script will continue to run in the background on the VM."
Write-Host "You can monitor its progress here. Press Ctrl+C to stop streaming at any time."
try {
    & gcloud compute instances tail-serial-port-output $VmName --zone=$Zone --port=1
} catch {
    Write-Warning "Stopped streaming logs. The startup script continues to run on the VM."
}
