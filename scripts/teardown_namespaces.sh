#!/usr/bin/env bash
# Q-Shield: Safe and Idempotent Network Namespace Teardown
set -euo pipefail

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (or via sudo/wsl -u root)." >&2
    exit 1
fi

echo "[*] Tearing down Q-Shield network namespaces and virtual links..."

# Safely delete namespaces (this automatically tears down interfaces inside them)
for ns in qs-server qs-client; do
    if ip netns list | grep -qw "$ns"; then
        echo "    - Removing network namespace: $ns"
        ip netns del "$ns" || true
    else
        echo "    - Network namespace $ns not present (skipping)"
    fi
done

# Clean up any stray veth links in root namespace if any
for iface in veth-server veth-client; do
    if ip link show "$iface" >/dev/null 2>&1; then
        echo "    - Removing stray link: $iface"
        ip link del "$iface" || true
    fi
done

echo "[+] Teardown completed successfully."