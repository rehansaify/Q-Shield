#!/usr/bin/env bash
# Q-Shield: Stage 2 - Classical WireGuard Setup
# Configures a baseline WireGuard tunnel between qs-server and qs-client.
# Idempotent and fails safely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

echo "[*] Initializing Q-Shield Stage 2: Classical WireGuard Tunnel..."

# Step 1: Verify Stage 1 namespaces exist
if ! ip netns list | grep -qw "qs-server" || ! ip netns list | grep -qw "qs-client"; then
    echo "[-] Error: Stage 1 namespaces (qs-server / qs-client) are missing." >&2
    echo "    Please execute: bash $SCRIPT_DIR/setup_namespaces.sh first." >&2
    exit 1
fi

# Step 2: Prepare secure key storage (mode 0700)
# We store keys in the native Linux path to enforce strict 0600 POSIX permissions.
KEYS_DIR="/etc/wireguard/qshield/keys"
mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

# Generate keys if they do not already exist (idempotent key management)
umask 077
if [ ! -f "$KEYS_DIR/server_private.key" ] || [ ! -f "$KEYS_DIR/server_public.key" ]; then
    echo "    - Generating server WireGuard keypair..."
    wg genkey > "$KEYS_DIR/server_private.key"
    chmod 0600 "$KEYS_DIR/server_private.key"
    wg pubkey < "$KEYS_DIR/server_private.key" > "$KEYS_DIR/server_public.key"
    chmod 0644 "$KEYS_DIR/server_public.key"
fi

if [ ! -f "$KEYS_DIR/client_private.key" ] || [ ! -f "$KEYS_DIR/client_public.key" ]; then
    echo "    - Generating client WireGuard keypair..."
    wg genkey > "$KEYS_DIR/client_private.key"
    chmod 0600 "$KEYS_DIR/client_private.key"
    wg pubkey < "$KEYS_DIR/client_private.key" > "$KEYS_DIR/client_public.key"
    chmod 0644 "$KEYS_DIR/client_public.key"
fi

SERVER_PUB="$(cat "$KEYS_DIR/server_public.key")"
CLIENT_PUB="$(cat "$KEYS_DIR/client_public.key")"

# Step 3: Configure qs-server wg0 (idempotent)
echo "    - Configuring server WireGuard interface (10.0.0.1/24 on port 51820)..."
ip netns exec qs-server ip link del dev wg0 2>/dev/null || true
ip netns exec qs-server ip link add dev wg0 type wireguard
ip netns exec qs-server ip addr add 10.0.0.1/24 dev wg0

ip netns exec qs-server wg set wg0 \
    listen-port 51820 \
    private-key "$KEYS_DIR/server_private.key" \
    peer "$CLIENT_PUB" \
    allowed-ips 10.0.0.2/32

ip netns exec qs-server ip link set dev wg0 up

# Step 4: Configure qs-client wg0 (idempotent)
echo "    - Configuring client WireGuard interface (10.0.0.2/24 -> 10.100.0.1:51820)..."
ip netns exec qs-client ip link del dev wg0 2>/dev/null || true
ip netns exec qs-client ip link add dev wg0 type wireguard
ip netns exec qs-client ip addr add 10.0.0.2/24 dev wg0

ip netns exec qs-client wg set wg0 \
    private-key "$KEYS_DIR/client_private.key" \
    peer "$SERVER_PUB" \
    endpoint 10.100.0.1:51820 \
    allowed-ips 10.0.0.0/24 \
    persistent-keepalive 5

ip netns exec qs-client ip link set dev wg0 up

# Step 5: Wait for initial WireGuard handshake
echo "    - Waiting for WireGuard handshake..."
HANDSHAKE_ESTABLISHED=false
MAX_RETRIES=20

for i in $(seq 1 "$MAX_RETRIES"); do
    LATEST_HS="$(ip netns exec qs-client wg show wg0 latest-handshakes | awk '{print $2}')"
    if [ -n "$LATEST_HS" ] && [ "$LATEST_HS" -gt 0 ]; then
        NOW="$(date +%s)"
        HS_AGE=$((NOW - LATEST_HS))
        if [ "$HS_AGE" -le 10 ]; then
            HANDSHAKE_ESTABLISHED=true
            echo "    [+] WireGuard handshake established (age: ${HS_AGE}s)"
            break
        fi
    fi
    sleep 0.5
done

if [ "$HANDSHAKE_ESTABLISHED" = false ]; then
    echo "[-] Error: WireGuard handshake failed to establish within timeout." >&2
    exit 1
fi

echo "[+] Stage 2 WireGuard tunnel established successfully."