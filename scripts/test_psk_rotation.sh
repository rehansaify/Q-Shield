#!/usr/bin/env bash
# Q-Shield: Stage 4 - PSK Rotation Verification Test
# Observes at least 3 distinct PSK epochs (2 transitions: A -> B -> C),
# asserting A != B != C, mutual convergence between peers, and measuring rotation intervals.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JSON_OUT="${1:-$ROOT_DIR/results/psk_rotation_test.json}"

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

get_fp() {
    local ns="$1"
    ip netns exec "$ns" wg show wg0 preshared-keys 2>/dev/null | awk '{print $2}' | sha256sum | awk '{print $1}'
}

echo -e "\n${BOLD}========================================================================${NC}"
echo -e "${BOLD}   Q-Shield Stage 4: Rosenpass Periodic PSK Rotation Verification      ${NC}"
echo -e "${BOLD}========================================================================${NC}\n"

# Step 1: Pre-flight checks
echo "[*] Step 1: Verifying Stage 3 prerequisites..."
if ! ip netns exec qs-server wg show wg0 | grep -q "preshared key:" || \
   ! ip netns exec qs-client wg show wg0 | grep -q "preshared key:"; then
    echo "[-] Error: WireGuard preshared key is missing. Ensure Stage 3 is active." >&2
    exit 1
fi

SERVER_PIDS="$(pgrep -f "rosenpass.*10.100.0.1:9999" || pgrep -f "rosenpass.*server" || true)"
CLIENT_PIDS="$(pgrep -f "rosenpass.*10.100.0.2:9999" || pgrep -f "rosenpass.*client" || true)"

if [ -z "$SERVER_PIDS" ] || [ -z "$CLIENT_PIDS" ]; then
    echo "[-] Error: One or both Rosenpass processes are not running." >&2
    exit 1
fi

if ! ip netns exec qs-client ping -c 2 -W 1 10.0.0.1 >/dev/null 2>&1; then
    echo "[-] Error: WireGuard tunnel is not passing traffic before test." >&2
    exit 1
fi
echo "    [+] Prerequisites verified: Rosenpass active and tunnel operational."

# Step 2: Epoch 1 (PSK-A)
echo -e "\n[*] Step 2: Capturing Epoch 1 (PSK-A)..."
FP1_SRV="$(get_fp "qs-server")"
FP1_CLI="$(get_fp "qs-client")"
TS1="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
T1_EPOCH="$(date +%s)"

if [ "$FP1_SRV" != "$FP1_CLI" ] || [ -z "$FP1_SRV" ]; then
    echo "[-] Error: Epoch 1 fingerprints do not match between server and client!" >&2
    exit 1
fi
echo "    [+] Epoch 1 confirmed (Server == Client: ${FP1_SRV:0:12}...${FP1_SRV: -8}) at $TS1"

# Step 3: Wait for Epoch 2 (PSK-B)
echo -e "\n[*] Step 3: Waiting for next Rosenpass periodic rotation (Epoch 2 / PSK-B)..."
echo "    (Rosenpass rotates approximately every 120 seconds. Polling every 2s...)"
FP2_SRV=""
FP2_CLI=""
T2_EPOCH=0
INTERVAL_1=0

while true; do
    sleep 2
    CUR_SRV="$(get_fp "qs-server")"
    if [ "$CUR_SRV" != "$FP1_SRV" ]; then
        # Allow client a moment to converge if not simultaneous
        sleep 0.5
        CUR_CLI="$(get_fp "qs-client")"
        T2_EPOCH="$(date +%s)"
        TS2="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        INTERVAL_1=$((T2_EPOCH - T1_EPOCH))
        FP2_SRV="$CUR_SRV"
        FP2_CLI="$CUR_CLI"
        break
    fi
done

if [ "$FP2_SRV" != "$FP2_CLI" ]; then
    echo "[-] Error: Epoch 2 fingerprints mismatch! (Server: $FP2_SRV, Client: $FP2_CLI)" >&2
    exit 1
fi
if [ "$FP2_SRV" = "$FP1_SRV" ]; then
    echo "[-] Error: PSK-B is identical to PSK-A!" >&2
    exit 1
fi
echo "    [+] Epoch 2 confirmed (Server == Client: ${FP2_SRV:0:12}...${FP2_SRV: -8}) at $TS2"
echo "    [+] Interval 1 (Epoch 1 -> Epoch 2): ${INTERVAL_1}s"
echo "    [+] Assertion Passed: PSK-A != PSK-B"

# Step 4: Wait for Epoch 3 (PSK-C)
echo -e "\n[*] Step 4: Waiting for next Rosenpass periodic rotation (Epoch 3 / PSK-C)..."
FP3_SRV=""
FP3_CLI=""
T3_EPOCH=0
INTERVAL_2=0

while true; do
    sleep 2
    CUR_SRV="$(get_fp "qs-server")"
    if [ "$CUR_SRV" != "$FP2_SRV" ]; then
        sleep 0.5
        CUR_CLI="$(get_fp "qs-client")"
        T3_EPOCH="$(date +%s)"
        TS3="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        INTERVAL_2=$((T3_EPOCH - T2_EPOCH))
        FP3_SRV="$CUR_SRV"
        FP3_CLI="$CUR_CLI"
        break
    fi
done

if [ "$FP3_SRV" != "$FP3_CLI" ]; then
    echo "[-] Error: Epoch 3 fingerprints mismatch! (Server: $FP3_SRV, Client: $FP3_CLI)" >&2
    exit 1
fi
if [ "$FP3_SRV" = "$FP2_SRV" ]; then
    echo "[-] Error: PSK-C is identical to PSK-B!" >&2
    exit 1
fi
echo "    [+] Epoch 3 confirmed (Server == Client: ${FP3_SRV:0:12}...${FP3_SRV: -8}) at $TS3"
echo "    [+] Interval 2 (Epoch 2 -> Epoch 3): ${INTERVAL_2}s"
echo "    [+] Assertion Passed: PSK-B != PSK-C"

# Calculate timing metrics
MIN_INTERVAL=$INTERVAL_1
MAX_INTERVAL=$INTERVAL_1
if [ "$INTERVAL_2" -lt "$MIN_INTERVAL" ]; then MIN_INTERVAL=$INTERVAL_2; fi
if [ "$INTERVAL_2" -gt "$MAX_INTERVAL" ]; then MAX_INTERVAL=$INTERVAL_2; fi
AVG_INTERVAL=$(( (INTERVAL_1 + INTERVAL_2) / 2 ))

echo -e "\n------------------------------------------------------------------------"
echo -e "${GREEN}${BOLD}ROTATION TEST RESULTS:${NC}"
echo -e "  - Epoch 1: ${FP1_SRV:0:12}...${FP1_SRV: -8} ($TS1)"
echo -e "  - Epoch 2: ${FP2_SRV:0:12}...${FP2_SRV: -8} ($TS2) [Interval: ${INTERVAL_1}s]"
echo -e "  - Epoch 3: ${FP3_SRV:0:12}...${FP3_SRV: -8} ($TS3) [Interval: ${INTERVAL_2}s]"
echo -e "  - Timing: Min: ${MIN_INTERVAL}s | Max: ${MAX_INTERVAL}s | Avg: ${AVG_INTERVAL}s"
echo -e "  - Cryptographic assertions (A != B, B != C, Server == Client): ${GREEN}PASSED${NC}"
echo -e "------------------------------------------------------------------------\n"

# Export test metadata to JSON
python3 - << PYEOF
import json

data = {
    "test_name": "Rosenpass Periodic PSK Rotation Test",
    "status": "PASS",
    "epochs_observed": 3,
    "transitions": [
        {
            "from_epoch": 1,
            "to_epoch": 2,
            "interval_seconds": $INTERVAL_1,
            "timestamp": "$TS2"
        },
        {
            "from_epoch": 2,
            "to_epoch": 3,
            "interval_seconds": $INTERVAL_2,
            "timestamp": "$TS3"
        }
    ],
    "intervals_seconds": [$INTERVAL_1, $INTERVAL_2],
    "min_interval_seconds": $MIN_INTERVAL,
    "max_interval_seconds": $MAX_INTERVAL,
    "average_interval_seconds": float($AVG_INTERVAL),
    "epochs": [
        {"epoch": 1, "timestamp": "$TS1", "fingerprint_sha256": "$FP1_SRV", "match": True},
        {"epoch": 2, "timestamp": "$TS2", "fingerprint_sha256": "$FP2_SRV", "match": True},
        {"epoch": 3, "timestamp": "$TS3", "fingerprint_sha256": "$FP3_SRV", "match": True}
    ],
    "security": {
        "raw_psk_exposed": False,
        "private_keys_exposed": False
    }
}

with open("$JSON_OUT", "w") as f:
    json.dump(data, f, indent=2)

print("[+] Saved rotation test results to: $JSON_OUT")
PYEOF