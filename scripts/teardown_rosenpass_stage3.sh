#!/usr/bin/env bash
# Q-Shield: Stage 3 - Rosenpass Teardown
# Stops Rosenpass processes, clears the WireGuard PSK, and restores Stage 2 classical baseline.
set -euo pipefail

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

echo "[*] Tearing down Stage 3 Rosenpass integration..."

# 1. Terminate all Rosenpass instances
echo "    - Stopping Rosenpass processes..."
killall -9 rosenpass 2>/dev/null || true
rm -f /var/run/qshield/rosenpass-server.pid /var/run/qshield/rosenpass-client.pid

# 2. Reset WireGuard PSK on both peers (clears PSK to restore Stage 2 baseline)
WG_KEYS_DIR="/etc/wireguard/qshield/keys"
if [ -f "$WG_KEYS_DIR/client_public.key" ] && [ -f "$WG_KEYS_DIR/server_public.key" ]; then
    CLIENT_WG_PUB="$(cat "$WG_KEYS_DIR/client_public.key")"
    SERVER_WG_PUB="$(cat "$WG_KEYS_DIR/server_public.key")"

    echo "    - Removing WireGuard preshared keys (restoring classical baseline)..."
    if ip netns list | grep -qw "qs-server" && ip netns exec qs-server ip link show dev wg0 >/dev/null 2>&1; then
        ip netns exec qs-server wg set wg0 peer "$CLIENT_WG_PUB" preshared-key /dev/null 2>/dev/null || true
    fi

    if ip netns list | grep -qw "qs-client" && ip netns exec qs-client ip link show dev wg0 >/dev/null 2>&1; then
        ip netns exec qs-client wg set wg0 peer "$SERVER_WG_PUB" preshared-key /dev/null 2>/dev/null || true
    fi
fi

# 3. Refresh baseline WireGuard handshake
if ip netns list | grep -qw "qs-client" && ip netns exec qs-client ip link show dev wg0 >/dev/null 2>&1; then
    ip netns exec qs-client ip link set dev wg0 down 2>/dev/null || true
    ip netns exec qs-client ip link set dev wg0 up 2>/dev/null || true
    sleep 0.5
    ip netns exec qs-client ping -c 2 -W 1 10.0.0.1 >/dev/null 2>&1 || true
fi

echo "[+] Stage 3 teardown complete. Stage 2 classical WireGuard baseline restored."