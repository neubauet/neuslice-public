#Requires -Version 5.1
<#
.SYNOPSIS
    NeuSlice printer discovery + pre-install check (Windows).
.DESCRIPTION
    Finds 3D printers on this network and prints the exact address to paste into
    the NeuSlice dashboard, then (in check mode) proves every endpoint the
    installer needs before it needs them.

    Run this BEFORE install-native.ps1. Unlike the installer it needs NO admin
    rights and changes nothing on the machine - it only reads the network.

    Node is provided automatically: an already-installed NeuSlice runtime is
    reused, otherwise a system Node >= 18, otherwise a portable one is fetched
    to a temp folder and removed afterwards.
.PARAMETER Mode
    'discover' (default) to find printers, or 'check' to pre-flight endpoints.
.PARAMETER Printer
    check mode only: also test this printer address, e.g. http://192.168.1.100:7125
.PARAMETER Json
    Emit machine-readable JSON instead of the human table.
.PARAMETER NoOpen
    Don't open the browser afterwards. By default a successful discover opens the
    NeuSlice registration page with the printers it found ready to select.
.EXAMPLE
    # Customer one-liner (no admin, no install):
    irm https://raw.githubusercontent.com/neubauet/neuslice-public/main/check.ps1 | iex
.EXAMPLE
    .\check.ps1 check -Printer http://192.168.1.100:7125
#>
[CmdletBinding()]
param(
    [ValidateSet('discover', 'check')]
    [string]$Mode    = 'discover',
    [string]$Printer = '',
    [switch]$Json,
    [switch]$NoOpen,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Extra = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pinned to match install-native.ps1 so a machine that already ran the installer
# reuses that runtime instead of downloading a second copy.
$NODE_VERSION = 'v24.19.0'
$NODE_URL     = "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-win-x64.zip"
$MIRROR_BASE  = 'https://raw.githubusercontent.com/neubauet/neuslice-public/main'
$DASHBOARD_URL = if ($env:NEUSLICE_DASHBOARD_URL) { $env:NEUSLICE_DASHBOARD_URL } else { 'https://neuslice.com/nodes/register' }
$INSTALL_DIR  = if ($env:NEUSLICE_DIR) { $env:NEUSLICE_DIR } else { "$env:USERPROFILE\.neuslice" }

function Write-Success { Write-Host "  [OK] $args" -ForegroundColor Green }
function Write-Warn    { Write-Host "  [!]  $args" -ForegroundColor Yellow }
function Write-Fail    { Write-Host "  [X]  $args" -ForegroundColor Red; exit 1 }
function Write-Dim     { Write-Host "  $args" -ForegroundColor DarkGray }

# Anything we create goes here and is removed on the way out. This script is
# explicitly a no-footprint tool - people run it before they have decided to
# install anything.
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "neuslice-check-$PID"
$script:CleanupTemp = $false

function Cleanup {
    if ($script:CleanupTemp -and (Test-Path $TempRoot)) {
        try { Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# -- Locate a usable Node -------------------------------------------------------
function Resolve-Node {
    # 1. A runtime the NeuSlice installer already put down.
    $bundled = Join-Path $INSTALL_DIR "runtime\node-$NODE_VERSION-win-x64\node.exe"
    if (Test-Path $bundled) { Write-Dim "Using the NeuSlice runtime already on this machine."; return $bundled }

    # Any other bundled version, in case the installer's pin has moved on.
    $anyBundled = Get-ChildItem -Path (Join-Path $INSTALL_DIR 'runtime') -Filter 'node.exe' -Recurse -ErrorAction SilentlyContinue |
                  Select-Object -First 1
    if ($anyBundled) { Write-Dim "Using the NeuSlice runtime already on this machine."; return $anyBundled.FullName }

    # 2. A system Node, if it is new enough for fetch + AbortSignal.timeout.
    $sysNode = Get-Command node -ErrorAction SilentlyContinue
    if ($sysNode) {
        try {
            $v = (& $sysNode.Source --version) 2>$null
            if ($v -match '^v(\d+)\.' -and [int]$Matches[1] -ge 18) {
                Write-Dim "Using system Node $v."
                return $sysNode.Source
            }
            Write-Warn "System Node $v is too old (need v18+); fetching a portable copy."
        } catch { }
    }

    # 3. Fetch a portable one. ~30 MB, deleted when this script exits.
    Write-Dim "Downloading a temporary Node runtime (~30 MB, removed when this finishes)..."
    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
    $script:CleanupTemp = $true
    $zip = Join-Path $TempRoot 'node.zip'
    try {
        Invoke-WebRequest -Uri $NODE_URL -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $TempRoot -Force
        Remove-Item $zip -Force
    } catch {
        Write-Fail "Could not download the Node runtime: $($_.Exception.Message)"
    }
    $exe = Join-Path $TempRoot "node-$NODE_VERSION-win-x64\node.exe"
    if (-not (Test-Path $exe)) { Write-Fail "Node download completed but node.exe is missing." }
    return $exe
}

# -- Locate discover.js ---------------------------------------------------------
function Resolve-Script {
    # Running from the source tree.
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot 'neuslice-agent\src\discover.js'
        if (Test-Path $local) { return $local }
    }
    # An installed agent already has it.
    $installed = Join-Path $INSTALL_DIR 'agent\src\discover.js'
    if (Test-Path $installed) { return $installed }

    # Otherwise pull the single file from the public mirror. It has no imports
    # beyond node: builtins, so one file is the whole tool.
    if (-not (Test-Path $TempRoot)) { New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null }
    $script:CleanupTemp = $true
    $dest = Join-Path $TempRoot 'discover.js'
    try { Invoke-WebRequest -Uri "$MIRROR_BASE/discover.js" -OutFile $dest -UseBasicParsing }
    catch { Write-Fail "Could not download discover.js: $($_.Exception.Message)" }
    return $dest
}

try {
    Write-Host ""
    Write-Host "  NeuSlice Network Check" -ForegroundColor Cyan -NoNewline
    Write-Host " (read-only - no admin, nothing installed)"

    $nodeExe    = Resolve-Node
    $scriptPath = Resolve-Script

    $argList = @($scriptPath, $Mode)
    if ($Json)                { $argList += '--json' }
    if ($Printer -ne '')      { $argList += "--printer=$Printer" }

    # Capture the dashboard payload from the SAME sweep that prints the table -
    # running discovery twice would double a 25-second wait for no reason.
    $foundFile = ''
    if ($Mode -eq 'discover' -and -not $Json -and -not $NoOpen) {
        if (-not (Test-Path $TempRoot)) { New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null }
        $script:CleanupTemp = $true
        $foundFile = Join-Path $TempRoot 'found.txt'
        $argList += "--found-out=$foundFile"
    }
    if ($Extra -and $Extra.Count -gt 0) { $argList += $Extra }

    & $nodeExe @argList
    $code = $LASTEXITCODE

    # The payoff: hand the results to the browser so the owner picks their
    # printer from a list instead of transcribing an IP into the form.
    if ($foundFile -ne '' -and (Test-Path $foundFile)) {
        $payload = (Get-Content $foundFile -Raw).Trim()
        if ($payload -match '^[A-Za-z0-9_-]+$') {
            Write-Host ""
            Write-Success "Opening NeuSlice with these printers ready to select..."
            Write-Dim "If your browser doesn't open, paste this address:"
            Write-Dim "$DASHBOARD_URL`?found=$payload"
            try { Start-Process "$DASHBOARD_URL`?found=$payload" } catch {
                Write-Warn "Could not open a browser automatically - copy the address above."
            }
        }
    }

    # 3 = discovery ran fine but found nothing. Worth a nudge, not an error dump.
    if ($code -eq 3) {
        Write-Warn "Nothing found. If the printer is on Wi-Fi, check it is on the same network as this PC"
        Write-Dim  "(a 5 GHz / guest network is the usual culprit), then re-run."
    }
    exit $code
}
finally {
    Cleanup
}
