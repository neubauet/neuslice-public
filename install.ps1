#Requires -Version 5.1
<#
.SYNOPSIS
    NeuSlice Node Installer for Windows
.DESCRIPTION
    Sets up the NeuSlice agent on Windows using Docker Desktop.
    Handles full registration automatically — no manual token copying required.
    If NEUSLICE_SETUP_CODE is set in the environment, uses it directly (one-liner mode).
    Otherwise, opens the NeuSlice dashboard so you can register your printer and get a code.
.EXAMPLE
    # One-liner from dashboard (recommended):
    $env:NEUSLICE_SETUP_CODE="ABC123"; irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.ps1 | iex
.EXAMPLE
    # Manual run:
    irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$COMPOSE_URL    = 'https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml'
$DASHBOARD_URL  = 'https://neuslice.com/nodes/register'
$BACKEND_URL    = 'https://printshare-backend-234aeo2mva-uc.a.run.app'
$CALLBACK_PORT  = 9876
$INSTALL_DIR    = if ($env:NEUSLICE_DIR) { $env:NEUSLICE_DIR } else { "$env:USERPROFILE\.neuslice" }

function Write-Header  { Write-Host "`n  $args" -ForegroundColor White }
function Write-Success { Write-Host "  [OK] $args" -ForegroundColor Green }
function Write-Warn    { Write-Host "  [!]  $args" -ForegroundColor Yellow }
function Write-Fail    { Write-Host "  [X]  $args" -ForegroundColor Red; exit 1 }
function Ask-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "  $Prompt $hint"
    if ($ans -eq '') { return $Default }
    return $ans -match '^[Yy]'
}

Write-Host ""
Write-Host "  NeuSlice Node Setup" -ForegroundColor Cyan -NoNewline
Write-Host " (Windows)"
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── 1. Check Docker Desktop ───────────────────────────────────────────────────

Write-Header "Checking Docker..."

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Warn "Docker not found."
    Write-Host ""
    Write-Host "  Please install Docker Desktop for Windows:" -ForegroundColor Yellow
    Write-Host "  https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
    Write-Host "  Make sure 'Use WSL 2 based engine' is enabled in Docker Desktop settings."
    Write-Host ""
    Start-Process "https://www.docker.com/products/docker-desktop/"
    Write-Fail "Install Docker Desktop, start it, then re-run this script."
}
Write-Success "Docker found: $(docker --version)"

try { docker info *>&1 | Out-Null }
catch { Write-Fail "Docker is installed but not running. Open Docker Desktop and wait for it to start, then re-run." }

try { docker compose version *>&1 | Out-Null }
catch { Write-Fail "Docker Compose v2 not found. Update Docker Desktop to the latest version." }
Write-Success "Docker Compose v2 available"

# ── 2. Create install directory ───────────────────────────────────────────────

Write-Header "Setting up install directory..."
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
Set-Location $INSTALL_DIR
Write-Success "Install directory: $INSTALL_DIR"

# ── 3. Download docker-compose.yml ────────────────────────────────────────────

Write-Header "Downloading docker-compose.yml..."
try {
    $bustUrl = "${COMPOSE_URL}?t=$(Get-Date -UFormat %s)"
    Invoke-WebRequest -Uri $bustUrl -OutFile 'docker-compose.yml' -UseBasicParsing `
        -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
} catch {
    Write-Fail "Failed to download docker-compose.yml: $_"
}
Write-Success "docker-compose.yml downloaded"

# ── 4. Configuration ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ── Setup ──────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$skipEnv = $false
if ((Test-Path '.env') -and (Select-String -Path '.env' -Pattern '^NEUSLICE_TOKEN=' -Quiet)) {
    $existingToken = (Get-Content '.env' | Where-Object { $_ -match '^NEUSLICE_TOKEN=' }) -replace '^NEUSLICE_TOKEN=', ''
    Write-Warn "Existing .env found (token: $($existingToken.Substring(0, [Math]::Min(8, $existingToken.Length)))...)."
    if (Ask-YesNo "Keep existing configuration?") {
        Write-Success "Keeping existing configuration"
        $skipEnv = $true
    }
}

if (-not $skipEnv) {

    # ── Get setup code (auto from env var, or via local callback) ─────────────
    $setupCode = $env:NEUSLICE_SETUP_CODE

    if (-not $setupCode) {
        Write-Host ""
        Write-Host "  We'll open the NeuSlice dashboard in your browser." -ForegroundColor DarkGray
        Write-Host "  Fill in your printer details there and click 'Register'." -ForegroundColor DarkGray
        Write-Host "  The installer will finish automatically — no copying required." -ForegroundColor DarkGray
        Write-Host ""

        # Start local HTTP listener on $CALLBACK_PORT
        Write-Header "Starting local setup listener on port $CALLBACK_PORT..."

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:${CALLBACK_PORT}/")
        try {
            $listener.Start()
        } catch {
            Write-Fail "Could not bind to port ${CALLBACK_PORT}. Check if another process is using it: netstat -ano | findstr :${CALLBACK_PORT}"
        }
        Write-Success "Listener ready"

        # Open dashboard
        Write-Host ""
        Write-Host "  Opening NeuSlice dashboard..." -ForegroundColor Cyan
        Start-Process $DASHBOARD_URL
        Write-Host "  Waiting for you to complete registration in your browser..." -ForegroundColor DarkGray
        Write-Host ""

        # Wait for browser callback (blocks until request arrives)
        $context  = $listener.GetContext()
        $rawUrl   = $context.Request.RawUrl   # /?code=XXXXXX
        $listener.Stop()

        # Parse code from query string
        $uri      = [System.Uri]("http://localhost${rawUrl}")
        $query    = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
        $setupCode = $query["code"]

        # Send success response to browser (closes the tab gracefully)
        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("OK")
        $context.Response.StatusCode        = 200
        $context.Response.ContentType       = "text/plain"
        $context.Response.ContentLength64   = $responseBytes.Length
        $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
        $context.Response.OutputStream.Close()

        if (-not $setupCode) {
            Write-Fail "Setup code not received from dashboard. Try running the one-liner from the dashboard instead."
        }
        Write-Success "Setup code received"
    } else {
        Write-Success "Using setup code from environment: $($setupCode.Substring(0,3))***"
    }

    # ── Exchange code for full config ─────────────────────────────────────────
    Write-Header "Exchanging setup code for configuration..."

    $exchangeUrl  = "${BACKEND_URL}/api/v1/setup/exchange"
    $exchangeBody = '{"code":"' + $setupCode.ToUpper() + '"}'

    try {
        $response = Invoke-RestMethod -Uri $exchangeUrl -Method Post -Body $exchangeBody `
            -ContentType 'application/json' -ErrorAction Stop
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) { Write-Fail "Setup code not found. It may have already been used or never existed." }
        if ($statusCode -eq 410) { Write-Fail "Setup code has expired (10-minute limit). Please register again from the dashboard." }
        if ($statusCode -eq 409) { Write-Fail "Setup code already used. Please register again from the dashboard." }
        Write-Fail "Exchange failed (HTTP $statusCode): $_"
    }

    $agentToken      = $response.agent_token
    $nodeId          = $response.node_id
    $hasBambuddy     = [bool]$response.has_bambuddy

    Write-Success "Configuration received for: $($response.display_name) ($($response.printer_model))"

    # ── Bambuddy ──────────────────────────────────────────────────────────────
    $bambuddyUrl    = 'http://localhost:8000'
    $composeProfile = ''

    if ($hasBambuddy) {
        Write-Host ""
        $customUrl = Read-Host "  Bambuddy URL (press Enter for http://localhost:8000)"
        if ($customUrl -ne '') { $bambuddyUrl = $customUrl.TrimEnd('/') }
        Write-Success "Using existing Bambuddy at $bambuddyUrl"
    } else {
        $composeProfile = 'bambuddy'
        $bambuddyUrl    = 'http://bambuddy:8000'
        Write-Success "Bambuddy will be installed as part of this setup"
        Write-Host "  After setup, open http://localhost:8000 to configure your printer in Bambuddy." -ForegroundColor DarkGray
    }

    # ── Timezone ──────────────────────────────────────────────────────────────
    $tz = 'UTC'
    try {
        $tzMap = @{
            'Eastern Standard Time'  = 'America/New_York'
            'Central Standard Time'  = 'America/Chicago'
            'Mountain Standard Time' = 'America/Denver'
            'Pacific Standard Time'  = 'America/Los_Angeles'
            'UTC'                    = 'UTC'
        }
        $winTz = (Get-TimeZone).Id
        $tz = if ($tzMap.ContainsKey($winTz)) { $tzMap[$winTz] } else { 'UTC' }
    } catch { }

    # ── Write .env ────────────────────────────────────────────────────────────
    $envContent = @"
# NeuSlice Node Configuration
# Generated by install.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# Agent credentials (auto-configured — do not share)
NEUSLICE_TOKEN=$agentToken
NEUSLICE_NODE_ID=$nodeId

# Bambuddy connection URL
BAMBUDDY_BASE_URL=$bambuddyUrl

# Timezone for log timestamps
TZ=$tz
"@

    if ($composeProfile -ne '') {
        $envContent += "`n# Enable Bambuddy container (managed by NeuSlice)"
        $envContent += "`nCOMPOSE_PROFILES=$composeProfile"
    }

    $envContent | Set-Content -Path '.env' -Encoding UTF8
    Write-Success ".env written"
}

# ── 5. Pull images and start ──────────────────────────────────────────────────

Write-Host ""
Write-Header "Pulling Docker images (this may take a minute on first run)..."
docker compose pull

Write-Host ""
Write-Header "Starting NeuSlice node..."
docker compose up -d

# ── 6. Done ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ✓ NeuSlice node is running!" -ForegroundColor Green
Write-Host ""

$profile = ''
if (Test-Path '.env') {
    $profileLine = Get-Content '.env' | Where-Object { $_ -match '^COMPOSE_PROFILES=' }
    if ($profileLine) { $profile = $profileLine -replace '^COMPOSE_PROFILES=', '' }
}
if ($profile -match 'bambuddy') {
    Write-Host "  Next step: open http://localhost:8000 in your browser to add your printer to Bambuddy." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  Your printer will appear online in the NeuSlice dashboard shortly."
Write-Host "  Updates are automatic — no action needed when NeuSlice releases new versions."
Write-Host ""
Write-Host "  Useful commands (run from $INSTALL_DIR):" -ForegroundColor DarkGray
Write-Host "    View logs:    docker compose logs -f neuslice-agent"
Write-Host "    Stop node:    docker compose down"
Write-Host "    Restart node: docker compose restart"
Write-Host ""
