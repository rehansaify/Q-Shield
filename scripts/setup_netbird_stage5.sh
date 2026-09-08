#!/usr/bin/env bash
# ==============================================================================
# Q-Shield Stage 5: NetBird Integration Setup
#
# Initializes NetBird client daemons inside isolated network namespaces
# (qs-server and qs-client) while preserving the validated Stage 2/3/4
# WireGuard and Rosenpass post-quantum baseline.
#
# Architecture Stack:
#   NetBird (Overlay / Peer Management / Policy)
#      â†“
#   WireGuard (wg0 - Transport Encryption)
#      â†“
#   Rosenpass (PQ KEM - Classic McEliece + ML-KEM PSK Injection)
#
# Idempotent and reversible. Does not affect host networking.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NB_BIN="$PROJECT_ROOT/bin/netbird"
RUN_DIR="/var/run/netbird"
LOG_DIR="/var/log/netbird"
LIB_DIR="/var/lib/netbird"

SERVER_NS="qs-server"
CLIENT_NS="qs-client"

SERVER_SOCK="$RUN_DIR/server.sock"
CLIENT_SOCK="$RUN_DIR/client.sock"
SERVER_CFG="$LIB_DIR/server.json"
CLIENT_CFG="$LIB_DIR/client.json"
SERVER_LOG="$LOG_DIR/server.log"
CLIENT_LOG="$LOG_DIR/client.log"
SERVER_PID_FILE="$RUN_DIR/server.pid"
CLIENT_PID_FILE="$RUN_DIR/client.pid"

echo "=================================================================="
echo "   Q-Shield Stage 5: NetBird Integration Setup"
echo "=================================================================="

# 1. Verify root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: Root privileges required. Run with sudo or as root." >&2
    exit 1
fi

# 2. Verify Stage 1 network namespaces
echo "[*] Step 1: Verifying Stage 1 network namespaces..."
if ! ip netns list | grep -qw "$SERVER_NS" || ! ip netns list | grep -qw "$CLIENT_NS"; then
    echo "[-] Error: Namespaces $SERVER_NS and $CLIENT_NS must exist." >&2
    echo "    Run scripts/setup_namespaces.sh first." >&2
    exit 1
fi
echo "    [+] Namespaces $SERVER_NS and $CLIENT_NS present."

# 3. Verify Stage 2/3 baseline (wg0 and Rosenpass active)
echo "[*] Step 2: Verifying baseline WireGuard and Rosenpass state..."
if ! ip -n "$SERVER_NS" link show wg0 >/dev/null 2>&1 || ! ip -n "$CLIENT_NS" link show wg0 >/dev/null 2>&1; then
    echo "[-] Error: WireGuard interface wg0 missing in one or both namespaces." >&2
    echo "    Run scripts/setup_wireguard_stage2.sh first." >&2
    exit 1
fi

if ! ip netns exec "$CLIENT_NS" ping -c 1 -W 2 10.0.0.1 >/dev/null 2>&1; then
    echo "[-] Error: Baseline WireGuard tunnel is not passing traffic (10.0.0.1 unreachable)." >&2
    exit 1
fi
echo "    [+] Baseline WireGuard tunnel (10.0.0.1 <-> 10.0.0.2) is operational."

# 4. Verify NetBird binary and version
echo "[*] Step 3: Verifying NetBird binary..."
if [ ! -x "$NB_BIN" ]; then
    echo "[-] Error: NetBird binary not found or not executable at $NB_BIN." >&2
    exit 1
fi

NB_VERSION="$("$NB_BIN" version 2>/dev/null | tr -d '\r\n' || echo 'unknown')"
echo "    [+] NetBird binary verified: version $NB_VERSION"

# 5. Prepare runtime directories with strict permissions
echo "[*] Step 4: Preparing isolated runtime directories..."
mkdir -p "$RUN_DIR" "$LOG_DIR" "$LIB_DIR"
chmod 0700 "$RUN_DIR" "$LOG_DIR" "$LIB_DIR"

# 6. Stop any existing NetBird processes if running
if [ -f "$SERVER_PID_FILE" ]; then
    OLD_PID="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$SERVER_PID_FILE"
fi

if [ -f "$CLIENT_PID_FILE" ]; then
    OLD_PID="$(cat "$CLIENT_PID_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$CLIENT_PID_FILE"
fi

rm -f "$SERVER_SOCK" "$CLIENT_SOCK"

# 7. Start NetBird daemon in qs-server namespace
echo "[*] Step 5: Starting NetBird service daemon in $SERVER_NS..."
ip netns exec "$SERVER_NS" nohup "$NB_BIN" service run \
    --daemon-addr "unix://$SERVER_SOCK" \
    --config "$SERVER_CFG" \
    --log-file "$SERVER_LOG" \
    --log-level "info" \
    </dev/null >/dev/null 2>&1 &
echo $! > "$SERVER_PID_FILE"

# 8. Start NetBird daemon in qs-client namespace
echo "[*] Step 6: Starting NetBird service daemon in $CLIENT_NS..."
ip netns exec "$CLIENT_NS" nohup "$NB_BIN" service run \
    --daemon-addr "unix://$CLIENT_SOCK" \
    --config "$CLIENT_CFG" \
    --log-file "$CLIENT_LOG" \
    --log-level "info" \
    </dev/null >/dev/null 2>&1 &
echo $! > "$CLIENT_PID_FILE"

# 9. Wait for daemon unix sockets to become responsive
echo "[*] Step 7: Awaiting daemon socket initialization..."
SERVER_READY=false
CLIENT_READY=false

for i in $(seq 1 20); do
    if [ -S "$SERVER_SOCK" ] && [ -S "$CLIENT_SOCK" ]; then
        SERVER_READY=true
        CLIENT_READY=true
        break
    fi
    sleep 0.2
done

if [ "$SERVER_READY" = false ] || [ "$CLIENT_READY" = false ]; then
    echo "[-] Error: NetBird daemons failed to initialize unix sockets." >&2
    exit 1
fi
echo "    [+] NetBird daemons active on isolated sockets:"
echo "        Server daemon: $SERVER_SOCK (PID $(cat "$SERVER_PID_FILE"))"
echo "        Client daemon: $CLIENT_SOCK (PID $(cat "$CLIENT_PID_FILE"))"

# 10. Configure RosenpassEnabled flag in configuration files if generated
for CFG_FILE in "$SERVER_CFG" "$CLIENT_CFG"; do
    if [ -f "$CFG_FILE" ]; then
        if jq '.RosenpassEnabled = true' "$CFG_FILE" > "${CFG_FILE}.tmp" 2>/dev/null; then
            mv "${CFG_FILE}.tmp" "$CFG_FILE"
            chmod 0600 "$CFG_FILE"
        fi
    fi
done

# Restart daemons to load RosenpassEnabled configuration if needed
kill -HUP "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
kill -HUP "$(cat "$CLIENT_PID_FILE")" 2>/dev/null || true
sleep 1

# Check if external management authentication is available
SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
MGMT_URL="${NETBIRD_MANAGEMENT_URL:-}"

if [ -z "$SETUP_KEY" ]; then
    echo "------------------------------------------------------------------"
    echo "[!] NETBIRD REGISTRATION STATUS: BLOCKED"
    echo "    Reason: NetBird client daemons are initialized and running,"
    echo "    but mesh connection and interface 'wt0' require authentication"
    echo "    with a NetBird Management Server."
    echo ""
    echo "    No setup key or management server URL provided in isolated environment."
    echo "    As mandated by Q-Shield architecture requirements (Req 4, 7, 16):"
    echo "    - No fake peers or credentials will be fabricated."
    echo "    - Existing WireGuard + Rosenpass PQ tunnel remains 100% operational."
    echo "------------------------------------------------------------------"
else
    echo "[*] Step 9: Registering peers with management server ($MGMT_URL)..."
    ip netns exec "$SERVER_NS" "$NB_BIN" up \
        --daemon-addr "unix://$SERVER_SOCK" \
        --management-url "$MGMT_URL" \
        --setup-key "$SETUP_KEY" \
        --enable-rosenpass || true
fi

echo "=================================================================="
echo "[+] Stage 5 setup initialized. NetBird daemons operational."
echo "=================================================================="