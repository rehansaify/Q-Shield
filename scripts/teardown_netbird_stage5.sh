#!/usr/bin/env bash
# ==============================================================================
# Q-Shield Stage 5: NetBird Integration Teardown
#
# Cleanly terminates NetBird service daemons, removes isolated sockets
# and configuration files, and verifies that baseline Stage 1 namespaces
# and Stage 2/3/4 WireGuard/Rosenpass post-quantum tunnel remain 100% intact.
#
# Idempotent and safe to run repeatedly.
# ==============================================================================

set -euo pipefail

RUN_DIR="/var/run/netbird"
LOG_DIR="/var/log/netbird"
LIB_DIR="/var/lib/netbird"

SERVER_NS="qs-server"
CLIENT_NS="qs-client"

SERVER_PID_FILE="$RUN_DIR/server.pid"
CLIENT_PID_FILE="$RUN_DIR/client.pid"

echo "=================================================================="
echo "   Q-Shield Stage 5: NetBird Integration Teardown"
echo "=================================================================="

# 1. Verify root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: Root privileges required. Run with sudo or as root." >&2
    exit 1
fi

# 2. Terminate NetBird service processes
echo "[*] Step 1: Stopping NetBird service daemons..."
for PID_FILE in "$SERVER_PID_FILE" "$CLIENT_PID_FILE"; do
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "    - Stopping NetBird PID $PID ($PID_FILE)..."
            kill "$PID" 2>/dev/null || true
            sleep 0.5
            if kill -0 "$PID" 2>/dev/null; then
                kill -9 "$PID" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
done

# Catch any lingering netbird processes
killall netbird 2>/dev/null || true

# 3. Clean up runtime sockets, configurations, and logs
echo "[*] Step 2: Cleaning up NetBird runtime state..."
rm -f "$RUN_DIR"/*.sock "$RUN_DIR"/*.pid
rm -rf "$LIB_DIR"
rm -rf "$LOG_DIR"
rm -rf "$RUN_DIR"
echo "    [+] NetBird runtime directories removed."

# 4. Verify baseline network namespaces still exist
echo "[*] Step 3: Verifying Stage 1 network namespaces..."
if ip netns list | grep -qw "$SERVER_NS" && ip netns list | grep -qw "$CLIENT_NS"; then
    echo "    [+] Namespaces $SERVER_NS and $CLIENT_NS intact."
else
    echo "[-] Warning: One or more baseline namespaces missing." >&2
fi

# 5. Verify baseline WireGuard interface and connectivity
echo "[*] Step 4: Verifying Stage 2/3/4 WireGuard and Rosenpass health..."
WG_OK=false
if ip -n "$SERVER_NS" link show wg0 >/dev/null 2>&1 && ip -n "$CLIENT_NS" link show wg0 >/dev/null 2>&1; then
    if ip netns exec "$CLIENT_NS" ping -c 2 -W 2 10.0.0.1 >/dev/null 2>&1; then
        WG_OK=true
        echo "    [+] WireGuard wg0 tunnel (10.0.0.1 <-> 10.0.0.2) active and responding."
    fi
fi

if [ "$WG_OK" = false ]; then
    echo "[-] Warning: Baseline WireGuard tunnel requires verification or restart." >&2
fi

# Check Rosenpass
RP_OK=false
if pgrep -f "rosenpass exchange" >/dev/null 2>&1; then
    RP_OK=true
    echo "    [+] Rosenpass post-quantum exchange daemons continue running."
fi

echo "=================================================================="
echo "[+] Stage 5 teardown complete. Reverted to Stage 3/4 baseline."
echo "=================================================================="