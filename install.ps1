#Requires -Version 5.1
<#
.SYNOPSIS
    NeuSlice Node Installer for Windows
.DESCRIPTION
    Sets up the NeuSlice agent, Bambuddy, and Watchtower on Windows using
    Docker Desktop. Requires only your Agent Token from the NeuSlice dashboard.
.EXAMPLE
    irm https://neuslice.com/install.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$COMPOSE_URL  = 'https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml'
$INSTALL_DIR  = if ($env:NEUSLICE_DIR) { $env:NEUSLICE_DIR } else { "$env:USERPROFILE\.neuslice" }

function Write-Header  { Write-Host "`n$args" -ForegroundColor White }
function Write-Success { Write-Host "  [OK] $args" -ForegroundColor Green }
function Write-Warn    { Write-Host "  [!]  $args" -ForegroundColor Yellow }
function Write-Fail    { Write-Host "  [X]  $args" -ForegroundColor Red; exit 1 }

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
    Write-Host "  Please install Docker Desktop for Windows and re-run this script:" -ForegroundColor Yellow
    Write-Host "  https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Make sure 'Use WSL 2 based engine' is enabled in Docker Desktop settings."
    Write-Host ""
    # Open the download page automatically
    Start-Process "https://www.docker.com/products/docker-desktop/"
    Write-Fail "Docker Desktop is required. Install it, start it, then re-run this script."
}

$dockerVersion = docker --version 2>&1
Write-Success "Docker found: $dockerVersion"

# Verify Docker is actually running (daemon responsive)
try {
    docker info *>&1 | Out-Null
} catch {
    Write-Fail "Docker is installed but not running. Open Docker Desktop and wait for it to start, then re-run."
}

# Check Docker Compose v2
try {
    docker compose version *>&1 | Out-Null
} catch {
    Write-Fail "Docker Compose v2 not found. Update Docker Desktop to the latest version."
}
Write-Success "Docker Compose v2 available"

# ── 2. Create install directory ───────────────────────────────────────────────

Write-Header "Setting up install directory..."

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
Set-Location $INSTALL_DIR
Write-Success "Install directory: $INSTALL_DIR"

# ── 3. Download docker-compose.yml ────────────────────────────────────────────

Write-Header "Downloading docker-compose.yml..."

try {
    # Force overwrite with no-cache headers to ensure we always get the latest version.
    Invoke-WebRequest -Uri $COMPOSE_URL -OutFile 'docker-compose.yml' -UseBasicParsing `
        -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
} catch {
    Write-Fail "Failed to download docker-compose.yml: $_"
}
Write-Success "docker-compose.yml downloaded ($(((Get-Item 'docker-compose.yml').LastWriteTime).ToString('HH:mm:ss')))"

# ── 4. Collect agent token ────────────────────────────────────────────────────

Write-Host ""
Write-Header "Agent Token"
Write-Host "  Get yours from the NeuSlice dashboard:" -ForegroundColor DarkGray
Write-Host "  Dashboard -> Your Printers -> Add Printer -> Copy Agent Token" -ForegroundColor DarkGray
Write-Host ""

$skipEnv = $false

if ((Test-Path '.env') -and (Select-String -Path '.env' -Pattern '^AGENT_TOKEN=' -Quiet)) {
    $existingToken = (Get-Content '.env' | Where-Object { $_ -match '^AGENT_TOKEN=' }) -replace '^AGENT_TOKEN=', ''
    Write-Warn "Existing .env found with AGENT_TOKEN set ($($existingToken.Substring(0, [Math]::Min(8, $existingToken.Length)))...)."
    $keep = Read-Host "  Keep existing configuration? [Y/n]"
    if ($keep -eq '' -or $keep -match '^[Yy]') {
        Write-Success "Keeping existing configuration"
        $skipEnv = $true
    }
}

if (-not $skipEnv) {
    $agentToken = ''
    while ($agentToken -eq '') {
        $agentToken = Read-Host "  Paste your Agent Token"
        if ($agentToken -eq '') {
            Write-Warn "Token cannot be empty."
        }
    }

    # Detect timezone in IANA format (Docker/Linux uses IANA, not Windows zone names)
    $tz = 'UTC'
    try {
        $winTz = (Get-TimeZone).Id
        # Common Windows -> IANA mappings for US zones most likely to be used
        $tzMap = @{
            'Eastern Standard Time'  = 'America/New_York'
            'Central Standard Time'  = 'America/Chicago'
            'Mountain Standard Time' = 'America/Denver'
            'Pacific Standard Time'  = 'America/Los_Angeles'
            'UTC'                    = 'UTC'
        }
        $tz = if ($tzMap.ContainsKey($winTz)) { $tzMap[$winTz] } else { 'UTC' }
    } catch { }

    # Write .env
    @"
# NeuSlice Node Configuration
# Generated by install.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# Your agent token from the NeuSlice dashboard (Settings -> Your Printers)
AGENT_TOKEN=$agentToken

# Timezone for log timestamps
TZ=$tz
"@ | Set-Content -Path '.env' -Encoding UTF8

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
Write-Host "  Your printer will appear online in the NeuSlice dashboard shortly."
Write-Host "  Updates are automatic - no action needed when NeuSlice releases new versions."
Write-Host ""
Write-Host "  Useful commands (run from $INSTALL_DIR):" -ForegroundColor DarkGray
Write-Host "    View logs:    docker compose logs -f neuslice-agent"
Write-Host "    Stop node:    docker compose down"
Write-Host "    Restart node: docker compose restart"
Write-Host ""
