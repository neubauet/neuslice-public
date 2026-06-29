#!/usr/bin/env bash
# NeuSlice Node Installer — Mac / Linux
#
# One-liner from dashboard (recommended — code pre-filled):
#   NEUSLICE_SETUP_CODE="ABC123" bash <(curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh)
#
# Manual run (opens dashboard in browser to register):
#   curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh | bash

set -euo pipefail

COMPOSE_URL="https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml"
DASHBOARD_URL="https://neuslice.com/nodes/register"
BACKEND_URL="https://printshare-backend-234aeo2mva-uc.a.run.app"
CALLBACK_PORT=9876
BAMBUDDY_PORT=8000
BAMBUDDY_READY_TIMEOUT=60   # seconds to wait for Bambuddy to start
INSTALL_DIR="${NEUSLICE_DIR:-$HOME/.neuslice}"

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"
CYAN="\033[36m"; GRAY="\033[90m"; RESET="\033[0m"

header() { echo -e "\n  ${BOLD}$*${RESET}"; }
ok()     { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()   { echo -e "  ${YELLOW}[!]${RESET}  $*"; }
fail()   { echo -e "  ${RED}[X]${RESET}  $*" >&2; exit 1; }
dim()    { echo -e "  ${GRAY}$*${RESET}"; }
info()   { echo -e "  ${CYAN}$*${RESET}"; }

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint; [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    local ans
    read -rp "  $prompt $hint: " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy] ]]
}

# Requires python3 (available on macOS by default and nearly all Linux distros)
json_field() {
    local json="$1" key="$2"
    echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))" 2>/dev/null || echo ""
}

json_array_len() {
    local json="$1"
    echo "$json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0"
}

json_array_field() {
    local json="$1" idx="$2" key="$3"
    echo "$json" | python3 -c "import sys,json; a=json.load(sys.stdin); print(a[$idx].get('$key',''))" 2>/dev/null || echo ""
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

# ── 2. Install directory ──────────────────────────────────────────────────────

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

    # ── Get NeuSlice setup code ───────────────────────────────────────────────
    SETUP_CODE="${NEUSLICE_SETUP_CODE:-}"

    if [ -z "$SETUP_CODE" ]; then
        echo ""
        dim "We'll open the NeuSlice dashboard in your browser."
        dim "Fill in your printer details and click 'Register'."
        dim "The installer will finish automatically — no copying required."
        echo ""

        # One-shot Python socket server on CALLBACK_PORT
        if ! command -v python3 &>/dev/null; then
            fail "python3 is required for the automatic setup flow. Install it and re-run, or use the one-liner from the dashboard."
        fi

        header "Starting local setup listener on port $CALLBACK_PORT..."

        PIPE_FILE=$(mktemp -u)
        mkfifo "$PIPE_FILE"

        python3 - <<PYEOF &
import socket
port = $CALLBACK_PORT
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', port))
s.listen(1)
conn, _ = s.accept()
data = conn.recv(4096).decode('utf-8', errors='replace')
code = ''
for line in data.splitlines():
    if line.startswith('GET '):
        path = line.split(' ')[1] if len(line.split(' ')) >= 2 else ''
        if 'code=' in path:
            code = path.split('code=')[1].split('&')[0].strip()
        break
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
with open('$PIPE_FILE', 'w') as f:
    f.write(code)
PYEOF

        ok "Listener ready on port $CALLBACK_PORT"

        echo ""
        info "Opening NeuSlice dashboard..."
        if command -v xdg-open &>/dev/null; then
            xdg-open "$DASHBOARD_URL" &>/dev/null &
        elif command -v open &>/dev/null; then
            open "$DASHBOARD_URL"
        else
            warn "Could not auto-open browser. Visit: $DASHBOARD_URL"
        fi

        dim "Waiting for you to complete registration in your browser..."
        echo ""

        SETUP_CODE=$(cat "$PIPE_FILE")
        rm -f "$PIPE_FILE"

        [ -z "$SETUP_CODE" ] && fail "Setup code not received. Try the one-liner from the dashboard instead."
        ok "Setup code received"
    else
        ok "Using setup code from environment: ${SETUP_CODE:0:3}***"
    fi

    # ── Exchange code for node config ─────────────────────────────────────────
    header "Exchanging setup code for configuration..."

    EXCHANGE_RESPONSE=$(curl -fsSL -X POST \
        -H "Content-Type: application/json" \
        -d "{\"code\":\"$(echo "$SETUP_CODE" | tr '[:lower:]' '[:upper:]')\"}" \
        "${BACKEND_URL}/api/v1/setup/exchange") \
        || fail "Exchange request failed. Check your internet connection."

    AGENT_TOKEN=$(json_field "$EXCHANGE_RESPONSE" "agent_token")
    NODE_ID=$(json_field "$EXCHANGE_RESPONSE" "node_id")
    DISPLAY_NAME=$(json_field "$EXCHANGE_RESPONSE" "display_name")
    PRINTER_MODEL=$(json_field "$EXCHANGE_RESPONSE" "printer_model")
    HAS_BAMBUDDY_RAW=$(json_field "$EXCHANGE_RESPONSE" "has_bambuddy")

    [ -z "$AGENT_TOKEN" ] || [ -z "$NODE_ID" ] && \
        fail "Exchange failed — code may be expired or already used. Register again from the dashboard."

    ok "Configuration received for: $DISPLAY_NAME ($PRINTER_MODEL)"

    # ── Bambuddy — Path A vs Path B ───────────────────────────────────────────

    COMPOSE_PROFILE=""
    BAMBUDDY_URL=""
    BAMBU_API_KEY=""
    BAMBU_PRINTER_ID=""

    if [ "$HAS_BAMBUDDY_RAW" = "False" ] || [ "$HAS_BAMBUDDY_RAW" = "false" ]; then

        # ── PATH A: Fresh Bambuddy install ────────────────────────────────────
        # Install Bambuddy as part of our compose stack. No API key needed —
        # Bambuddy ships with auth disabled by default. The agent will query
        # the printers list after startup and pick the right one.

        COMPOSE_PROFILE="bambuddy"
        BAMBUDDY_URL="http://bambuddy:${BAMBUDDY_PORT}"
        ok "Bambuddy will be installed as part of this setup (Path A — no API key required)"
        dim "After setup, open http://localhost:${BAMBUDDY_PORT} to add your printer to Bambuddy."
        dim "The agent will detect your printer automatically."

    else

        # ── PATH B: Existing Bambuddy install ─────────────────────────────────
        # Owner already has Bambuddy running. Need URL + API key, then we
        # query the printers list and let them pick if there are multiple.

        echo ""
        info "You indicated Bambuddy is already installed."
        echo ""

        # Bambuddy URL
        read -rp "  Bambuddy URL (press Enter for http://localhost:${BAMBUDDY_PORT}): " CUSTOM_URL
        BAMBUDDY_URL="${CUSTOM_URL:-http://localhost:${BAMBUDDY_PORT}}"
        BAMBUDDY_URL="${BAMBUDDY_URL%/}"   # strip trailing slash

        # API key
        echo ""
        dim "Create an API key in Bambuddy: Settings → API Keys → Create API Key"
        dim "Required permissions: Read Status, Manage Queue, Control Printer, Manage Library"
        echo ""
        BAMBU_API_KEY=""
        while [ -z "$BAMBU_API_KEY" ]; do
            read -rp "  Bambuddy API Key: " BAMBU_API_KEY
            [ -z "$BAMBU_API_KEY" ] && warn "API key cannot be empty."
        done

        # Fetch printer list from Bambuddy
        echo ""
        header "Fetching printers from Bambuddy..."

        PRINTERS_JSON=$(curl -fsSL \
            -H "X-API-Key: $BAMBU_API_KEY" \
            "${BAMBUDDY_URL}/api/v1/printers") \
            || fail "Could not reach Bambuddy at ${BAMBUDDY_URL}. Check the URL and make sure Bambuddy is running."

        PRINTER_COUNT=$(json_array_len "$PRINTERS_JSON")

        if [ "$PRINTER_COUNT" -eq 0 ]; then
            fail "No printers found in Bambuddy at ${BAMBUDDY_URL}. Add your printer in Bambuddy first, then re-run."
        elif [ "$PRINTER_COUNT" -eq 1 ]; then
            BAMBU_PRINTER_ID=$(json_array_field "$PRINTERS_JSON" 0 "id")
            PRINTER_NAME=$(json_array_field "$PRINTERS_JSON" 0 "name")
            PRINTER_MODEL_BB=$(json_array_field "$PRINTERS_JSON" 0 "model")
            ok "Auto-selected: $PRINTER_NAME ($PRINTER_MODEL_BB) — ID $BAMBU_PRINTER_ID"
        else
            # Multiple printers — show a numbered list
            echo ""
            echo -e "  ${BOLD}Multiple printers found. Which one is this node?${RESET}"
            echo ""
            for i in $(seq 0 $((PRINTER_COUNT - 1))); do
                P_ID=$(json_array_field "$PRINTERS_JSON" $i "id")
                P_NAME=$(json_array_field "$PRINTERS_JSON" $i "name")
                P_MODEL=$(json_array_field "$PRINTERS_JSON" $i "model")
                echo "    $((i + 1))) $P_NAME  ($P_MODEL)  — ID $P_ID"
            done
            echo ""

            SELECTION=""
            while true; do
                read -rp "  Enter number (1–${PRINTER_COUNT}): " SELECTION
                if [[ "$SELECTION" =~ ^[0-9]+$ ]] && \
                   [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$PRINTER_COUNT" ]; then
                    IDX=$((SELECTION - 1))
                    BAMBU_PRINTER_ID=$(json_array_field "$PRINTERS_JSON" $IDX "id")
                    PRINTER_NAME=$(json_array_field "$PRINTERS_JSON" $IDX "name")
                    ok "Selected: $PRINTER_NAME — ID $BAMBU_PRINTER_ID"
                    break
                else
                    warn "Please enter a number between 1 and ${PRINTER_COUNT}."
                fi
            done
        fi
    fi

    # ── Timezone ──────────────────────────────────────────────────────────────
    TZ_VAL=$(timedatectl show --property=Timezone --value 2>/dev/null \
        || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' \
        || echo "UTC")

    # ── Write .env ────────────────────────────────────────────────────────────
    cat > .env << ENV
# NeuSlice Node Configuration
# Generated by install.sh on $(date)

# Agent credentials (auto-configured — do not share)
NEUSLICE_TOKEN=${AGENT_TOKEN}
NEUSLICE_NODE_ID=${NODE_ID}

# Bambuddy connection
BAMBUDDY_BASE_URL=${BAMBUDDY_URL}

# Timezone for log timestamps
TZ=${TZ_VAL}
ENV

    # Path B extras — API key and printer ID
    if [ -n "$BAMBU_API_KEY" ]; then
        cat >> .env << ENV

# Bambuddy API credentials (Path B — existing install)
BAMBU_API_KEY=${BAMBU_API_KEY}
ENV
    fi

    if [ -n "$BAMBU_PRINTER_ID" ]; then
        echo "BAMBU_PRINTER_ID=${BAMBU_PRINTER_ID}" >> .env
    fi

    # Compose profile for fresh Bambuddy
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

# ── 6. Path A: wait for Bambuddy, then pick printer ──────────────────────────

if grep -q "^COMPOSE_PROFILES=bambuddy" .env 2>/dev/null; then
    echo ""
    header "Waiting for Bambuddy to start..."
    BAMBUDDY_HOST_URL="http://localhost:${BAMBUDDY_PORT}"
    ELAPSED=0
    until curl -fsSL --max-time 2 "${BAMBUDDY_HOST_URL}/api/v1/printers" &>/dev/null; do
        if [ "$ELAPSED" -ge "$BAMBUDDY_READY_TIMEOUT" ]; then
            warn "Bambuddy didn't respond within ${BAMBUDDY_READY_TIMEOUT}s."
            warn "Open http://localhost:${BAMBUDDY_PORT} to add your printer manually."
            warn "Then restart the agent: docker compose restart neuslice-agent"
            break
        fi
        printf "  Waiting... (%ds)\r" "$ELAPSED"
        sleep 3
        ELAPSED=$((ELAPSED + 3))
    done

    echo ""
    PRINTERS_JSON=$(curl -fsSL --max-time 5 "${BAMBUDDY_HOST_URL}/api/v1/printers" 2>/dev/null || echo "[]")
    PRINTER_COUNT=$(json_array_len "$PRINTERS_JSON")

    if [ "$PRINTER_COUNT" -eq 0 ]; then
        echo ""
        warn "No printers found in Bambuddy yet."
        info "Open http://localhost:${BAMBUDDY_PORT} to add your printer."
        dim "Once added, restart the agent: docker compose restart neuslice-agent"
        dim "The agent will auto-detect your printer on next start."
    elif [ "$PRINTER_COUNT" -eq 1 ]; then
        BAMBU_PRINTER_ID=$(json_array_field "$PRINTERS_JSON" 0 "id")
        PRINTER_NAME=$(json_array_field "$PRINTERS_JSON" 0 "name")
        echo "BAMBU_PRINTER_ID=${BAMBU_PRINTER_ID}" >> .env
        ok "Auto-selected printer: $PRINTER_NAME (ID $BAMBU_PRINTER_ID) — written to .env"
        docker compose restart neuslice-agent &>/dev/null || true
        ok "Agent restarted with printer selection"
    else
        echo ""
        echo -e "  ${BOLD}Multiple printers found in Bambuddy. Which one is this node?${RESET}"
        echo ""
        for i in $(seq 0 $((PRINTER_COUNT - 1))); do
            P_ID=$(json_array_field "$PRINTERS_JSON" $i "id")
            P_NAME=$(json_array_field "$PRINTERS_JSON" $i "name")
            P_MODEL=$(json_array_field "$PRINTERS_JSON" $i "model")
            echo "    $((i + 1))) $P_NAME  ($P_MODEL)  — ID $P_ID"
        done
        echo ""

        SELECTION=""
        while true; do
            read -rp "  Enter number (1–${PRINTER_COUNT}): " SELECTION
            if [[ "$SELECTION" =~ ^[0-9]+$ ]] && \
               [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$PRINTER_COUNT" ]; then
                IDX=$((SELECTION - 1))
                BAMBU_PRINTER_ID=$(json_array_field "$PRINTERS_JSON" $IDX "id")
                PRINTER_NAME=$(json_array_field "$PRINTERS_JSON" $IDX "name")
                echo "BAMBU_PRINTER_ID=${BAMBU_PRINTER_ID}" >> .env
                ok "Selected: $PRINTER_NAME (ID $BAMBU_PRINTER_ID) — written to .env"
                docker compose restart neuslice-agent &>/dev/null || true
                ok "Agent restarted with printer selection"
                break
            else
                warn "Please enter a number between 1 and ${PRINTER_COUNT}."
            fi
        done
    fi
fi

# ── 7. Done ───────────────────────────────────────────────────────────────────

echo ""
echo -e "  ${GREEN}${BOLD}✓ NeuSlice node is running!${RESET}"
echo ""

if grep -q "^COMPOSE_PROFILES=bambuddy" .env 2>/dev/null && \
   ! grep -q "^BAMBU_PRINTER_ID=" .env 2>/dev/null; then
    echo -e "  ${YELLOW}Next step:${RESET} Open http://localhost:${BAMBUDDY_PORT} to add your printer to Bambuddy."
    dim "Then run: docker compose restart neuslice-agent"
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
