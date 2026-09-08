#!/usr/bin/env bash
# Q-Shield: Stage 3 - Rosenpass Post-Quantum Key Exchange Setup
# Generates post-quantum keypairs, configures Rosenpass on qs-server and qs-client,
# and automatically injects the resulting shared secret into the WireGuard PSK slot.
# Idempotent and fails safely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RP_BIN="$ROOT_DIR/bin/rosenpass"

if [ ! -x "$RP_BIN" ]; then
    RP_BIN="$(command -v rosenpass || true)"
fi

if [ ! -x "$RP_BIN" ]; then
    echo "[-] Error: Rosenpass binary not found or not executable at $ROOT_DIR/bin/rosenpass" >&2
    exit 1
fi

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

echo "[*] Initializing Q-Shield Stage 3: Rosenpass Post-Quantum Integration..."

# 1. Verify Stage 1 namespaces exist
if ! ip netns list | grep -qw "qs-server" || ! ip netns list | grep -qw "qs-client"; then
    echo "[-] Error: Stage 1 namespaces (qs-server / qs-client) are missing." >&2
    echo "    Please run: sudo bash $SCRIPT_DIR/setup_namespaces.sh first." >&2
    exit 1
fi

# 2. Verify Stage 2 WireGuard wg0 exists
if ! ip netns exec qs-server ip link show dev wg0 >/dev/null 2>&1 || \
   ! ip netns exec qs-client ip link show dev wg0 >/dev/null 2>&1; then
    echo "[-] Error: Stage 2 WireGuard wg0 interfaces are missing." >&2
    echo "    Please run: sudo bash $SCRIPT_DIR/setup_wireguard_stage2.sh first." >&2
    exit 1
fi

# 3. Verify Stage 2 handshake is active
LATEST_HS="$(ip netns exec qs-client wg show wg0 latest-handshakes | awk '{print $2}' || echo "0")"
if [ -z "$LATEST_HS" ] || [ "$LATEST_HS" -eq 0 ]; then
    echo "[-] Error: Stage 2 baseline WireGuard tunnel has no active handshake." >&2
    exit 1
fi

# 4. Stop any running Rosenpass instances (idempotency)
echo "    - Cleaning up existing Rosenpass instances if any..."
killall -9 rosenpass 2>/dev/null || true
sleep 0.5

# 5. Prepare secure Rosenpass runtime directories
RP_RUNTIME_DIR="/etc/wireguard/qshield/rosenpass"
LOG_DIR="/var/log/qshield"
RUN_DIR="/var/run/qshield"

mkdir -p "$RP_RUNTIME_DIR" "$LOG_DIR" "$RUN_DIR"
chmod 700 "$RP_RUNTIME_DIR" "$RUN_DIR"

# 6. Generate Rosenpass Post-Quantum Keys if missing (idempotent)
if [ ! -f "$RP_RUNTIME_DIR/server.pqpk" ] || [ ! -f "$RP_RUNTIME_DIR/server.pqsk" ]; then
    echo "    - Generating server Rosenpass post-quantum keypair (Classic McEliece + ML-KEM)..."
    "$RP_BIN" gen-keys -f -p "$RP_RUNTIME_DIR/server.pqpk" -s "$RP_RUNTIME_DIR/server.pqsk"
    chmod 600 "$RP_RUNTIME_DIR/server.pqsk"
fi

if [ ! -f "$RP_RUNTIME_DIR/client.pqpk" ] || [ ! -f "$RP_RUNTIME_DIR/client.pqsk" ]; then
    echo "    - Generating client Rosenpass post-quantum keypair (Classic McEliece + ML-KEM)..."
    "$RP_BIN" gen-keys -f -p "$RP_RUNTIME_DIR/client.pqpk" -s "$RP_RUNTIME_DIR/client.pqsk"
    chmod 600 "$RP_RUNTIME_DIR/client.pqsk"
fi

# Retrieve existing WireGuard public keys (for native WireGuard PSK injection)
WG_KEYS_DIR="/etc/wireguard/qshield/keys"
SERVER_WG_PUB="$(cat "$WG_KEYS_DIR/server_public.key")"
CLIENT_WG_PUB="$(cat "$WG_KEYS_DIR/client_public.key")"

# 7. Start Rosenpass daemon in qs-server with native WireGuard PSK injection
echo "    - Starting Rosenpass daemon in qs-server..."
ip netns exec qs-server nohup "$RP_BIN" exchange \
    public-key "$RP_RUNTIME_DIR/server.pqpk" \
    secret-key "$RP_RUNTIME_DIR/server.pqsk" \
    listen 10.100.0.1:9999 \
    verbose \
    peer public-key "$RP_RUNTIME_DIR/client.pqpk" \
    wireguard wg0 "$CLIENT_WG_PUB" \
    > "$LOG_DIR/rosenpass-server.log" 2>&1 &
echo $! > "$RUN_DIR/rosenpass-server.pid"

sleep 0.8

# 8. Start Rosenpass daemon in qs-client with native WireGuard PSK injection
echo "    - Starting Rosenpass daemon in qs-client..."
ip netns exec qs-client nohup "$RP_BIN" exchange \
    public-key "$RP_RUNTIME_DIR/client.pqpk" \
    secret-key "$RP_RUNTIME_DIR/client.pqsk" \
    listen 10.100.0.2:9999 \
    verbose \
    peer public-key "$RP_RUNTIME_DIR/server.pqpk" \
    endpoint 10.100.0.1:9999 \
    wireguard wg0 "$SERVER_WG_PUB" \
    > "$LOG_DIR/rosenpass-client.log" 2>&1 &
echo $! > "$RUN_DIR/rosenpass-client.pid"

# 9. Wait for successful post-quantum exchange and WireGuard PSK population
echo "    - Waiting for Rosenpass post-quantum exchange and PSK injection..."
EXCHANGE_SUCCESS=false
MAX_WAIT=20

for i in $(seq 1 "$MAX_WAIT"); do
    SERVER_PSK_PRESENT=false
    CLIENT_PSK_PRESENT=false

    # Check if WireGuard wg0 shows preshared key on server
    if ip netns exec qs-server wg show wg0 | grep -q "preshared key:"; then
        SERVER_PSK_PRESENT=true
    fi

    # Check if WireGuard wg0 shows preshared key on client
    if ip netns exec qs-client wg show wg0 | grep -q "preshared key:"; then
        CLIENT_PSK_PRESENT=true
    fi

    if [ "$SERVER_PSK_PRESENT" = true ] && [ "$CLIENT_PSK_PRESENT" = true ]; then
        EXCHANGE_SUCCESS=true
        echo "    [+] Post-quantum key exchange succeeded. PSK injected into WireGuard on both peers."
        break
    fi
    sleep 0.5
done

if [ "$EXCHANGE_SUCCESS" = false ]; then
    echo "[-] Error: Rosenpass exchange timed out or failed to set WireGuard PSK." >&2
    echo "    Check logs: $LOG_DIR/rosenpass-server.log and $LOG_DIR/rosenpass-client.log" >&2
    exit 1
fi

# 10. Trigger tunnel handshake with the newly installed PSK and verify continuity
echo "    - Verifying WireGuard tunnel continuity with hybrid post-quantum PSK..."
ip netns exec qs-client ping -c 2 -W 1 10.0.0.1 >/dev/null 2>&1 || true

PING_CHECK="$(ip netns exec qs-client ping -c 3 -W 1 10.0.0.1 2>&1 || true)"
if echo "$PING_CHECK" | grep -q "0% packet loss"; then
    echo "    [+] Bidirectional traffic confirmed across hybrid post-quantum tunnel."
else
    echo "[-] Error: Traffic failed across tunnel after PSK installation." >&2
    exit 1
fi

echo "[+] Stage 3 Rosenpass Post-Quantum Integration completed successfully."