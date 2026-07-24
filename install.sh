#!/usr/bin/env bash
# NeuSlice Node Installer — Mac / Linux
#
# One-liner from dashboard (recommended — code pre-filled):
#   NEUSLICE_SETUP_CODE="ABC123" bash <(curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh)
#
# Manual run (opens dashboard in browser to register):
#   curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/install.sh | bash

# -E (errtrace) matters: without it the ERR trap below does NOT fire inside
# functions or subshells, which is most of this script.
set -Eeuo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# Every value is env-overridable so CI and self-hosters can point at a mock or
# a private backend without editing the script.
COMPOSE_URL="${COMPOSE_URL:-https://raw.githubusercontent.com/neubauet/neuslice-public/main/docker-compose.yml}"
DASHBOARD_URL="${DASHBOARD_URL:-https://neuslice.com/nodes/register}"
BACKEND_URL="${BACKEND_URL:-https://printshare-backend-234aeo2mva-uc.a.run.app}"
CALLBACK_PORT="${CALLBACK_PORT:-9876}"
BAMBUDDY_PORT="${BAMBUDDY_PORT:-8000}"
BAMBUDDY_READY_TIMEOUT="${BAMBUDDY_READY_TIMEOUT:-60}"   # seconds to wait for Bambuddy
INSTALL_DIR="${NEUSLICE_DIR:-$HOME/.neuslice}"

# Take every answer from the environment and never prompt. Used by CI, and by
# owners scripting a multi-machine rollout.
NEUSLICE_NONINTERACTIVE="${NEUSLICE_NONINTERACTIVE:-0}"
# Exercise the whole flow without touching Docker (CI only).
NEUSLICE_DRY_RUN="${NEUSLICE_DRY_RUN:-0}"

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"
CYAN="\033[36m"; GRAY="\033[90m"; RESET="\033[0m"

header() { echo -e "\n  ${BOLD}$*${RESET}"; }
ok()     { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()   { echo -e "  ${YELLOW}[!]${RESET}  $*"; }
fail()   { CLEAN_FAIL=1; echo -e "  ${RED}[X]${RESET}  $*" >&2; exit 1; }
dim()    { echo -e "  ${GRAY}$*${RESET}"; }
info()   { echo -e "  ${CYAN}$*${RESET}"; }

# ── Transcript + failure reporting ────────────────────────────────────────────
# Before this, every failure looked identical: `set -e` exited silently and the
# terminal simply came back, with no message, no line number and no log. Six
# separate installer bugs presented as "it connects, then drops to the terminal".
mkdir -p "$INSTALL_DIR"
LOG_FILE="${NEUSLICE_LOG:-$INSTALL_DIR/install.log}"
printf '\n=== install run %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

CLEAN_FAIL=0
on_error() {
    local rc=$? line="$1" cmd="$2"
    # fail() already printed something actionable — don't stack a second report.
    [ "${CLEAN_FAIL:-0}" = "1" ] && return 0
    # A failure inside $( ) fires ERR in the subshell AND again in the parent.
    # Report only from the top level, where the command shown is the full
    # assignment rather than the last fragment of its pipeline.
    [ "${BASH_SUBSHELL:-0}" -gt 0 ] && return 0
    echo "" >&2
    echo -e "  ${RED}[X]${RESET}  Install failed at line ${line} (exit ${rc})" >&2
    echo -e "        command: ${cmd}" >&2
    echo -e "  ${GRAY}      full transcript: ${LOG_FILE}${RESET}" >&2
    echo -e "  ${GRAY}      (safe to share — credentials are written to .env, never echoed)${RESET}" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ── Prompt helpers ────────────────────────────────────────────────────────────
# Prompts talk to the terminal directly rather than through the log pipe above.
# Two reasons: `read -p` writes its prompt to stderr, which tee can buffer so the
# prompt never appears; and when this script is run as `curl ... | bash`, stdin
# is the SCRIPT itself, not the user. Reading /dev/tty fixes both.
HAVE_TTY=0
if [ -r /dev/tty ] && [ -w /dev/tty ]; then HAVE_TTY=1; fi

_no_tty_fail() {
    fail "Need a value for $1, but this run is non-interactive. Set $1 in the environment (see NEUSLICE_NONINTERACTIVE in the README)."
}

ask() {  # ask VAR_NAME "prompt text"
    local __var="$1" __prompt="$2" __reply=""
    if [ "$NEUSLICE_NONINTERACTIVE" = "1" ] || [ "$HAVE_TTY" != "1" ]; then
        _no_tty_fail "$__var"
    fi
    printf '%s' "$__prompt" > /dev/tty
    IFS= read -r __reply < /dev/tty
    printf -v "$__var" '%s' "$__reply"
}

ask_secret() {  # ask_secret VAR_NAME "prompt text" — never echoed, never logged
    local __var="$1" __prompt="$2" __reply=""
    if [ "$NEUSLICE_NONINTERACTIVE" = "1" ] || [ "$HAVE_TTY" != "1" ]; then
        _no_tty_fail "$__var"
    fi
    printf '%s' "$__prompt" > /dev/tty
    IFS= read -rs __reply < /dev/tty
    printf '\n' > /dev/tty
    printf -v "$__var" '%s' "$__reply"
}

ask_yn() {
    local prompt="$1" default="${2:-y}" hint ans
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    if [ "$NEUSLICE_NONINTERACTIVE" = "1" ] || [ "$HAVE_TTY" != "1" ]; then
        ans="$default"
    else
        printf '  %s %s: ' "$prompt" "$hint" > /dev/tty
        IFS= read -r ans < /dev/tty
    fi
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

# ── 0. Preflight ──────────────────────────────────────────────────────────────
# Fail on a missing prerequisite with a clear message, up front, instead of
# dying obscurely 300 lines later.

header "Checking prerequisites..."

OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Darwin) PLATFORM="macOS" ;;
    Linux)
        PLATFORM="Linux"
        grep -qi microsoft /proc/version 2>/dev/null && PLATFORM="WSL"
        ;;
    *) fail "Unsupported OS: $OS_NAME. This installer supports macOS and Linux — on Windows use install.ps1." ;;
esac
ok "Platform: $PLATFORM"

# od and tr generate the Watchtower token; python3 parses every API response.
MISSING_TOOLS=()
for _t in curl python3 od tr; do
    command -v "$_t" &>/dev/null || MISSING_TOOLS+=("$_t")
done
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    fail "Missing required tool(s): ${MISSING_TOOLS[*]} — install them and re-run."
fi
ok "Required tools present"

# ── Docker access ─────────────────────────────────────────────────────────────
# get.docker.com installs Docker and starts the daemon, but it does NOT add the
# invoking user to the `docker` group — it only prints a suggestion to. On Linux
# the daemon socket is root:docker, so the very next `docker info` in THIS shell
# fails with "permission denied", and a fresh single-run install can never get
# past it. (Docker Desktop on macOS/Windows exposes the socket to the user
# directly, which is why this went unnoticed there — that's where we test.)
#
# ensure_docker_access() makes the current run work in one shot:
#   1. If we can already reach the daemon, do nothing.
#   2. If the daemon is genuinely down, try to start it; else fail clearly.
#   3. Otherwise it's a group-membership gap: add the user to `docker`, then run
#      the rest of THIS run's docker commands through `sg docker` — which reads
#      /etc/group fresh, so the group is usable immediately with no re-login. If
#      `sg` can't (rare), fall back to sudo.
# After this, every docker call goes through d() so it uses whatever access
# method we resolved.
DOCKER_SG=0
DOCKER_SUDO=0
DOCKER_GROUP_ADDED=0
DOCKER_USER=""

ensure_docker_access() {
    docker info &>/dev/null && return 0

    # Is the daemon actually down, or can we just not reach the socket? Check as
    # root to tell them apart. If root can't reach it either, it's really down —
    # try to start it (systemd hosts), then give up with an actionable message.
    if ! sudo docker info &>/dev/null; then
        sudo systemctl enable --now docker &>/dev/null || true
        sudo docker info &>/dev/null || \
            fail "Docker is installed but its daemon isn't running. Start it with: sudo systemctl enable --now docker  — then re-run."
    fi

    # Daemon is up; this session just lacks socket access. Resolve the real login
    # user even if someone ran us under sudo (against our advice).
    DOCKER_USER="${SUDO_USER:-$(id -un)}"
    if [ "$DOCKER_USER" != "root" ] && \
       ! id -nG "$DOCKER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        warn "Adding '$DOCKER_USER' to the 'docker' group..."
        if sudo usermod -aG docker "$DOCKER_USER"; then
            DOCKER_GROUP_ADDED=1
        else
            warn "Could not add '$DOCKER_USER' to the docker group — will use sudo for this run."
        fi
    fi

    # Use the group NOW, without a re-login: `sg` reads /etc/group at exec time.
    if [ "$DOCKER_USER" != "root" ] && sg docker -c 'docker info' &>/dev/null; then
        DOCKER_SG=1
    elif sudo docker info &>/dev/null; then
        DOCKER_SUDO=1
    else
        fail "Docker is installed and running, but this account can't access it. Log out and back in (or reboot), then re-run."
    fi
}

# Run a docker command through whatever access method ensure_docker_access chose.
# In sg mode the command must be a single string, so quote every argument.
d() {
    if   [ "$DOCKER_SG" = 1 ];   then sg docker -c "$(printf '%q ' docker "$@")"
    elif [ "$DOCKER_SUDO" = 1 ]; then sudo docker "$@"
    else                              docker "$@"
    fi
}

# ── 1. Check Docker ───────────────────────────────────────────────────────────

header "Checking Docker..."

if [ "$NEUSLICE_DRY_RUN" = "1" ]; then
    warn "DRY RUN — skipping all Docker checks and commands"
else
    if ! command -v docker &>/dev/null; then
        warn "Docker not found. Installing..."
        curl -fsSL https://get.docker.com | sh
        ok "Docker installed"
    else
        ok "Docker found: $(docker --version)"
    fi

    # Make sure THIS run can reach the daemon — including the common fresh-install
    # case where Docker was just installed and the user's docker-group membership
    # hasn't taken effect in this shell yet. (See ensure_docker_access above.)
    ensure_docker_access

    d compose version &>/dev/null || \
        fail "Docker Compose v2 required. Run: apt install docker-compose-plugin  or update Docker Desktop."
    ok "Docker Compose v2 available"
fi

# ── 2. Install directory ──────────────────────────────────────────────────────

header "Setting up install directory..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
ok "Install directory: $INSTALL_DIR"

# ── 3. Download docker-compose.yml ────────────────────────────────────────────

header "Downloading docker-compose.yml..."
# Cache-bust http(s) only — raw.githubusercontent caches for ~5 min. A file://
# URL (used by the CI dry-run) must not get a query string appended.
case "$COMPOSE_URL" in
    http*) curl -fsSL "${COMPOSE_URL}?t=$(date +%s)" -o docker-compose.yml ;;
    *)     curl -fsSL "${COMPOSE_URL}" -o docker-compose.yml ;;
esac
ok "docker-compose.yml downloaded"

# ── 4. Configuration ──────────────────────────────────────────────────────────

echo ""
echo -e "  ${GRAY}── Setup ──────────────────────────────────${RESET}"
echo ""

SKIP_ENV=false
if [ -f .env ] && grep -q "^NEUSLICE_TOKEN=" .env; then
    EXISTING_TOKEN=$(grep "^NEUSLICE_TOKEN=" .env | cut -d'=' -f2)
    warn "Existing .env found (token: ${EXISTING_TOKEN:0:8}...)."

    # Ensure WATCHTOWER_TOKEN exists even on re-runs (older installs won't have it)
    if ! grep -q "^WATCHTOWER_HTTP_API_TOKEN=" .env; then
        WT=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d '[:space:]')
        printf "\nWATCHTOWER_HTTP_API_TOKEN=%s\n" "$WT" >> .env
        ok "Added WATCHTOWER_TOKEN to existing .env"
    fi

    # Ensure NEUSLICE_API_URL exists (pre-fix installs lack it; the agent
    # requires it explicitly and crash-loops without it).
    if ! grep -q "^NEUSLICE_API_URL=" .env; then
        echo "NEUSLICE_API_URL=$BACKEND_URL" >> .env
        ok "Added NEUSLICE_API_URL to existing .env"
    fi

    # Ensure BAMBU_USERNAME/PASSWORD exist (older installs won't have them)
    if grep -q "^BAMBU_API_KEY=" .env && ! grep -q "^BAMBU_USERNAME=" .env; then
        echo ""
        info "Your .env is missing Bambuddy login credentials (needed for file upload)."
        dim  "(These are the username and password for the Bambuddy web UI.)"
        echo ""
        UP_USER="${BAMBU_USERNAME:-}"
        while [ -z "$UP_USER" ]; do
            ask UP_USER "  Bambuddy Username: "
            [ -z "$UP_USER" ] && warn "Username cannot be empty."
        done
        UP_PASS="${BAMBU_PASSWORD:-}"
        while [ -z "$UP_PASS" ]; do
            ask_secret UP_PASS "  Bambuddy Password: "
            [ -z "$UP_PASS" ] && warn "Password cannot be empty."
        done
        printf "\nBAMBU_USERNAME=%s\n" "$UP_USER" >> .env
        printf "BAMBU_PASSWORD=%s\n" "$UP_PASS" >> .env
        ok "Added BAMBU_USERNAME and BAMBU_PASSWORD to existing .env"
    fi

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
    # Seeded from the environment when present, so a scripted or CI run supplies
    # these instead of being prompted. The prompt loops below are `while [ -z … ]`,
    # so an env-provided value simply skips the prompt.
    BAMBU_API_KEY="${BAMBU_API_KEY:-}"
    BAMBU_USERNAME="${BAMBU_USERNAME:-}"
    BAMBU_PASSWORD="${BAMBU_PASSWORD:-}"
    BAMBU_PRINTER_ID="${BAMBU_PRINTER_ID:-}"

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

        # Bambuddy URL — the SAME Bambuddy needs TWO addresses, because two
        # different clients reach it:
        #   1. THIS installer, on the host, curls Bambuddy to validate + list
        #      printers            → needs a HOST-reachable address
        #   2. the agent CONTAINER, at runtime, curls it for every print
        #      → 'localhost' there is the container itself, so it needs an
        #        address that reaches the host FROM a container
        # host.docker.internal does NOT resolve from the host shell on macOS, so
        # defaulting to it (as this once did) made the validation curl below fail
        # with "Could not resolve host". Instead we ask for the URL as the user
        # reaches it here (localhost), validate THAT, and translate only a loopback
        # host to a container-reachable address for .env:
        #   macOS / Windows Docker Desktop → host.docker.internal
        #   Linux Docker Engine            → default-route gateway (fallback host.docker.internal)
        # A real LAN IP or remote hostname reaches both, so it is left unchanged.
        DEFAULT_BAMBUDDY_URL="http://localhost:${BAMBUDDY_PORT}"
        if [ -n "${NEUSLICE_BAMBUDDY_URL:-}" ]; then
            CUSTOM_URL="$NEUSLICE_BAMBUDDY_URL"      # scripted / CI
        elif [ "$NEUSLICE_NONINTERACTIVE" = "1" ]; then
            CUSTOM_URL=""                            # take the localhost default
        else
            dim "(Enter the URL as you reach Bambuddy on THIS machine — usually localhost."
            dim " We translate it to a container-reachable address for the agent automatically.)"
            ask CUSTOM_URL "  Bambuddy URL (press Enter for $DEFAULT_BAMBUDDY_URL): "
        fi
        BAMBUDDY_VALIDATE_URL="${CUSTOM_URL:-$DEFAULT_BAMBUDDY_URL}"
        BAMBUDDY_VALIDATE_URL="${BAMBUDDY_VALIDATE_URL%/}"   # strip trailing slash

        # Container-reachable address written to .env (see note above).
        # One address on every platform: docker-compose.yml maps
        # host.docker.internal to `host-gateway`, which Docker resolves to the
        # host on Linux Engine as well as Docker Desktop.
        #
        # This replaced a per-platform guess that used `ip route show default` on
        # Linux — that returns the LAN ROUTER, not the docker bridge gateway, so
        # Linux nodes were pointed at the wrong host; and the pipeline exited 127
        # on a box without iproute2, which under set -e + pipefail killed the
        # whole installer with 2>/dev/null hiding the reason.
        HOST_ADDR="host.docker.internal"
        BAMBUDDY_URL=$(printf '%s' "$BAMBUDDY_VALIDATE_URL" \
            | sed -E "s#://(localhost|127\.0\.0\.1)([:/]|\$)#://${HOST_ADDR}\2#")
        [ "$BAMBUDDY_URL" != "$BAMBUDDY_VALIDATE_URL" ] && \
            dim "Agent container will reach Bambuddy at $BAMBUDDY_URL"

        # API key
        echo ""
        dim "Create an API key in Bambuddy: Settings → API Keys → Create API Key"
        dim "Required permissions: Read Status, Manage Queue, Control Printer, Manage Library"
        echo ""
        while [ -z "$BAMBU_API_KEY" ]; do
            ask BAMBU_API_KEY "  Bambuddy API Key: "
            [ -z "$BAMBU_API_KEY" ] && warn "API key cannot be empty."
        done

        # Bambuddy login credentials (needed for file upload — API key alone is not enough)
        echo ""
        info "Bambuddy requires a username and password to upload print files."
        dim  "(These are the credentials you use to log into the Bambuddy web UI.)"
        echo ""
        while [ -z "$BAMBU_USERNAME" ]; do
            ask BAMBU_USERNAME "  Bambuddy Username: "
            [ -z "$BAMBU_USERNAME" ] && warn "Username cannot be empty."
        done
        while [ -z "$BAMBU_PASSWORD" ]; do
            ask_secret BAMBU_PASSWORD "  Bambuddy Password: "
            [ -z "$BAMBU_PASSWORD" ] && warn "Password cannot be empty."
        done

        # Fetch printer list from Bambuddy
        echo ""
        header "Fetching printers from Bambuddy..."

        # Validate against the HOST-reachable URL the user entered — NOT the
        # translated container URL, which may not resolve from the host (macOS).
        PRINTERS_JSON=$(curl -fsSL \
            -H "X-API-Key: $BAMBU_API_KEY" \
            "${BAMBUDDY_VALIDATE_URL}/api/v1/printers/") \
            || fail "Could not reach Bambuddy at ${BAMBUDDY_VALIDATE_URL}. Check the URL and make sure Bambuddy is running."

        PRINTER_COUNT=$(json_array_len "$PRINTERS_JSON")

        if [ "$PRINTER_COUNT" -eq 0 ]; then
            fail "No printers found in Bambuddy at ${BAMBUDDY_VALIDATE_URL}. Add your printer in Bambuddy first, then re-run."
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
                ask SELECTION "  Enter number (1–${PRINTER_COUNT}): "
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
    WATCHTOWER_HTTP_API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d '[:space:]')
    cat > .env << ENV
# NeuSlice Node Configuration
# Generated by install.sh on $(date)

# Agent credentials (auto-configured — do not share)
NEUSLICE_TOKEN=${AGENT_TOKEN}
NEUSLICE_NODE_ID=${NODE_ID}
NEUSLICE_API_URL=${BACKEND_URL}

# Watchtower update token (shared secret between agent and watchtower)
WATCHTOWER_HTTP_API_TOKEN=${WATCHTOWER_HTTP_API_TOKEN}

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

if [ "$NEUSLICE_DRY_RUN" = "1" ]; then
    echo ""
    warn "DRY RUN — skipping 'docker compose pull' and 'docker compose up -d'"
    ok "Config written; stopping before Docker as requested"
else
    echo ""
    header "Pulling Docker images (this may take a minute on first run)..."
    d compose pull || {
        warn "Image pull failed — continuing with locally cached images (if any)..."
    }

    echo ""
    header "Starting NeuSlice node..."
    d compose up -d || {
        echo ""
        fail "'docker compose up -d' failed. Recent logs:\n$(d compose logs --tail=30 2>&1)"
    }
fi

# ── 6. Path A: wait for Bambuddy, then pick printer ──────────────────────────

if [ "$NEUSLICE_DRY_RUN" != "1" ] && grep -q "^COMPOSE_PROFILES=bambuddy" .env 2>/dev/null; then
    echo ""
    header "Waiting for Bambuddy to start..."
    BAMBUDDY_HOST_URL="http://localhost:${BAMBUDDY_PORT}"
    ELAPSED=0
    until curl -fsSL --max-time 2 "${BAMBUDDY_HOST_URL}/api/v1/printers/" &>/dev/null; do
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
    PRINTERS_JSON=$(curl -fsSL --max-time 5 "${BAMBUDDY_HOST_URL}/api/v1/printers/" 2>/dev/null || echo "[]")
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
        d compose restart neuslice-agent &>/dev/null || true
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
            ask SELECTION "  Enter number (1–${PRINTER_COUNT}): "
            if [[ "$SELECTION" =~ ^[0-9]+$ ]] && \
               [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$PRINTER_COUNT" ]; then
                IDX=$((SELECTION - 1))
                BAMBU_PRINTER_ID=$(json_array_field "$PRINTERS_JSON" $IDX "id")
                PRINTER_NAME=$(json_array_field "$PRINTERS_JSON" $IDX "name")
                echo "BAMBU_PRINTER_ID=${BAMBU_PRINTER_ID}" >> .env
                ok "Selected: $PRINTER_NAME (ID $BAMBU_PRINTER_ID) — written to .env"
                d compose restart neuslice-agent &>/dev/null || true
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

# If we added the user to the docker group during THIS run, the node is already
# up (we used `sg`/sudo to get here), but their *shell* won't have the group
# until the next login — so the "Useful commands" below would fail with a
# permission error in this same terminal. Tell them once.
if [ "${DOCKER_GROUP_ADDED:-0}" = 1 ]; then
    info "Added '${DOCKER_USER}' to the 'docker' group so you can manage the node without sudo."
    dim "Your node is already running. To run the commands below in THIS terminal,"
    dim "log out and back in once (or reboot) so the group applies to your shell."
    echo ""
fi

dim "Useful commands (run from $INSTALL_DIR):"
echo "    View logs:    docker compose logs -f neuslice-agent"
echo "    Stop node:    docker compose down"
echo "    Restart node: docker compose restart"
echo ""
