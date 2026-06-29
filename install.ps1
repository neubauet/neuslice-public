#Requires -Version 5.1
<#
.SYNOPSIS
    NeuSlice Node Installer for Windows
.DESCRIPTION
    Sets up the NeuSlice agent on Windows using Docker Desktop.
    Handles full registration automatically — no manual token copying required.
    If NEUSLICE_SETUP_CODE is set in the environment, uses it directly (one-liner mode).
    Otherwise opens the NeuSlice dashboard so you can register and get a code.

    Bambuddy handling:
      Path A (fresh install) — Bambuddy is spun up as part of this stack.
                               No API key required. Agent auto-detects printer.
      Path B (existing)      — Prompts for Bambuddy URL + API key, fetches
                               the printer list, and lets you pick if there are multiple.
.EXAMPLE
    # One-liner from dashboard (recommended):
    $env:NEUSLICE_SETUP_CODE="ABC123"; irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.ps1 | iex
.EXAMPLE
    # Manual run:
    irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$COMPOSE_URL           = 'https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml'
$DASHBOARD_URL         = 'https://neuslice.com/nodes/register'
$BACKEND_URL           = 'https://printshare-backend-234aeo2mva-uc.a.run.app'
$CALLBACK_PORT         = 9876
$BAMBUDDY_PORT         = 8000
$BAMBUDDY_READY_TIMEOUT = 60   # seconds
$INSTALL_DIR           = if ($env:NEUSLICE_DIR) { $env:NEUSLICE_DIR } else { "$env:USERPROFILE\.neuslice" }

function Write-Header  { Write-Host "`n  $args" -ForegroundColor White }
function Write-Success { Write-Host "  [OK] $args" -ForegroundColor Green }
function Write-Warn    { Write-Host "  [!]  $args" -ForegroundColor Yellow }
function Write-Fail    { Write-Host "  [X]  $args" -ForegroundColor Red; exit 1 }
function Write-Info    { Write-Host "  $args" -ForegroundColor Cyan }
function Write-Dim     { Write-Host "  $args" -ForegroundColor DarkGray }
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
    Write-Host "  Please install Docker Desktop for Windows:" -ForegroundColor Yellow
    Write-Host "  https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
    Start-Process "https://www.docker.com/products/docker-desktop/"
    Write-Fail "Install Docker Desktop, start it, then re-run this script."
}
Write-Success "Docker found: $(docker --version)"

try { docker info *>&1 | Out-Null }
catch { Write-Fail "Docker is not running. Open Docker Desktop and wait for it to start, then re-run." }

try { docker compose version *>&1 | Out-Null }
catch { Write-Fail "Docker Compose v2 not found. Update Docker Desktop to the latest version." }
Write-Success "Docker Compose v2 available"

# ── 2. Install directory ──────────────────────────────────────────────────────

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

    # ── Get NeuSlice setup code ───────────────────────────────────────────────
    $setupCode = $env:NEUSLICE_SETUP_CODE

    if (-not $setupCode) {
        Write-Host ""
        Write-Dim "We'll open the NeuSlice dashboard in your browser."
        Write-Dim "Fill in your printer details and click 'Register'."
        Write-Dim "The installer will finish automatically — no copying required."
        Write-Host ""

        Write-Header "Starting local setup listener on port $CALLBACK_PORT..."

        # Add System.Web for QueryString parsing
        Add-Type -AssemblyName System.Web

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:${CALLBACK_PORT}/")
        try {
            $listener.Start()
        } catch {
            Write-Fail "Could not bind to port ${CALLBACK_PORT}. Check if another process is using it: netstat -ano | findstr :${CALLBACK_PORT}"
        }
        Write-Success "Listener ready"

        Write-Host ""
        Write-Info "Opening NeuSlice dashboard..."
        Start-Process $DASHBOARD_URL
        Write-Dim "Waiting for you to complete registration in your browser..."
        Write-Host ""

        $context  = $listener.GetContext()
        $rawUrl   = $context.Request.RawUrl
        $listener.Stop()

        $uri      = [System.Uri]("http://localhost${rawUrl}")
        $query    = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
        $setupCode = $query["code"]

        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("OK")
        $context.Response.StatusCode      = 200
        $context.Response.ContentType     = "text/plain"
        $context.Response.ContentLength64 = $responseBytes.Length
        $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
        $context.Response.OutputStream.Close()

        if (-not $setupCode) {
            Write-Fail "Setup code not received. Try the one-liner from the dashboard instead."
        }
        Write-Success "Setup code received"
    } else {
        Write-Success "Using setup code from environment: $($setupCode.Substring(0,3))***"
    }

    # ── Exchange code for node config ─────────────────────────────────────────
    Write-Header "Exchanging setup code for configuration..."

    $exchangeBody = '{"code":"' + $setupCode.ToUpper() + '"}'
    try {
        $exchangeResponse = Invoke-RestMethod `
            -Uri "${BACKEND_URL}/api/v1/setup/exchange" `
            -Method Post `
            -Body $exchangeBody `
            -ContentType 'application/json' `
            -ErrorAction Stop
    } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -eq 404) { Write-Fail "Setup code not found. It may already have been used." }
        if ($sc -eq 410) { Write-Fail "Setup code expired (10-minute limit). Register again from the dashboard." }
        if ($sc -eq 409) { Write-Fail "Setup code already used. Register again from the dashboard." }
        Write-Fail "Exchange failed (HTTP $sc): $_"
    }

    $agentToken   = $exchangeResponse.agent_token
    $nodeId       = $exchangeResponse.node_id
    $displayName  = $exchangeResponse.display_name
    $printerModel = $exchangeResponse.printer_model
    $hasBambuddy  = [bool]$exchangeResponse.has_bambuddy

    Write-Success "Configuration received for: $displayName ($printerModel)"

    # ── Bambuddy — Path A vs Path B ───────────────────────────────────────────

    $composeProfile  = ''
    $bambuddyUrl     = ''
    $bambuApiKey     = ''
    $bambuPrinterId  = ''

    if (-not $hasBambuddy) {

        # ── PATH A: Fresh Bambuddy install ────────────────────────────────────
        $composeProfile = 'bambuddy'
        $bambuddyUrl    = "http://bambuddy:${BAMBUDDY_PORT}"
        Write-Success "Bambuddy will be installed as part of this setup (Path A)"
        Write-Dim "After setup, open http://localhost:${BAMBUDDY_PORT} to add your printer."
        Write-Dim "The agent will detect your printer automatically."

    } else {

        # ── PATH B: Existing Bambuddy install ─────────────────────────────────
        Write-Host ""
        Write-Info "You indicated Bambuddy is already installed."
        Write-Host ""

        # URL
        $customUrl = Read-Host "  Bambuddy URL (press Enter for http://localhost:${BAMBUDDY_PORT})"
        $bambuddyUrl = if ($customUrl -ne '') { $customUrl.TrimEnd('/') } else { "http://localhost:${BAMBUDDY_PORT}" }

        # API key
        Write-Host ""
        Write-Dim "Create an API key in Bambuddy: Settings → API Keys → Create API Key"
        Write-Dim "Required permissions: Read Status, Manage Queue, Control Printer, Manage Library"
        Write-Host ""
        $bambuApiKey = ''
        while ($bambuApiKey -eq '') {
            $bambuApiKey = Read-Host "  Bambuddy API Key"
            if ($bambuApiKey -eq '') { Write-Warn "API key cannot be empty." }
        }

        # Fetch printer list
        Write-Host ""
        Write-Header "Fetching printers from Bambuddy..."

        try {
            $printersResponse = Invoke-RestMethod `
                -Uri "${bambuddyUrl}/api/v1/printers" `
                -Headers @{ 'X-API-Key' = $bambuApiKey } `
                -Method Get `
                -ErrorAction Stop
        } catch {
            Write-Fail "Could not reach Bambuddy at ${bambuddyUrl}. Check the URL and that Bambuddy is running."
        }

        $printers = @($printersResponse)   # ensure array even for single item
        $count    = $printers.Count

        if ($count -eq 0) {
            Write-Fail "No printers found in Bambuddy at ${bambuddyUrl}. Add your printer in Bambuddy first, then re-run."
        } elseif ($count -eq 1) {
            $bambuPrinterId = $printers[0].id
            $pName          = $printers[0].name
            $pModel         = $printers[0].model
            Write-Success "Auto-selected: $pName ($pModel) — ID $bambuPrinterId"
        } else {
            # Multiple printers — interactive picker
            Write-Host ""
            Write-Host "  Multiple printers found. Which one is this node?" -ForegroundColor White
            Write-Host ""
            for ($i = 0; $i -lt $count; $i++) {
                $p = $printers[$i]
                Write-Host "    $($i + 1)) $($p.name)  ($($p.model))  — ID $($p.id)"
            }
            Write-Host ""

            while ($true) {
                $raw = Read-Host "  Enter number (1–$count)"
                if ($raw -match '^\d+$') {
                    $sel = [int]$raw
                    if ($sel -ge 1 -and $sel -le $count) {
                        $chosen         = $printers[$sel - 1]
                        $bambuPrinterId = $chosen.id
                        Write-Success "Selected: $($chosen.name) — ID $bambuPrinterId"
                        break
                    }
                }
                Write-Warn "Please enter a number between 1 and $count."
            }
        }
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
    $envLines = @(
        "# NeuSlice Node Configuration",
        "# Generated by install.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
        "",
        "# Agent credentials (auto-configured — do not share)",
        "NEUSLICE_TOKEN=$agentToken",
        "NEUSLICE_NODE_ID=$nodeId",
        "",
        "# Bambuddy connection",
        "BAMBUDDY_BASE_URL=$bambuddyUrl",
        "",
        "# Timezone for log timestamps",
        "TZ=$tz"
    )

    if ($bambuApiKey -ne '') {
        $envLines += ""
        $envLines += "# Bambuddy API credentials (Path B — existing install)"
        $envLines += "BAMBU_API_KEY=$bambuApiKey"
    }

    if ($bambuPrinterId -ne '') {
        $envLines += "BAMBU_PRINTER_ID=$bambuPrinterId"
    }

    if ($composeProfile -ne '') {
        $envLines += ""
        $envLines += "# Enable Bambuddy container (managed by NeuSlice)"
        $envLines += "COMPOSE_PROFILES=$composeProfile"
    }

    $envLines -join "`n" | Set-Content -Path '.env' -Encoding UTF8
    Write-Success ".env written"
}

# ── 5. Pull images and start ──────────────────────────────────────────────────

Write-Host ""
Write-Header "Pulling Docker images (this may take a minute on first run)..."
docker compose pull

Write-Host ""
Write-Header "Starting NeuSlice node..."
docker compose up -d

# ── 6. Path A: wait for Bambuddy, then pick printer ──────────────────────────

$isPathA = $false
if (Test-Path '.env') {
    $profileLine = Get-Content '.env' | Where-Object { $_ -match '^COMPOSE_PROFILES=' }
    if ($profileLine -match 'bambuddy') { $isPathA = $true }
}

if ($isPathA) {
    Write-Host ""
    Write-Header "Waiting for Bambuddy to start..."

    $bambuddyLocal = "http://localhost:${BAMBUDDY_PORT}"
    $elapsed = 0
    $ready   = $false

    while ($elapsed -lt $BAMBUDDY_READY_TIMEOUT) {
        try {
            $null = Invoke-RestMethod -Uri "${bambuddyLocal}/api/v1/printers" `
                -Method Get -TimeoutSec 2 -ErrorAction Stop
            $ready = $true
            break
        } catch { }
        Write-Host "  Waiting... (${elapsed}s)" -NoNewline
        Write-Host "`r" -NoNewline
        Start-Sleep -Seconds 3
        $elapsed += 3
    }

    Write-Host ""

    if (-not $ready) {
        Write-Warn "Bambuddy didn't respond within ${BAMBUDDY_READY_TIMEOUT}s."
        Write-Warn "Open http://localhost:${BAMBUDDY_PORT} to add your printer manually."
        Write-Warn "Then restart the agent: docker compose restart neuslice-agent"
    } else {
        try {
            $printers = @(Invoke-RestMethod -Uri "${bambuddyLocal}/api/v1/printers" `
                -Method Get -ErrorAction Stop)
        } catch {
            $printers = @()
        }

        $count = $printers.Count

        if ($count -eq 0) {
            Write-Host ""
            Write-Warn "No printers found in Bambuddy yet."
            Write-Info "Open http://localhost:${BAMBUDDY_PORT} to add your printer."
            Write-Dim "Once added, restart the agent: docker compose restart neuslice-agent"
        } elseif ($count -eq 1) {
            $pid2  = $printers[0].id
            $pName = $printers[0].name
            Add-Content -Path '.env' -Value "BAMBU_PRINTER_ID=$pid2"
            Write-Success "Auto-selected printer: $pName (ID $pid2) — written to .env"
            docker compose restart neuslice-agent *>&1 | Out-Null
            Write-Success "Agent restarted with printer selection"
        } else {
            Write-Host ""
            Write-Host "  Multiple printers found in Bambuddy. Which one is this node?" -ForegroundColor White
            Write-Host ""
            for ($i = 0; $i -lt $count; $i++) {
                $p = $printers[$i]
                Write-Host "    $($i + 1)) $($p.name)  ($($p.model))  — ID $($p.id)"
            }
            Write-Host ""

            while ($true) {
                $raw = Read-Host "  Enter number (1–$count)"
                if ($raw -match '^\d+$') {
                    $sel = [int]$raw
                    if ($sel -ge 1 -and $sel -le $count) {
                        $chosen = $printers[$sel - 1]
                        $pid2   = $chosen.id
                        Add-Content -Path '.env' -Value "BAMBU_PRINTER_ID=$pid2"
                        Write-Success "Selected: $($chosen.name) (ID $pid2) — written to .env"
                        docker compose restart neuslice-agent *>&1 | Out-Null
                        Write-Success "Agent restarted with printer selection"
                        break
                    }
                }
                Write-Warn "Please enter a number between 1 and $count."
            }
        }
    }
}

# ── 7. Done ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ✓ NeuSlice node is running!" -ForegroundColor Green
Write-Host ""

# Remind about Bambuddy setup if printer wasn't selected yet
$needsBambuddySetup = $false
if (Test-Path '.env') {
    $hasPrinterLine = Select-String -Path '.env' -Pattern '^BAMBU_PRINTER_ID=' -Quiet
    $hasProfile     = Select-String -Path '.env' -Pattern '^COMPOSE_PROFILES=bambuddy' -Quiet
    if ($hasProfile -and -not $hasPrinterLine) { $needsBambuddySetup = $true }
}
if ($needsBambuddySetup) {
    Write-Host "  Next step: open http://localhost:${BAMBUDDY_PORT} to add your printer to Bambuddy." -ForegroundColor Yellow
    Write-Dim "Then run: docker compose restart neuslice-agent"
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
