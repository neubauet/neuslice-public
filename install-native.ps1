#Requires -Version 5.1
<#
.SYNOPSIS
    NeuSlice Node Installer for Windows - NATIVE (no Docker).
.DESCRIPTION
    Sets up the NeuSlice agent as a native Windows service (WinSW) with a bundled Node
    runtime - NO Docker Desktop. On Windows the native agent reaches the Bambuddy HTTP
    endpoint AND each LAN Moonraker directly (host networking), which the container path
    could not do. Registration is identical to the Docker installer (setup-code exchange).

    Self-update: the native agent uses Velopack (spec Phase 4 / 3.5). Until the signed
    release feed is live (cert-followup), updates are a manual re-run of this installer;
    the service itself runs and prints/serves normally in the meantime.

    Requires an ELEVATED PowerShell (registering a Windows service needs admin).
.PARAMETER AgentSource
    Where to get the agent code. A local path (dev/self-host) or a .zip URL. Empty =
    auto: the repo's ./neuslice-agent if this script runs from the source tree, else the
    public mirror.
.EXAMPLE
    # One-liner from the dashboard (customer):
    $env:NEUSLICE_SETUP_CODE="ABC123"; irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/install-native.ps1 | iex
.EXAMPLE
    # From a local checkout (validate on your own box, no mirror needed):
    ./install-native.ps1 -AgentSource .\neuslice-agent
#>
[CmdletBinding()]
param(
    [string]$AgentSource = '',
    [string]$SetupCode   = $env:NEUSLICE_SETUP_CODE   # carried across self-elevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Pinned provisioning sources (bump + re-test when updating) -----------------
$NODE_VERSION          = 'v20.18.0'                                          # Node LTS (agent needs >=18: fetch, AbortSignal.timeout)
$NODE_URL              = "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-win-x64.zip"
$WINSW_URL             = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
$MIRROR_AGENT_ZIP      = 'https://raw.githubusercontent.com/neubauet/neuslice-public/main/neuslice-agent-native.zip'

$DASHBOARD_URL         = 'https://neuslice.com/nodes/register'
$BACKEND_URL           = 'https://printshare-backend-234aeo2mva-uc.a.run.app'
$CALLBACK_PORT         = 9876
$BAMBUDDY_PORT         = 8000
$BAMBUDDY_READY_TIMEOUT = 60
$SERVICE_ID            = 'neuslice-agent'
$INSTALL_DIR           = if ($env:NEUSLICE_DIR) { $env:NEUSLICE_DIR } else { "$env:USERPROFILE\.neuslice" }
$AGENT_DIR             = Join-Path $INSTALL_DIR 'agent'
$RUNTIME_DIR           = Join-Path $INSTALL_DIR 'runtime'

function Write-Header  { Write-Host "`n  $args" -ForegroundColor White }
function Write-Success { Write-Host "  [OK] $args" -ForegroundColor Green }
function Write-Warn    { Write-Host "  [!]  $args" -ForegroundColor Yellow }
function Write-Fail    { $script:CleanFail = $true; Write-Host "  [X]  $args" -ForegroundColor Red; exit 1 }
function Write-Info    { Write-Host "  $args" -ForegroundColor Cyan }
function Write-Dim     { Write-Host "  $args" -ForegroundColor DarkGray }

# -- Transcript + failure trap (same diagnostics contract as install.ps1) -------
$script:CleanFail = $false
if (-not (Test-Path $INSTALL_DIR)) { New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null }
$LOG_FILE = if ($env:NEUSLICE_LOG) { $env:NEUSLICE_LOG } else { Join-Path $INSTALL_DIR 'install-native.log' }
try { Start-Transcript -Path $LOG_FILE -Append | Out-Null } catch { }
trap {
    if (-not $script:CleanFail) {
        Write-Host ""
        Write-Host "  [X]  Install failed at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
        if ($_.InvocationInfo.Line) { Write-Host ("        command: " + $_.InvocationInfo.Line.Trim()) -ForegroundColor Red }
        Write-Host ("        " + $_.Exception.Message) -ForegroundColor Red
        Write-Host "        full transcript: $LOG_FILE" -ForegroundColor DarkGray
        Write-Host "        (safe to share - credentials go to the .env, never the console)" -ForegroundColor DarkGray
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
function Ask-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "  $Prompt $hint"
    if ($ans -eq '') { return $Default }
    return $ans -match '^[Yy]'
}

Write-Host ""
Write-Host "  NeuSlice Node Setup" -ForegroundColor Cyan -NoNewline
Write-Host " (Windows, native - no Docker)"
Write-Host "  ------------------------------------------" -ForegroundColor DarkGray

# -- 1. Elevation (service registration needs admin) - self-elevate if needed ---
Write-Header "Checking prerequisites..."
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        Write-Fail "Registering the Windows service needs admin, and self-elevation only works from a saved .ps1 (not a pasted one-liner). Re-open PowerShell as Administrator and re-run."
    }
    Write-Warn "Not elevated - relaunching as Administrator (accept the UAC prompt; a new window opens)..."
    $relArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($AgentSource) { $relArgs += @('-AgentSource', $AgentSource) }
    if ($SetupCode)   { $relArgs += @('-SetupCode', $SetupCode) }   # carry the code across the UAC boundary
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $relArgs -Verb RunAs }
    catch { Write-Fail "Elevation was declined. Re-open PowerShell as Administrator and re-run." }
    exit 0
}
Write-Success "Running elevated"

# -- 2. Provision the Node runtime + WinSW (no Docker) --------------------------
New-Item -ItemType Directory -Force -Path $INSTALL_DIR, $RUNTIME_DIR | Out-Null

$nodeExe = Join-Path $RUNTIME_DIR "node-$NODE_VERSION-win-x64\node.exe"
if (-not (Test-Path $nodeExe)) {
    Write-Header "Downloading Node.js $NODE_VERSION (bundled runtime)..."
    $nodeZip = Join-Path $INSTALL_DIR 'node.zip'
    Invoke-WebRequest -Uri $NODE_URL -OutFile $nodeZip -UseBasicParsing
    Expand-Archive -Path $nodeZip -DestinationPath $RUNTIME_DIR -Force
    Remove-Item $nodeZip -Force
}
if (-not (Test-Path $nodeExe)) { Write-Fail "Node runtime not found after extract - check $NODE_URL" }
$npmCli = Join-Path (Split-Path $nodeExe) 'node_modules\npm\bin\npm-cli.js'
Write-Success "Node runtime: $(& $nodeExe --version)"

$winswExe = Join-Path $INSTALL_DIR "$SERVICE_ID.exe"
if (-not (Test-Path $winswExe)) {
    Write-Header "Downloading the service wrapper (WinSW)..."
    Invoke-WebRequest -Uri $WINSW_URL -OutFile $winswExe -UseBasicParsing
}
Write-Success "Service wrapper ready"

# -- 3. Get the agent code (local checkout or mirror) + install prod deps --------
Write-Header "Fetching the agent..."
if (-not $AgentSource) {
    $localGuess = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'neuslice-agent' } else { '' }
    $AgentSource = if ($localGuess -and (Test-Path $localGuess)) { $localGuess } else { $MIRROR_AGENT_ZIP }
}

if (Test-Path $AgentSource -PathType Container) {
    # Local checkout: copy just what the agent needs to run.
    if (Test-Path $AGENT_DIR) { Remove-Item $AGENT_DIR -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $AGENT_DIR | Out-Null
    Copy-Item (Join-Path $AgentSource 'src') (Join-Path $AGENT_DIR 'src') -Recurse
    foreach ($f in 'package.json', 'package-lock.json') {
        $src = Join-Path $AgentSource $f
        if (Test-Path $src) { Copy-Item $src $AGENT_DIR }
    }
    Write-Success "Agent copied from $AgentSource"
} else {
    # Mirror / URL: download the zip and extract the agent root.
    $agentZip = Join-Path $INSTALL_DIR 'agent.zip'
    Invoke-WebRequest -Uri $AgentSource -OutFile $agentZip -UseBasicParsing
    if (Test-Path $AGENT_DIR) { Remove-Item $AGENT_DIR -Recurse -Force }
    $tmp = Join-Path $INSTALL_DIR 'agent-unzip'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $agentZip -DestinationPath $tmp -Force
    Remove-Item $agentZip -Force
    # The zip may wrap the agent in a top folder; find the dir that has src\index.js.
    $root = Get-ChildItem $tmp -Recurse -Filter 'index.js' | Where-Object { $_.FullName -match '\\src\\index\.js$' } | Select-Object -First 1
    if (-not $root) { Write-Fail "Downloaded agent zip has no src\index.js" }
    Move-Item (Split-Path (Split-Path $root.FullName)) $AGENT_DIR
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Success "Agent downloaded"
}

Write-Header "Installing agent dependencies (production only)..."
Push-Location $AGENT_DIR
try {
    # npm writes deprecation warnings to stderr; under ErrorActionPreference=Stop a 2>&1
    # merge wraps those as a TERMINATING error even though npm exits 0. Run the native
    # call under Continue and gate on the real exit code instead.
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $nodeExe $npmCli install --omit=dev --no-audit --no-fund 2>&1 | Out-Null
    $npmCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($npmCode -ne 0) { throw "npm install exited $npmCode" }
} finally { Pop-Location }
Write-Success "Dependencies installed"

# -- 4. Configuration (registration + Bambuddy) ---------------------------------
$envFile = Join-Path $AGENT_DIR '.env'
Write-Host ""
Write-Host "  -- Setup ----------------------------------" -ForegroundColor DarkGray

$skipEnv = $false
if ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern '^NEUSLICE_TOKEN=' -Quiet)) {
    $existingToken = (Get-Content $envFile | Where-Object { $_ -match '^NEUSLICE_TOKEN=' }) -replace '^NEUSLICE_TOKEN=', ''
    Write-Warn "Existing .env found (token: $($existingToken.Substring(0, [Math]::Min(8, $existingToken.Length)))...)."
    if (Ask-YesNo "Keep existing configuration?") { Write-Success "Keeping existing configuration"; $skipEnv = $true }
}

if (-not $skipEnv) {
    # -- Setup code (env one-liner, or local callback listener) -----------------
    $setupCode = $SetupCode
    if (-not $setupCode) {
        Write-Host ""
        Write-Dim "We'll open the NeuSlice dashboard. Fill in your printer details and click 'Register'."
        Write-Dim "The installer finishes automatically - no copying required."
        Write-Header "Starting local setup listener on port $CALLBACK_PORT..."
        Add-Type -AssemblyName System.Web
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:${CALLBACK_PORT}/")
        try { $listener.Start() } catch { Write-Fail "Could not bind port ${CALLBACK_PORT}. In use? netstat -ano | findstr :${CALLBACK_PORT}" }
        Write-Success "Listener ready"
        Write-Info "Opening NeuSlice dashboard..."
        Start-Process $DASHBOARD_URL
        Write-Dim "Waiting for you to complete registration in your browser (Ctrl+C to cancel)..."
        # Async accept so Ctrl+C works (a blocking GetContext() ignores it), with a
        # timeout, and so a stray hit with no ?code= doesn't kill the install - we answer
        # it and keep waiting for the real callback.
        $deadline = (Get-Date).AddMinutes(10)
        while (-not $setupCode) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(250)) {
                if ((Get-Date) -gt $deadline) {
                    $listener.Stop()
                    Write-Fail "Timed out waiting for registration. Grab the setup code from the dashboard and re-run with:  `$env:NEUSLICE_SETUP_CODE='CODE'; ./install-native.ps1"
                }
            }
            $context   = $task.Result
            $uri       = [System.Uri]("http://localhost" + $context.Request.RawUrl)
            $setupCode = [System.Web.HttpUtility]::ParseQueryString($uri.Query)["code"]
            $msg       = if ($setupCode) { "OK - registration received. You can close this tab." } else { "NeuSlice installer is waiting for a setup code..." }
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
            $context.Response.StatusCode = 200; $context.Response.ContentType = "text/plain"
            $context.Response.ContentLength64 = $responseBytes.Length
            $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
            $context.Response.OutputStream.Close()
        }
        $listener.Stop()
        Write-Success "Setup code received"
    } else {
        Write-Success "Using provided setup code: $($setupCode.Substring(0,3))***"
    }

    Write-Header "Exchanging setup code for configuration..."
    try {
        $exchangeResponse = Invoke-RestMethod -Uri "${BACKEND_URL}/api/v1/setup/exchange" -Method Post `
            -Body ('{"code":"' + $setupCode.ToUpper() + '"}') -ContentType 'application/json' -ErrorAction Stop
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

    # -- Bambuddy - native: localhost works (no host.docker.internal) -----------
    $bambuddyUrl = ''; $bambuApiKey = ''; $bambuUsername = ''; $bambuPassword = ''; $bambuPrinterId = ''; $isPathA = $false
    if (-not $hasBambuddy) {
        $isPathA = $true
        $bambuddyUrl = "http://127.0.0.1:${BAMBUDDY_PORT}"
        Write-Success "Bambuddy: native (Path A)"
        Write-Dim "Install Bambuddy's native Windows service and open http://localhost:${BAMBUDDY_PORT} to add your printer."
        Write-Dim "The agent will detect it automatically once it's up."
    } else {
        Write-Host ""
        Write-Info "You indicated Bambuddy is already installed."
        $defaultBambuddyUrl = "http://127.0.0.1:${BAMBUDDY_PORT}"
        Write-Dim "(Native agent reaches Bambuddy on localhost directly. Change only if it's on another machine.)"
        $customUrl = Read-Host "  Bambuddy URL (press Enter for $defaultBambuddyUrl)"
        $bambuddyUrl = if ($customUrl -ne '') { $customUrl.TrimEnd('/') } else { $defaultBambuddyUrl }
        Write-Host ""
        Write-Dim "Create an API key in Bambuddy: Settings -> API Keys (Read Status, Manage Queue, Control Printer, Manage Library)."
        while ($bambuApiKey -eq '') { $bambuApiKey = Read-Host "  Bambuddy API Key"; if ($bambuApiKey -eq '') { Write-Warn "API key cannot be empty." } }
        Write-Host ""
        Write-Dim "Bambuddy also needs your web-UI username + password to upload print files."
        while ($bambuUsername -eq '') { $bambuUsername = Read-Host "  Bambuddy Username"; if ($bambuUsername -eq '') { Write-Warn "Username cannot be empty." } }
        while ($bambuPassword -eq '') {
            $bambuPassword = Read-Host "  Bambuddy Password" -AsSecureString | ForEach-Object {
                [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
            if ($bambuPassword -eq '') { Write-Warn "Password cannot be empty." }
        }
        Write-Header "Fetching printers from Bambuddy..."
        try {
            $printers = @(Invoke-RestMethod -Uri "${bambuddyUrl}/api/v1/printers/" -Headers @{ 'X-API-Key' = $bambuApiKey } -Method Get -MaximumRedirection 5 -ErrorAction Stop)
        } catch { Write-Fail "Could not reach Bambuddy at ${bambuddyUrl}: $_" }
        if ($printers.Count -eq 0) { Write-Fail "No printers in Bambuddy at ${bambuddyUrl}. Add one first, then re-run." }
        elseif ($printers.Count -eq 1) { $bambuPrinterId = $printers[0].id; Write-Success "Auto-selected: $($printers[0].name) - ID $bambuPrinterId" }
        else {
            Write-Host ""; Write-Host "  Multiple printers found. Which one is this node?" -ForegroundColor White; Write-Host ""
            for ($i = 0; $i -lt $printers.Count; $i++) { Write-Host "    $($i + 1)) $($printers[$i].name)  ($($printers[$i].model))  - ID $($printers[$i].id)" }
            while ($true) {
                $raw = Read-Host "  Enter number (1-$($printers.Count))"
                if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le $printers.Count) { $bambuPrinterId = $printers[[int]$raw - 1].id; Write-Success "Selected ID $bambuPrinterId"; break }
                Write-Warn "Please enter a number between 1 and $($printers.Count)."
            }
        }
    }

    # -- Timezone ---------------------------------------------------------------
    $tz = 'UTC'
    try {
        $tzMap = @{ 'Eastern Standard Time' = 'America/New_York'; 'Central Standard Time' = 'America/Chicago'
                    'Mountain Standard Time' = 'America/Denver'; 'Pacific Standard Time' = 'America/Los_Angeles'; 'UTC' = 'UTC' }
        $winTz = (Get-TimeZone).Id
        $tz = if ($tzMap.ContainsKey($winTz)) { $tzMap[$winTz] } else { 'UTC' }
    } catch { }

    # -- Write .env (native: AGENT_RUNTIME=native, localhost Bambuddy, no Docker/Watchtower) --
    $envLines = @(
        "# NeuSlice Node Configuration (native)",
        "# Generated by install-native.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
        "",
        "# Agent credentials (auto-configured - do not share)",
        "NEUSLICE_TOKEN=$agentToken",
        "NEUSLICE_NODE_ID=$nodeId",
        "NEUSLICE_API_URL=$BACKEND_URL",
        "",
        "# Native Windows service runtime (WinSW + Velopack self-update)",
        "AGENT_RUNTIME=native",
        "",
        "# Bambuddy connection (agent reads BAMBUDDY_BASE_URL or BAMBU_HOST)",
        "BAMBUDDY_BASE_URL=$bambuddyUrl",
        "",
        "TZ=$tz"
    )
    if ($bambuApiKey -ne '') {
        $envLines += @("", "# Bambuddy API credentials (existing install)", "BAMBU_API_KEY=$bambuApiKey", "BAMBU_USERNAME=$bambuUsername", "BAMBU_PASSWORD=$bambuPassword")
    }
    if ($bambuPrinterId -ne '') { $envLines += "BAMBU_PRINTER_ID=$bambuPrinterId" }
    $envLines -join "`n" | Set-Content -Path $envFile -Encoding UTF8
    Write-Success ".env written"
}

# -- 5. WinSW service definition + install --------------------------------------
Write-Header "Installing the Windows service..."
$xml = @"
<service>
  <id>$SERVICE_ID</id>
  <name>NeuSlice Printer Agent</name>
  <description>Runs this host's NeuSlice printer agent as a native Windows service (no Docker).</description>
  <executable>$nodeExe</executable>
  <arguments>src\index.js</arguments>
  <workingdirectory>$AGENT_DIR</workingdirectory>
  <env name="AGENT_RUNTIME" value="native"/>
  <!-- Graceful stop: run service_stop.js, which writes the stop sentinel the agent
       watches, so a service stop drains instead of aborting a print (Procedure B2). -->
  <stopexecutable>$nodeExe</stopexecutable>
  <stoparguments>src\service_stop.js</stoparguments>
  <stoptimeout>35 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec"/>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>8</keepFiles></log>
</service>
"@
$xml | Set-Content -Path (Join-Path $INSTALL_DIR "$SERVICE_ID.xml") -Encoding UTF8

# Reinstall cleanly if a prior service exists. (Continue: WinSW may write to stderr,
# which a *>&1 merge under Stop would turn into a terminating error.)
if (Get-Service -Name $SERVICE_ID -ErrorAction SilentlyContinue) {
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $winswExe stop   *>&1 | Out-Null
    & $winswExe uninstall *>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
    Start-Sleep -Seconds 2
}
& $winswExe install
if ($LASTEXITCODE -ne 0) { Write-Fail "Service install failed (WinSW exit $LASTEXITCODE) - see $LOG_FILE" }
& $winswExe start
Write-Success "Service '$SERVICE_ID' installed and started"

# -- 6. Path A: wait for native Bambuddy, then pick printer + restart -----------
$isPathA = $false
if (Test-Path $envFile) {
    $bl = Get-Content $envFile | Where-Object { $_ -match '^BAMBUDDY_BASE_URL=' }
    $hasPrinter = Select-String -Path $envFile -Pattern '^BAMBU_PRINTER_ID=' -Quiet
    if ($bl -match '127\.0\.0\.1|localhost' -and -not $hasPrinter) { $isPathA = $true }
}
if ($isPathA) {
    Write-Header "Waiting for Bambuddy at http://localhost:${BAMBUDDY_PORT}..."
    $elapsed = 0; $ready = $false
    while ($elapsed -lt $BAMBUDDY_READY_TIMEOUT) {
        try { $null = Invoke-RestMethod -Uri "http://localhost:${BAMBUDDY_PORT}/api/v1/printers/" -Method Get -TimeoutSec 2 -ErrorAction Stop; $ready = $true; break } catch { }
        Start-Sleep -Seconds 3; $elapsed += 3
    }
    if (-not $ready) {
        Write-Warn "Bambuddy didn't respond within ${BAMBUDDY_READY_TIMEOUT}s. Open http://localhost:${BAMBUDDY_PORT}, add your printer, then: Restart-Service $SERVICE_ID"
    } else {
        try { $printers = @(Invoke-RestMethod -Uri "http://localhost:${BAMBUDDY_PORT}/api/v1/printers/" -Method Get -ErrorAction Stop) } catch { $printers = @() }
        if ($printers.Count -ge 1) {
            $pid2 = $printers[0].id
            Add-Content -Path $envFile -Value "BAMBU_PRINTER_ID=$pid2"
            Restart-Service $SERVICE_ID -ErrorAction SilentlyContinue
            Write-Success "Selected printer $($printers[0].name) (ID $pid2) - service restarted"
        } else {
            Write-Warn "No printers in Bambuddy yet. Add one at http://localhost:${BAMBUDDY_PORT}, then: Restart-Service $SERVICE_ID"
        }
    }
}

# -- 7. Done --------------------------------------------------------------------
Write-Host ""
Write-Host "  NeuSlice node is running (native - no Docker)." -ForegroundColor Green
Write-Host ""
Write-Host "  Your printer will appear online in the NeuSlice dashboard shortly."
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor DarkGray
Write-Host "    Status:  Get-Service $SERVICE_ID"
Write-Host "    Logs:    Get-Content '$INSTALL_DIR\$SERVICE_ID.out.log' -Tail 40 -Wait"
Write-Host "    Stop:    Stop-Service $SERVICE_ID     (drains gracefully)"
Write-Host "    Start:   Start-Service $SERVICE_ID"
Write-Host ""
try { Stop-Transcript | Out-Null } catch { }
