#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIP,
    [string]$DomainName,
    [string]$AdminPassword,
    [string]$DokployToken
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

function Invoke-DokployAPI {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$Token,
        [string]$BaseUrl
    )
    
    # Different auth methods for cloud vs self-hosted
    $headers = @{
        "Content-Type" = "application/json"
        "Accept" = "application/json"
    }
    
    # For Dokploy Cloud, try different auth formats
    if ($BaseUrl -like "*app.dokploy.com*") {
        $headers["Authorization"] = "Bearer $Token"
        # Also try alternative auth header formats
        $headers["X-API-Key"] = $Token
    } else {
        $headers["Authorization"] = "Bearer $Token"
    }
    
    $apiUrl = if ($BaseUrl -like "*app.dokploy.com*") {
        "$BaseUrl/api/v1/$Endpoint"  # Cloud API version
    } else {
        "$BaseUrl/api/$Endpoint"     # Self-hosted API
    }
    
    $params = @{
        Uri = $apiUrl
        Method = $Method
        Headers = $headers
        TimeoutSec = 30
    }
    
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    
    Write-Info "API Call: $Method $apiUrl"
    
    try {
        $response = Invoke-RestMethod @params
        return $response
    } catch {
        $errorDetails = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $errorStream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($errorStream)
                $errorBody = $reader.ReadToEnd()
                $errorDetails += " | Response: $errorBody"
            } catch {
                # Ignore error reading response
            }
        }
        Write-Err "API call failed: $errorDetails"
        throw
    }
}

try {
    Write-Info "Starting automated ERPNext deployment to Dokploy..."
    
    # Generate admin password if not provided
    if (-not $AdminPassword) {
        $AdminPassword = New-RandomPassword 16
        Write-Info "Generated admin password: $AdminPassword"
    }

    # Set domain name and Dokploy URL
    $siteName = if ($DomainName) { $DomainName } else { "$ServerIP.traefik.me" }
    
    # Check if using Dokploy Cloud or self-hosted
    $isCloudDeployment = $true # Default to cloud
    $dokployUrl = if ($isCloudDeployment) { "https://app.dokploy.com" } else { "http://${ServerIP}:3000" }
    
    Write-Info "Deployment Configuration:"
    Write-Host "  Server IP:    $ServerIP" -ForegroundColor Yellow
    Write-Host "  Site Name:    $siteName" -ForegroundColor Yellow
    Write-Host "  Admin Pass:   $AdminPassword" -ForegroundColor Yellow
    Write-Host "  Dokploy URL:  $dokployUrl" -ForegroundColor Yellow
    Write-Host ""

    # Validate server IP and URL construction
    if (-not $ServerIP -or $ServerIP -eq "") {
        Write-Err "ServerIP parameter is required and cannot be empty"
        exit 1
    }
    
    # Validate URL construction
    try {
        $testUri = [System.Uri]::new($dokployUrl)
        Write-Info "Dokploy URL validated: $dokployUrl"
    } catch {
        Write-Err "Invalid Dokploy URL constructed: $dokployUrl"
        Write-Err "Error: $($_.Exception.Message)"
        exit 1
    }

    # Test connection to Dokploy
    Write-Info "Testing connection to Dokploy..."
    $testConnection = $false
    
    if ($isCloudDeployment) {
        Write-Info "Using Dokploy Cloud - testing API connectivity..."
        try {
            $testResponse = Invoke-WebRequest -Uri "https://app.dokploy.com" -Method GET -TimeoutSec 10 -UseBasicParsing
            if ($testResponse.StatusCode -eq 200) {
                $testConnection = $true
                Write-Success "Successfully connected to Dokploy Cloud"
            }
        } catch {
            Write-Warn "Cannot connect to Dokploy Cloud: $($_.Exception.Message)"
        }
    } else {
        Write-Info "Testing self-hosted Dokploy connection..."
        try {
            $testConnection = Test-NetConnection -ComputerName $ServerIP -Port 3000 -InformationLevel Quiet -WarningAction SilentlyContinue
            if (-not $testConnection) {
                Write-Warn "Cannot connect to Dokploy on $ServerIP:3000"
                Write-Info "Please ensure:"
                Write-Info "  1. Dokploy is installed and running"
                Write-Info "  2. Port 3000 is accessible (firewall/security groups)"
                Write-Info "  3. Server IP is correct: $ServerIP"
                Write-Info ""
                Write-Info "To install Dokploy:"
                Write-Info "  ssh root@$ServerIP"
                Write-Info "  curl -sSL https://dokploy.com/install.sh | sh"
            } else {
                Write-Success "Successfully connected to self-hosted Dokploy"
            }
        } catch {
            Write-Warn "Could not test connection: $($_.Exception.Message)"
        }
    }

    # Check if Dokploy token is provided or prompt for it
    if (-not $DokployToken) {
        Write-Info "To automate deployment, we need your Dokploy API token."
        Write-Info "Get it from: $dokployUrl/dashboard/settings/api-tokens"
        $DokployToken = Read-Host "Enter Dokploy API Token (or press Enter to skip automation)"
    }
    
    # Test API authentication first
    if ($DokployToken) {
        Write-Info "Testing API authentication..."
        try {
            $testAuth = Invoke-DokployAPI -Endpoint "auth/me" -Method "GET" -Token $DokployToken -BaseUrl $dokployUrl
            Write-Success "API authentication successful!"
        } catch {
            Write-Warn "API authentication failed. This might be due to:"
            Write-Info "  1. Invalid API token format"
            Write-Info "  2. Dokploy Cloud API structure differences"  
            Write-Info "  3. Token permissions or scope issues"
            Write-Info ""
            Write-Info "Let's proceed with manual deployment instructions instead."
            $DokployToken = $null
        }
    }

    # Skip automation if connection failed and no token provided
    if (-not $testConnection -and -not $DokployToken) {
        Write-Warn "Skipping automation due to connection issues. Will generate manual deployment files."
        $DokployToken = $null
    }

    # Read the updated docker-compose file from the repository
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $ScriptDir
    $ComposeFile = Join-Path $RepoRoot 'dokploy-docker-compose.yml'
    
    if (-not (Test-Path $ComposeFile)) {
        Write-Err "dokploy-docker-compose.yml not found. Please ensure the file exists in the repository root."
        exit 1
    }
    
    # Read the compose content and replace placeholders
    $composeContent = Get-Content $ComposeFile -Raw
    $composeContent = $composeContent -replace '100\.100\.0\.100\.traefik\.me', $siteName
    $composeContent = $composeContent -replace 'v3fS82sueJ84Ds9j', $AdminPassword

    # Save compose file
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $ScriptDir
    $ComposeFile = Join-Path $RepoRoot 'dokploy-docker-compose.yml'
    
    # If Dokploy token is provided, attempt automated deployment
    if ($DokployToken) {
        Write-Info "Attempting automated deployment via Dokploy API..."
        
        try {
            # Create project
            Write-Info "Creating project: erpnext-project"
            $projectBody = @{
                name = "erpnext-project"
                description = "ERPNext deployment via automated script"
            }
            $project = Invoke-DokployAPI -Endpoint "projects" -Method "POST" -Body $projectBody -Token $DokployToken -BaseUrl $dokployUrl
            $projectId = $project.projectId
            Write-Success "Project created with ID: $projectId"
            
            # Create compose service
            Write-Info "Creating compose service: erpnext-stack"
            $serviceBody = @{
                name = "erpnext-stack"
                description = "ERPNext full stack deployment"
                projectId = $projectId
                composeFile = $composeContent
                serviceType = "compose"
            }
            $service = Invoke-DokployAPI -Endpoint "compose" -Method "POST" -Body $serviceBody -Token $DokployToken -BaseUrl $dokployUrl
            $serviceId = $service.composeId
            Write-Success "Compose service created with ID: $serviceId"
            
            # Configure domain if provided
            if ($DomainName) {
                Write-Info "Configuring domain: $DomainName"
                $domainBody = @{
                    host = $DomainName
                    path = "/"
                    port = 80
                    https = $true
                    certificateType = "letsencrypt"
                    composeId = $serviceId
                }
                Invoke-DokployAPI -Endpoint "domains" -Method "POST" -Body $domainBody -Token $DokployToken -BaseUrl $dokployUrl
                Write-Success "Domain configured with SSL"
            }
            
            # Deploy the service
            Write-Info "Deploying ERPNext stack..."
            $deployBody = @{
                composeId = $serviceId
            }
            $deployment = Invoke-DokployAPI -Endpoint "compose/$serviceId/deploy" -Method "POST" -Body $deployBody -Token $DokployToken -BaseUrl $dokployUrl
            Write-Success "Deployment initiated!"
            
            # Monitor deployment status
            Write-Info "Monitoring deployment progress (this may take 5-10 minutes)..."
            $timeout = 600 # 10 minutes
            $elapsed = 0
            $interval = 30
            
            do {
                Start-Sleep $interval
                $elapsed += $interval
                
                try {
                    $status = Invoke-DokployAPI -Endpoint "compose/$serviceId" -Token $DokployToken -BaseUrl $dokployUrl
                    Write-Info "Deployment status: $($status.buildStatus) (${elapsed}s elapsed)"
                    
                    if ($status.buildStatus -eq "success") {
                        Write-Success "Deployment completed successfully!"
                        break
                    } elseif ($status.buildStatus -eq "error") {
                        Write-Err "Deployment failed. Check Dokploy logs for details."
                        break
                    }
                } catch {
                    Write-Warn "Could not check deployment status: $($_.Exception.Message)"
                }
                
            } while ($elapsed -lt $timeout)
            
            if ($elapsed -ge $timeout) {
                Write-Warn "Deployment monitoring timed out. Check Dokploy UI for status."
            }
            
        } catch {
            Write-Err "Automated deployment failed: $($_.Exception.Message)"
            Write-Info "Falling back to manual deployment instructions..."
        }
    } else {
        Write-Info "No API token provided. Skipping automated deployment."
    }
    
    # Save the customized compose file
    $composeContent | Set-Content -Path $ComposeFile -Encoding UTF8
    Write-Success "Updated dokploy-docker-compose.yml with your configuration"

    Write-Host ""
    Write-Success "ERPNext Dokploy deployment completed!"
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "Site Configuration:" -ForegroundColor Cyan
    Write-Host "  URL:            http://$siteName" -ForegroundColor Green
    Write-Host "  Username:       Administrator" -ForegroundColor Green  
    Write-Host "  Password:       $AdminPassword" -ForegroundColor Green
    Write-Host "  Dokploy UI:     $dokployUrl" -ForegroundColor Green
    Write-Host ""
    
    if ($DokployToken) {
        Write-Host "Automated Deployment:" -ForegroundColor Cyan
        Write-Host "✅ Project and service created automatically" -ForegroundColor Green
        Write-Host "✅ ERPNext stack deployed" -ForegroundColor Green
        if ($DomainName) {
            Write-Host "✅ SSL certificate configured for $DomainName" -ForegroundColor Green
        }
        Write-Host "" 
        Write-Host "Next Steps:" -ForegroundColor Yellow
        Write-Host "1. Wait 2-3 minutes for all services to start" -ForegroundColor White
        Write-Host "2. Access your ERPNext at: http://$siteName" -ForegroundColor White
        Write-Host "3. Monitor progress in Dokploy UI: $dokployUrl" -ForegroundColor White
    } else {
        Write-Host "Manual Deployment Required:" -ForegroundColor Yellow
        Write-Host "1. Access Dokploy UI: $dokployUrl" -ForegroundColor White
        Write-Host "2. Create new project: 'erpnext-project'" -ForegroundColor White
        Write-Host "3. Create compose service using dokploy-docker-compose.yml" -ForegroundColor White
        Write-Host "4. Deploy and wait 5-10 minutes" -ForegroundColor White
    }
    Write-Host "==========================================" -ForegroundColor Yellow

} catch {
    Write-Err $_.Exception.Message
    Write-Info "Setup failed. Check the error above and try again."
    exit 1
}
