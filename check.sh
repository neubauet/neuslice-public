#!/usr/bin/env bash
# NeuSlice printer discovery + pre-install check — Mac / Linux
#
# Finds 3D printers on this network and prints the exact address to paste into
# the NeuSlice dashboard, then (in check mode) proves every endpoint the
# installer needs before it needs them.
#
# Run this BEFORE install.sh. Unlike the installer it needs no root and changes
# nothing on the machine — it only reads the network.
#
#   curl -fsSL https://raw.githubusercontent.com/neubauet/neuslice-public/main/check.sh | bash
#   ./check.sh check --printer=http://192.168.1.100:7125
#
# Exit codes: 0 success · 1 error or failed check · 3 discover found nothing.

set -Eeuo pipefail

NODE_VERSION="${NODE_VERSION:-v24.19.0}"
MIRROR_BASE="${MIRROR_BASE:-https://raw.githubusercontent.com/neubauet/neuslice-public/main}"
DASHBOARD_URL="${NEUSLICE_DASHBOARD_URL:-https://neuslice.com/nodes/register}"
INSTALL_DIR="${NEUSLICE_DIR:-$HOME/.neuslice}"

# Set NEUSLICE_NO_OPEN=1 to keep the browser closed after a successful discover.
NO_OPEN="${NEUSLICE_NO_OPEN:-0}"

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"
CYAN="\033[36m"; GRAY="\033[90m"; RESET="\033[0m"

ok()   { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[!]${RESET}  $*"; }
fail() { echo -e "  ${RED}[X]${RESET}  $*" >&2; exit 1; }
dim()  { echo -e "  ${GRAY}$*${RESET}"; }

# Anything we create goes here and is removed on exit. This is deliberately a
# no-footprint tool — people run it before deciding to install anything.
TEMP_ROOT=""
cleanup() { [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ] && rm -rf "$TEMP_ROOT"; return 0; }
trap cleanup EXIT

make_temp() {
    [ -n "$TEMP_ROOT" ] && return 0
    TEMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t neuslice-check)"
}

# ── Locate a usable Node ──────────────────────────────────────────────────────
resolve_node() {
    # 1. A runtime the NeuSlice installer already put down.
    local bundled
    bundled="$(find "$INSTALL_DIR/runtime" -name node -type f -perm -u+x 2>/dev/null | head -n 1 || true)"
    if [ -n "$bundled" ]; then
        dim "Using the NeuSlice runtime already on this machine." >&2
        echo "$bundled"; return 0
    fi

    # 2. A system Node, if it is new enough for fetch + AbortSignal.timeout.
    if command -v node >/dev/null 2>&1; then
        local v major
        v="$(node --version 2>/dev/null || echo v0)"
        major="$(echo "$v" | sed -E 's/^v([0-9]+)\..*/\1/')"
        if [ "${major:-0}" -ge 18 ] 2>/dev/null; then
            dim "Using system Node $v." >&2
            command -v node; return 0
        fi
        warn "System Node $v is too old (need v18+); fetching a portable copy." >&2
    fi

    # 3. Fetch a portable one, removed when this script exits.
    local os arch tarball
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux"  ;;
        *)      fail "Unsupported OS $(uname -s). Install Node 18+ and re-run." ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x64"   ;;
        arm64|aarch64) arch="arm64" ;;
        *)             fail "Unsupported architecture $(uname -m). Install Node 18+ and re-run." ;;
    esac

    make_temp
    tarball="node-${NODE_VERSION}-${os}-${arch}.tar.gz"
    dim "Downloading a temporary Node runtime (~30 MB, removed when this finishes)..." >&2
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${tarball}" -o "$TEMP_ROOT/node.tar.gz" \
        || fail "Could not download the Node runtime."
    tar -xzf "$TEMP_ROOT/node.tar.gz" -C "$TEMP_ROOT" || fail "Could not extract the Node runtime."
    local exe="$TEMP_ROOT/node-${NODE_VERSION}-${os}-${arch}/bin/node"
    [ -x "$exe" ] || fail "Node download completed but the binary is missing."
    echo "$exe"
}

# ── Locate discover.js ────────────────────────────────────────────────────────
resolve_script() {
    # Running from the source tree.
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '')"
    if [ -n "$here" ] && [ -f "$here/neuslice-agent/src/discover.js" ]; then
        echo "$here/neuslice-agent/src/discover.js"; return 0
    fi
    # An installed agent already has it.
    if [ -f "$INSTALL_DIR/agent/src/discover.js" ]; then
        echo "$INSTALL_DIR/agent/src/discover.js"; return 0
    fi
    # Otherwise pull the single file from the public mirror. It imports nothing
    # beyond node: builtins, so one file is the whole tool.
    make_temp
    curl -fsSL "$MIRROR_BASE/discover.js" -o "$TEMP_ROOT/discover.js" \
        || fail "Could not download discover.js."
    echo "$TEMP_ROOT/discover.js"
}

echo ""
echo -e "  ${CYAN}${BOLD}NeuSlice Network Check${RESET} (read-only — no root, nothing installed)"

NODE_BIN="$(resolve_node)"
SCRIPT_PATH="$(resolve_script)"

# No args at all → discover. Otherwise pass everything through untouched.
if [ "$#" -eq 0 ]; then set -- discover; fi

# Capture the dashboard payload from the SAME sweep that prints the table —
# running discovery twice would double a 25-second wait for no reason.
FOUND_FILE=""
if [ "$1" = "discover" ] && [ "$NO_OPEN" != "1" ] && ! printf '%s\n' "$@" | grep -qx -- '--json'; then
    make_temp
    FOUND_FILE="$TEMP_ROOT/found.txt"
    set -- "$@" "--found-out=$FOUND_FILE"
fi

set +e
"$NODE_BIN" "$SCRIPT_PATH" "$@"
CODE=$?
set -e

# The payoff: hand the results to the browser so the owner picks their printer
# from a list instead of transcribing an IP into the form.
if [ -n "$FOUND_FILE" ] && [ -s "$FOUND_FILE" ]; then
    PAYLOAD="$(tr -d '[:space:]' < "$FOUND_FILE")"
    case "$PAYLOAD" in
        *[!A-Za-z0-9_-]*|'') ;;   # not a clean payload - leave the browser alone
        *)
            REGISTER_URL="${DASHBOARD_URL}?found=${PAYLOAD}"
            echo ""
            ok  "Opening NeuSlice with these printers ready to select..."
            dim "If your browser doesn't open, paste this address:"
            dim "$REGISTER_URL"
            if command -v xdg-open >/dev/null 2>&1; then
                xdg-open "$REGISTER_URL" >/dev/null 2>&1 &
            elif command -v open >/dev/null 2>&1; then
                open "$REGISTER_URL" >/dev/null 2>&1 || true
            else
                warn "Could not open a browser automatically - copy the address above."
            fi
            ;;
    esac
fi

# 3 = discovery ran fine but found nothing. Worth a nudge, not an error dump.
if [ "$CODE" -eq 3 ]; then
    warn "Nothing found. If the printer is on Wi-Fi, check it is on the same network as this computer"
    dim  "(a 5 GHz / guest network is the usual culprit), then re-run."
fi
exit $CODE
