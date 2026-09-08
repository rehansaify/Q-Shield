#!/usr/bin/env bash
# Q-Shield: Stage 2 - WireGuard Teardown
# Safely tears down wg0 interfaces while leaving Stage 1 namespaces intact.
set -euo pipefail

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

echo "[*] Tearing down Stage 2 WireGuard interfaces..."

# Remove wg0 from qs-server if it exists
if ip netns list | grep -qw "qs-server"; then
    if ip netns exec qs-server ip link show dev wg0 >/dev/null 2>&1; then
        echo "    - Removing wg0 from qs-server"
        ip netns exec qs-server ip link del dev wg0 || true
    else
        echo "    - wg0 not present in qs-server (skipping)"
    fi
fi

# Remove wg0 from qs-client if it exists
if ip netns list | grep -qw "qs-client"; then
    if ip netns exec qs-client ip link show dev wg0 >/dev/null 2>&1; then
        echo "    - Removing wg0 from qs-client"
        ip netns exec qs-client ip link del dev wg0 || true
    else
        echo "    - wg0 not present in qs-client (skipping)"
    fi
fi

echo "[+] Stage 2 WireGuard interfaces removed. Stage 1 namespaces remain intact."