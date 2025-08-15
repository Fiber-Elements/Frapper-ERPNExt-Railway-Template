[CmdletBinding()]
param(
  [string]$ProjectName = "frappe-erpnext",
  [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Command($name) {
  try { & $name --version *> $null; return $true } catch { return $false }
}

function New-RandomPassword([int]$length = 20) {
  $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789_-'
  $arr = $chars.ToCharArray()
  -join ((1..$length) | ForEach-Object { $arr[(Get-Random -Minimum 0 -Maximum $arr.Length)] })
}

try {
  Write-Info 'Preflight checks'
  if (-not (Test-Command 'railway')) { throw 'Railway CLI is not installed or not on PATH. Please install it and try again.' }

  $user = (railway whoami) 2>$null
  if (-not $user) { throw 'You are not logged into Railway. Please run `railway login` and try again.' }
  Write-Info "Logged in as $user"

  $AdminPassword = if ($PSBoundParameters.ContainsKey('Credential')) {
    $Credential.GetNetworkCredential().Password
  } else {
    Write-Info 'No password provided. Generating a strong random password.'
    New-RandomPassword 20
  }

  Write-Info "Creating Railway project '$ProjectName'..."
  $project = railway project create --name $ProjectName -d | ConvertFrom-Json
  railway link $project.id

  Write-Info 'Setting up services and environment variables...'
  railway up -d

  $siteName = "${ProjectName}.up.railway.app"
  railway variables set `
    FRAPPE_SITE_NAME_HEADER=$siteName `
    ADMIN_PASSWORD=$AdminPassword `
    LETSENCRYPT_EMAIL="$user"

  Write-Info 'Starting deployment...'
  railway up

  Write-Host ""
  Write-Host 'Deployment complete!' -ForegroundColor Green
  Write-Host '----------------------------------------'
  Write-Host "URL:        https://$siteName"
  Write-Host 'Username:   Administrator'
  Write-Host "Password:   $AdminPassword"

} catch {
  Write-Err $_.Exception.Message
  exit 1
}
