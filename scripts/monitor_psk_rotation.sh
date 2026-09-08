#!/usr/bin/env bash
# Q-Shield: Stage 4 - PSK Rotation Monitor
# Safely monitors WireGuard preshared key updates across qs-server and qs-client.
# Uses non-secret cryptographic SHA-256 fingerprints; NEVER outputs or logs raw PSKs.
set -euo pipefail

TARGET_EPOCHS=3
POLL_INTERVAL=2
MAX_TIMEOUT=600
JSON_OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epochs)
            TARGET_EPOCHS="$2"
            shift 2
            ;;
        --interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --timeout)
            MAX_TIMEOUT="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT="$2"
            shift 2
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

# Color helpers
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

get_fingerprint() {
    local ns="$1"
    ip netns exec "$ns" wg show wg0 preshared-keys 2>/dev/null | awk '{print $2}' | sha256sum | awk '{print $1}'
}

echo -e "\n${BOLD}========================================================================${NC}"
echo -e "${BOLD}   Q-Shield: Post-Quantum PSK Rotation Observability Monitor            ${NC}"
echo -e "${BOLD}   Target Epochs: $TARGET_EPOCHS | Poll Frequency: ${POLL_INTERVAL}s | Max Timeout: ${MAX_TIMEOUT}s ${NC}"
echo -e "${BOLD}========================================================================${NC}\n"

printf "%-8s | %-25s | %-24s | %-24s | %-7s | %-12s\n" \
    "EPOCH" "TIMESTAMP" "SERVER FINGERPRINT" "CLIENT FINGERPRINT" "MATCH" "INTERVAL"
echo "---------------------------------------------------------------------------------------------------------"

START_TIME="$(date +%s)"
CURRENT_EPOCH=1
PREV_ROTATION_TIME="$START_TIME"
PREV_SERVER_FP=""

declare -a EPOCH_NUMS=()
declare -a EPOCH_TIMESTAMPS=()
declare -a EPOCH_SERVER_FPS=()
declare -a EPOCH_CLIENT_FPS=()
declare -a EPOCH_MATCHES=()
declare -a EPOCH_INTERVALS=()

# Initial observation (Epoch 1)
SRV_FP="$(get_fingerprint "qs-server")"
CLI_FP="$(get_fingerprint "qs-client")"

if [ -z "$SRV_FP" ] || [ -z "$CLI_FP" ]; then
    echo "[-] Error: WireGuard preshared key is not configured. Is Stage 3 active?" >&2
    exit 1
fi

MATCH="NO"
if [ "$SRV_FP" = "$CLI_FP" ]; then
    MATCH="YES"
fi

TS_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SRV_TRUNC="${SRV_FP:0:10}...${SRV_FP: -8}"
CLI_TRUNC="${CLI_FP:0:10}...${CLI_FP: -8}"

printf "${CYAN}%-8s${NC} | %-25s | %-24s | %-24s | ${GREEN}%-7s${NC} | %-12s\n" \
    "Epoch 1" "$TS_ISO" "$SRV_TRUNC" "$CLI_TRUNC" "$MATCH" "Baseline"

EPOCH_NUMS+=(1)
EPOCH_TIMESTAMPS+=("$TS_ISO")
EPOCH_SERVER_FPS+=("$SRV_FP")
EPOCH_CLIENT_FPS+=("$CLI_FP")
EPOCH_MATCHES+=("$MATCH")
EPOCH_INTERVALS+=(0)

PREV_SERVER_FP="$SRV_FP"

while [ "$CURRENT_EPOCH" -lt "$TARGET_EPOCHS" ]; do
    NOW="$(date +%s)"
    ELAPSED=$((NOW - START_TIME))
    if [ "$ELAPSED" -ge "$MAX_TIMEOUT" ]; then
        echo -e "\n[-] Warning: Max timeout ($MAX_TIMEOUT s) reached before observing $TARGET_EPOCHS epochs." >&2
        break
    fi

    sleep "$POLL_INTERVAL"

    NEW_SRV_FP="$(get_fingerprint "qs-server")"
    NEW_CLI_FP="$(get_fingerprint "qs-client")"

    if [ -n "$NEW_SRV_FP" ] && [ "$NEW_SRV_FP" != "$PREV_SERVER_FP" ]; then
        ROTATION_NOW="$(date +%s)"
        INTERVAL=$((ROTATION_NOW - PREV_ROTATION_TIME))
        CURRENT_EPOCH=$((CURRENT_EPOCH + 1))
        
        MATCH="NO"
        if [ "$NEW_SRV_FP" = "$NEW_CLI_FP" ]; then
            MATCH="YES"
        fi

        TS_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        SRV_TRUNC="${NEW_SRV_FP:0:10}...${NEW_SRV_FP: -8}"
        CLI_TRUNC="${NEW_CLI_FP:0:10}...${NEW_CLI_FP: -8}"

        printf "${GREEN}%-8s${NC} | %-25s | %-24s | %-24s | ${GREEN}%-7s${NC} | %-12s\n" \
            "Epoch $CURRENT_EPOCH" "$TS_ISO" "$SRV_TRUNC" "$CLI_TRUNC" "$MATCH" "${INTERVAL}s"

        EPOCH_NUMS+=("$CURRENT_EPOCH")
        EPOCH_TIMESTAMPS+=("$TS_ISO")
        EPOCH_SERVER_FPS+=("$NEW_SRV_FP")
        EPOCH_CLIENT_FPS+=("$NEW_CLI_FP")
        EPOCH_MATCHES+=("$MATCH")
        EPOCH_INTERVALS+=("$INTERVAL")

        PREV_SERVER_FP="$NEW_SRV_FP"
        PREV_ROTATION_TIME="$ROTATION_NOW"
    fi
done

echo -e "\n[+] Monitoring complete. Observed $CURRENT_EPOCH epochs."

if [ -n "$JSON_OUTPUT" ]; then
    python3 - << PYEOF
import json

epochs = []
nums = [int(x) for x in """$(printf '%s\n' "${EPOCH_NUMS[@]}")""".strip().split('\n') if x]
ts = """$(printf '%s\n' "${EPOCH_TIMESTAMPS[@]}")""".strip().split('\n')
s_fps = """$(printf '%s\n' "${EPOCH_SERVER_FPS[@]}")""".strip().split('\n')
c_fps = """$(printf '%s\n' "${EPOCH_CLIENT_FPS[@]}")""".strip().split('\n')
matches = """$(printf '%s\n' "${EPOCH_MATCHES[@]}")""".strip().split('\n')
intervals = [int(x) for x in """$(printf '%s\n' "${EPOCH_INTERVALS[@]}")""".strip().split('\n') if x]

for i in range(len(nums)):
    epochs.append({
        "epoch": nums[i],
        "timestamp": ts[i],
        "server_fingerprint_sha256": s_fps[i],
        "client_fingerprint_sha256": c_fps[i],
        "fingerprints_match": True if matches[i] == "YES" else False,
        "interval_seconds": intervals[i]
    })

data = {
    "total_epochs_observed": len(nums),
    "epochs": epochs
}

with open("$JSON_OUTPUT", "w") as f:
    json.dump(data, f, indent=2)

print("[+] Wrote rotation metadata to: $JSON_OUTPUT")
PYEOF
fi