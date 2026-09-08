#!/usr/bin/env bash
# Q-Shield: Idempotent Network Namespace Setup
# Creates isolated namespaces qs-server and qs-client linked via a veth pair.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (or via sudo/wsl -u root)." >&2
    exit 1
fi

echo "[*] Setting up Q-Shield network namespaces (idempotent)..."

# Step 1: Clean up any existing namespaces or dangling veth interfaces first
if [ -f "$SCRIPT_DIR/teardown_namespaces.sh" ]; then
    bash "$SCRIPT_DIR/teardown_namespaces.sh" >/dev/null 2>&1 || true
fi

# Step 2: Create isolated network namespaces
echo "    - Creating network namespaces: qs-server and qs-client"
ip netns add qs-server
ip netns add qs-client

# Step 3: Create virtual ethernet (veth) pair
echo "    - Creating virtual ethernet pair: veth-server <-> veth-client"
ip link add veth-server type veth peer name veth-client

# Step 4: Move interfaces into their respective namespaces
echo "    - Moving veth-server to qs-server and veth-client to qs-client"
ip link set veth-server netns qs-server
ip link set veth-client netns qs-client

# Step 5: Configure qs-server network stack
echo "    - Configuring qs-server (10.100.0.1/24 on veth-server)"
ip netns exec qs-server ip addr add 10.100.0.1/24 dev veth-server
ip netns exec qs-server ip link set veth-server up
ip netns exec qs-server ip link set lo up
ip netns exec qs-server sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true

# Step 6: Configure qs-client network stack
echo "    - Configuring qs-client (10.100.0.2/24 on veth-client)"
ip netns exec qs-client ip addr add 10.100.0.2/24 dev veth-client
ip netns exec qs-client ip link set veth-client up
ip netns exec qs-client ip link set lo up
ip netns exec qs-client sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true

echo "[+] Network namespaces setup successfully."