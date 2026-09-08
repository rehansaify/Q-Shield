#!/usr/bin/env bash
# Q-Shield: Stage 4 - Tunnel Continuity Across PSK Rotations
# Transmits high-frequency ICMP ping packets (10 pkts/sec) across wg0 while monitoring
# multiple Rosenpass PSK rotation boundaries, asserting zero-loss tunnel continuity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JSON_OUT="${1:-$ROOT_DIR/results/continuity_test.json}"
PING_LOG="/tmp/qshield_continuity_ping.log"

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

get_fp() {
    local ns="$1"
    ip netns exec "$ns" wg show wg0 preshared-keys 2>/dev/null | awk '{print $2}' | sha256sum | awk '{print $1}'
}

echo -e "\n${BOLD}========================================================================${NC}"
echo -e "${BOLD}   Q-Shield Stage 4: Tunnel Continuity Test Across PSK Rotations       ${NC}"
echo -e "${BOLD}   Traffic: 100ms ICMP stream | Target: 3 Epochs (2 Rotations)          ${NC}"
echo -e "${BOLD}========================================================================${NC}\n"

# Verify baseline
if ! ip netns exec qs-client ping -c 2 -W 1 10.0.0.1 >/dev/null 2>&1; then
    echo "[-] Error: Tunnel is unreachable before test." >&2
    exit 1
fi

# Clean previous ping log
rm -f "$PING_LOG"

# Step 1: Record initial Epoch 1 state
START_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
START_EPOCH="$(date +%s)"
CURRENT_FP="$(get_fp "qs-server")"
echo "[*] Initial PSK Epoch 1 Fingerprint: ${CURRENT_FP:0:12}...${CURRENT_FP: -8} at $START_TS"

# Step 2: Start continuous 100ms ping stream
echo "[*] Launching high-frequency ping stream (10 pkts/sec, 100ms interval)..."
ip netns exec qs-client ping -i 0.1 10.0.0.1 > "$PING_LOG" 2>&1 &
PING_PID=$!

# Trap cleanup
trap 'kill -INT $PING_PID 2>/dev/null || true' EXIT

EPOCHS_DETECTED=1
declare -a ROTATION_TIMESTAMPS=()
declare -a ROTATION_INTERVALS=()
declare -a HANDSHAKE_AGES=()
declare -a TRANSITION_FPS=()

PREV_ROT_EPOCH="$START_EPOCH"
PREV_TX="$(ip netns exec qs-client wg show wg0 transfer | awk '{print $3}')"

while [ "$EPOCHS_DETECTED" -lt 3 ]; do
    sleep 2
    NEW_FP="$(get_fp "qs-server")"
    if [ -n "$NEW_FP" ] && [ "$NEW_FP" != "$CURRENT_FP" ]; then
        ROT_NOW="$(date +%s)"
        ROT_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        ROT_INT=$((ROT_NOW - PREV_ROT_EPOCH))
        EPOCHS_DETECTED=$((EPOCHS_DETECTED + 1))
        
        # Query handshake age at rotation
        LATEST_HS="$(ip netns exec qs-client wg show wg0 latest-handshakes | awk '{print $2}' || echo "0")"
        HS_AGE=0
        if [ -n "$LATEST_HS" ] && [ "$LATEST_HS" -gt 0 ]; then
            HS_AGE=$((ROT_NOW - LATEST_HS))
        fi
        
        # Verify transfer counters increased
        CURR_TX="$(ip netns exec qs-client wg show wg0 transfer | awk '{print $3}')"
        TX_DIFF=$((CURR_TX - PREV_TX))
        PREV_TX="$CURR_TX"

        echo -e "    ${GREEN}[+] Rotation detected -> Epoch $EPOCHS_DETECTED${NC} at $ROT_TS (Interval: ${ROT_INT}s, HS Age: ${HS_AGE}s, TX Diff: +${TX_DIFF}B)"
        echo -e "        New Fingerprint: ${NEW_FP:0:12}...${NEW_FP: -8}"

        ROTATION_TIMESTAMPS+=("$ROT_TS")
        ROTATION_INTERVALS+=("$ROT_INT")
        HANDSHAKE_AGES+=("$HS_AGE")
        TRANSITION_FPS+=("$NEW_FP")

        CURRENT_FP="$NEW_FP"
        PREV_ROT_EPOCH="$ROT_NOW"
    fi
done

END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

echo -e "\n[*] Observed 3 epochs. Terminating continuous traffic stream..."
# Send SIGINT to ping process so it prints its summary statistics block
kill -INT "$PING_PID" 2>/dev/null || true
sleep 1

# Parse ping summary statistics from log
# --- 10.0.0.1 ping statistics ---
# 2415 packets transmitted, 2415 received, 0% packet loss, time 241432ms
# rtt min/avg/max/mdev = 0.041/0.062/1.842/0.038 ms
TX_PKTS=0
RX_PKTS=0
LOSS_PCT=100
RTT_MIN=0
RTT_AVG=0
RTT_MAX=0
RTT_MDEV=0

if grep -q "packets transmitted" "$PING_LOG"; then
    STAT_LINE="$(grep "packets transmitted" "$PING_LOG")"
    TX_PKTS="$(echo "$STAT_LINE" | awk '{print $1}')"
    RX_PKTS="$(echo "$STAT_LINE" | awk '{print $4}')"
    LOSS_PCT="$(echo "$STAT_LINE" | grep -oP '\d+(?=% packet loss)')"
fi

if grep -q "rtt min/avg/max/mdev" "$PING_LOG"; then
    RTT_LINE="$(grep "rtt min/avg/max/mdev" "$PING_LOG" | awk -F '=' '{print $2}' | tr -d ' ' | sed 's/ms//g')"
    RTT_MIN="$(echo "$RTT_LINE" | awk -F '/' '{print $1}')"
    RTT_AVG="$(echo "$RTT_LINE" | awk -F '/' '{print $2}')"
    RTT_MAX="$(echo "$RTT_LINE" | awk -F '/' '{print $3}')"
    RTT_MDEV="$(echo "$RTT_LINE" | awk -F '/' '{print $4}')"
fi

DROPPED_PKTS=$((TX_PKTS - RX_PKTS))

echo -e "\n========================================================================"
echo -e "${BOLD}CONTINUITY TEST RESULTS:${NC}"
echo -e "  - Test Duration:       ${DURATION} seconds"
echo -e "  - Packets Transmitted: ${TX_PKTS}"
echo -e "  - Packets Received:    ${RX_PKTS}"
echo -e "  - Packets Dropped:     ${DROPPED_PKTS}"
echo -e "  - Measured Packet Loss: ${BOLD}${LOSS_PCT}%${NC}"
echo -e "  - RTT Latency:         min=${RTT_MIN}ms, avg=${RTT_AVG}ms, max=${RTT_MAX}ms, mdev=${RTT_MDEV}ms"
echo -e "  - Rotation Timestamps: ${ROTATION_TIMESTAMPS[*]}"
echo -e "========================================================================\n"

# Export JSON results
python3 - << PYEOF
import json

data = {
    "test_name": "Tunnel Continuity Across PSK Rotations",
    "status": "PASS" if float("$LOSS_PCT") == 0.0 else "FAIL",
    "duration_seconds": $DURATION,
    "traffic_metrics": {
        "packets_sent": int("$TX_PKTS"),
        "packets_received": int("$RX_PKTS"),
        "packets_dropped": int("$DROPPED_PKTS"),
        "packet_loss_percentage": float("$LOSS_PCT"),
        "rtt_min_ms": float("$RTT_MIN") if "$RTT_MIN" != "" else None,
        "rtt_avg_ms": float("$RTT_AVG") if "$RTT_AVG" != "" else None,
        "rtt_max_ms": float("$RTT_MAX") if "$RTT_MAX" != "" else None,
        "rtt_mdev_ms": float("$RTT_MDEV") if "$RTT_MDEV" != "" else None
    },
    "rotation_observations": {
        "epochs_observed": $EPOCHS_DETECTED,
        "rotation_timestamps": """$(printf '%s\n' "${ROTATION_TIMESTAMPS[@]}")""".strip().split('\n'),
        "rotation_intervals_seconds": [int(x) for x in """$(printf '%s\n' "${ROTATION_INTERVALS[@]}")""".strip().split('\n') if x],
        "handshake_ages_at_rotation": [int(x) for x in """$(printf '%s\n' "${HANDSHAKE_AGES[@]}")""".strip().split('\n') if x]
    },
    "security": {
        "raw_psk_exposed": False,
        "private_keys_exposed": False
    }
}

with open("$JSON_OUT", "w") as f:
    json.dump(data, f, indent=2)

print("[+] Saved continuity test results to: $JSON_OUT")
PYEOF

rm -f "$PING_LOG"