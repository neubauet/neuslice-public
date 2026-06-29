#!/usr/bin/env bash
# NeuSlice Node Installer — Mac / Linux
#
# One-liner from dashboard (recommended):
#   NEUSLICE_SETUP_CODE="ABC123" bash <(curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh)
#
# Manual run (opens dashboard in browser):
#   curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh | bash

set -euo pipefail

COMPOSE_URL="https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml"
DASHBOARD_URL="https://neuslice.com/nodes/register"
BACKEND_URL="https://printshare-backend-234aeo2mva-uc.a.run.app"
CALLBACK_PORT=9876
INSTALL_DIR="${NEUSLICE_DIR:-$HOME/.neuslice}"

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; GRAY="\033[90m"; RESET="\033[0m"

header()  { echo -e "\n  ${BOLD}$*${RESET}"; }
ok()      { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${RESET}  $*"; }
fail()    { echo -e "  ${RED}[X]${RESET}  $*" >&2; exit 1; }
dim()     { echo -e "  ${GRAY}$*${RESET}"; }

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint; [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    local ans
    read -rp "  $prompt $hint: " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy] ]]
}

echo ""
echo -e "  ${BOLD}${CYAN}NeuSlice Node Setup${RESET}"
echo -e "  ${GRAY}──────────────────────────────────────────${RESET}"
echo ""

# ── 1. Check Docker ───────────────────────────────────────────────────────────

header "Checking Docker..."

if ! command -v docker &>/dev/null; then
    warn "Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed"
else
    ok "Docker found: $(docker --version)"
fi

docker info &>/dev/null || fail "Docker is installed but not running. Start Docker and re-run."

docker compose version &>/dev/null || \
    fail "Docker Compose v2 required. Run: apt install docker-compose-plugin  or update Docker Desktop."
ok "Docker Compose v2 available"

# ── 2. Create install directory ───────────────────────────────────────────────

header "Setting up install directory..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
ok "Install directory: $INSTALL_DIR"

# ── 3. Download docker-compose.yml ────────────────────────────────────────────

header "Downloading docker-compose.yml..."
curl -fsSL --no-cache "${COMPOSE_URL}?t=$(date +%s)" -o docker-compose.yml
ok "docker-compose.yml downloaded"

# ── 4. Configuration ──────────────────────────────────────────────────────────

echo ""
echo -e "  ${GRAY}── Setup ──────────────────────────────────${RESET}"
echo ""

SKIP_ENV=false
if [ -f .env ] && grep -q "^NEUSLICE_TOKEN=" .env; then
    EXISTING_TOKEN=$(grep "^NEUSLICE_TOKEN=" .env | cut -d'=' -f2)
    warn "Existing .env found (token: ${EXISTING_TOKEN:0:8}...)."
    if ask_yn "Keep existing configuration?"; then
        ok "Keeping existing configuration"
        SKIP_ENV=true
    fi
fi

if [ "$SKIP_ENV" = false ]; then

    # ── Get setup code ────────────────────────────────────────────────────────
    SETUP_CODE="${NEUSLICE_SETUP_CODE:-}"

    if [ -z "$SETUP_CODE" ]; then
        echo ""
        dim "We'll open the NeuSlice dashboard in your browser."
        dim "Fill in your printer details and click 'Register'."
        dim "The installer will finish automatically — no copying required."
        echo ""

        # Pick a method to serve a single HTTP response
        # Prefer Python (available on macOS by default and most Linux)
        if command -v python3 &>/dev/null; then
            SERVE_METHOD="python3"
        elif command -v python &>/dev/null; then
            SERVE_METHOD="python"
        elif command -v nc &>/dev/null; then
            SERVE_METHOD="nc"
        else
            fail "No HTTP server available. Install Python 3 and re-run, or use the one-liner from the dashboard."
        fi

        header "Starting local setup listener on port $CALLBACK_PORT..."

        # Named pipe so we can capture output from background server
        PIPE_FILE=$(mktemp -u)
        mkfifo "$PIPE_FILE"

        CODE_RECEIVED=""

        if [ "$SERVE_METHOD" = "python3" ] || [ "$SERVE_METHOD" = "python" ]; then
            # Python one-shot server — reads one request, prints the code, exits
            $SERVE_METHOD - <<PYEOF &
SERVER_PID=$$
import socket, sys, os, signal

port = $CALLBACK_PORT
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', port))
s.listen(1)
conn, _ = s.accept()
data = conn.recv(4096).decode('utf-8', errors='replace')

# Parse code from GET request line: GET /?code=XXXXXX HTTP/1.1
code = ''
for line in data.splitlines():
    if line.startswith('GET '):
        parts = line.split(' ')
        if len(parts) >= 2:
            path = parts[1]
            if 'code=' in path:
                code = path.split('code=')[1].split('&')[0].strip()
    break

# Respond to browser (CORS so the fetch() from neuslice.com works)
response = (
    'HTTP/1.1 200 OK\r\n'
    'Access-Control-Allow-Origin: *\r\n'
    'Content-Type: text/plain\r\n'
    'Content-Length: 2\r\n'
    'Connection: close\r\n'
    '\r\n'
    'OK'
)
conn.sendall(response.encode())
conn.close()
s.close()

# Write code to the named pipe so parent can read it
with open('$PIPE_FILE', 'w') as f:
    f.write(code)
PYEOF
        else
            # Fallback: netcat (one-shot, GNU netcat style)
            {
                RESPONSE="HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
                REQUEST=$(echo -e "$RESPONSE" | nc -l -p "$CALLBACK_PORT" -q 1)
                CODE_LINE=$(echo "$REQUEST" | grep "^GET " | head -1)
                CODE=$(echo "$CODE_LINE" | sed 's/.*code=//;s/[& ].*//')
                echo "$CODE" > "$PIPE_FILE"
            } &
        fi

        SERVER_BG_PID=$!
        ok "Listener ready on port $CALLBACK_PORT"

        # Open dashboard in browser
        echo ""
        echo -e "  ${CYAN}Opening NeuSlice dashboard...${RESET}"
        if command -v xdg-open &>/dev/null; then
            xdg-open "$DASHBOARD_URL" &>/dev/null &
        elif command -v open &>/dev/null; then
            open "$DASHBOARD_URL"
        else
            echo -e "  ${YELLOW}Could not auto-open browser. Visit:${RESET} $DASHBOARD_URL"
        fi

        dim "Waiting for you to complete registration in your browser..."
        echo ""

        # Block until code arrives through the pipe
        SETUP_CODE=$(cat "$PIPE_FILE")
        rm -f "$PIPE_FILE"

        if [ -z "$SETUP_CODE" ]; then
            fail "Setup code not received. Try running the one-liner from the dashboard instead."
        fi
        ok "Setup code received"
    else
        ok "Using setup code from environment: ${SETUP_CODE:0:3}***"
    fi

    # ── Exchange code for full config ─────────────────────────────────────────
    header "Exchanging setup code for configuration..."

    EXCHANGE_RESPONSE=$(curl -fsSL -X POST \
        -H "Content-Type: application/json" \
        -d "{\"code\":\"$(echo "$SETUP_CODE" | tr '[:lower:]' '[:upper:]')\"}" \
        "${BACKEND_URL}/api/v1/setup/exchange") || {
        HTTP_STATUS=$?
        fail "Exchange request failed (exit $HTTP_STATUS). Check your internet connection."
    }

    # Parse JSON with python (available on both macOS and Linux)
    parse_json() {
        local key="$1"
        echo "$EXCHANGE_RESPONSE" | \
            $SERVE_METHOD -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))"
    }

    # If python wasn't set (code path with nc), default to python3
    : "${SERVE_METHOD:=python3}"

    AGENT_TOKEN=$(parse_json "agent_token")
    NODE_ID=$(parse_json "node_id")
    DISPLAY_NAME=$(parse_json "display_name")
    PRINTER_MODEL=$(parse_json "printer_model")
    HAS_BAMBUDDY_RAW=$(parse_json "has_bambuddy")

    if [ -z "$AGENT_TOKEN" ] || [ -z "$NODE_ID" ]; then
        fail "Exchange failed — no token or node_id in response. The code may be expired or already used."
    fi

    ok "Configuration received for: $DISPLAY_NAME ($PRINTER_MODEL)"

    # ── Bambuddy ──────────────────────────────────────────────────────────────
    COMPOSE_PROFILE=""
    BAMBUDDY_URL="http://localhost:8000"

    if [ "$HAS_BAMBUDDY_RAW" = "True" ] || [ "$HAS_BAMBUDDY_RAW" = "true" ]; then
        read -rp "  Bambuddy URL (press Enter for http://localhost:8000): " CUSTOM_URL
        [ -n "$CUSTOM_URL" ] && BAMBUDDY_URL="${CUSTOM_URL%/}"
        ok "Using existing Bambuddy at $BAMBUDDY_URL"
    else
        COMPOSE_PROFILE="bambuddy"
        BAMBUDDY_URL="http://bambuddy:8000"
        ok "Bambuddy will be installed as part of this setup"
        dim "After setup, open http://localhost:8000 to configure your printer in Bambuddy."
    fi

    # ── Timezone ──────────────────────────────────────────────────────────────
    TZ_VAL=$(timedatectl show --property=Timezone --value 2>/dev/null || \
             readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || \
             echo "UTC")

    # ── Write .env ────────────────────────────────────────────────────────────
    cat > .env << ENV
# NeuSlice Node Configuration
# Generated by install.sh on $(date)

# Agent credentials (auto-configured — do not share)
NEUSLICE_TOKEN=${AGENT_TOKEN}
NEUSLICE_NODE_ID=${NODE_ID}

# Bambuddy connection URL
BAMBUDDY_BASE_URL=${BAMBUDDY_URL}

# Timezone for log timestamps
TZ=${TZ_VAL}
ENV

    if [ -n "$COMPOSE_PROFILE" ]; then
        echo "" >> .env
        echo "# Enable Bambuddy container (managed by NeuSlice)" >> .env
        echo "COMPOSE_PROFILES=${COMPOSE_PROFILE}" >> .env
    fi

    chmod 600 .env
    ok ".env written"
fi

# ── 5. Pull and start ─────────────────────────────────────────────────────────

echo ""
header "Pulling Docker images (this may take a minute on first run)..."
docker compose pull

echo ""
header "Starting NeuSlice node..."
docker compose up -d

# ── 6. Done ───────────────────────────────────────────────────────────────────

echo ""
echo -e "  ${GREEN}${BOLD}✓ NeuSlice node is running!${RESET}"
echo ""

if grep -q "^COMPOSE_PROFILES=bambuddy" .env 2>/dev/null; then
    echo -e "  ${YELLOW}Next step:${RESET} open http://localhost:8000 in your browser to configure your printer in Bambuddy."
    echo ""
fi

echo "  Your printer will appear online in the NeuSlice dashboard shortly."
echo "  Updates are automatic — no action needed when NeuSlice releases new versions."
echo ""
dim "Useful commands (run from $INSTALL_DIR):"
echo "    View logs:    docker compose logs -f neuslice-agent"
echo "    Stop node:    docker compose down"
echo "    Restart node: docker compose restart"
echo ""
