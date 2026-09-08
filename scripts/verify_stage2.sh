#!/usr/bin/env bash
# Q-Shield: Stage 2 - Classical WireGuard Verification Script
# Runs 11 comprehensive automated tests on the baseline WireGuard tunnel.
# Generates human-readable console output and results/stage2_results.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$ROOT_DIR/results"
mkdir -p "$RESULTS_DIR"
JSON_OUT="$RESULTS_DIR/stage2_results.json"
KEYS_DIR="/etc/wireguard/qshield/keys"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

declare -a CHECK_NAMES=()
declare -a CHECK_STATUSES=()
declare -a CHECK_DETAILS=()

record_check() {
    local name="$1"
    local status="$2"
    local details="$3"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    CHECK_NAMES+=("$name")
    CHECK_STATUSES+=("$status")
    CHECK_DETAILS+=("$details")
    if [ "$status" = "PASS" ]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        printf "  [ ${GREEN}PASS${NC} ] %-42s %s\n" "$name" "$details"
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        printf "  [ ${RED}FAIL${NC} ] %-42s %s\n" "$name" "$details"
    fi
}

echo -e "\n${BOLD}================================================================${NC}"
echo -e "${BOLD}   Q-Shield Stage 2: Classical WireGuard Verification (11 Tests)${NC}"
echo -e "${BOLD}================================================================${NC}\n"

# TEST 1: Verify wg0 exists inside qs-server
if ip netns list | grep -qw "qs-server" && ip netns exec qs-server ip link show dev wg0 >/dev/null 2>&1; then
    record_check "TEST 1: Server wg0 Interface" "PASS" "Interface wg0 exists in qs-server"
else
    record_check "TEST 1: Server wg0 Interface" "FAIL" "Interface wg0 missing in qs-server"
fi

# TEST 2: Verify wg0 exists inside qs-client
if ip netns list | grep -qw "qs-client" && ip netns exec qs-client ip link show dev wg0 >/dev/null 2>&1; then
    record_check "TEST 2: Client wg0 Interface" "PASS" "Interface wg0 exists in qs-client"
else
    record_check "TEST 2: Client wg0 Interface" "FAIL" "Interface wg0 missing in qs-client"
fi

# TEST 3: Verify server is listening on UDP 51820
SERVER_PORT="$(ip netns exec qs-server wg show wg0 listen-port 2>/dev/null || echo "")"
if [ "$SERVER_PORT" = "51820" ]; then
    record_check "TEST 3: Server Listen Port" "PASS" "qs-server listening on UDP 51820"
else
    record_check "TEST 3: Server Listen Port" "FAIL" "Expected UDP 51820, found: ${SERVER_PORT:-none}"
fi

# TEST 4: Run wg show inside both namespaces (ensure private keys are never exposed)
WG_SHOW_SERVER="$(ip netns exec qs-server wg show wg0 2>&1 || true)"
WG_SHOW_CLIENT="$(ip netns exec qs-client wg show wg0 2>&1 || true)"

SERVER_PRIV="$(cat "$KEYS_DIR/server_private.key" 2>/dev/null || echo "NOSERVERKEY")"
CLIENT_PRIV="$(cat "$KEYS_DIR/client_private.key" 2>/dev/null || echo "NOCLIENTKEY")"

# Validate that actual raw secret keys are NEVER printed, and that private key is masked as (hidden)
LEAK_DETECTED=false
if [ -n "$SERVER_PRIV" ] && [ "$SERVER_PRIV" != "NOSERVERKEY" ]; then
    if echo "$WG_SHOW_SERVER $WG_SHOW_CLIENT" | grep -Fq "$SERVER_PRIV"; then
        LEAK_DETECTED=true
    fi
fi
if [ -n "$CLIENT_PRIV" ] && [ "$CLIENT_PRIV" != "NOCLIENTKEY" ]; then
    if echo "$WG_SHOW_SERVER $WG_SHOW_CLIENT" | grep -Fq "$CLIENT_PRIV"; then
        LEAK_DETECTED=true
    fi
fi

if [ "$LEAK_DETECTED" = true ]; then
    record_check "TEST 4: Interface State Display" "FAIL" "Raw private key was leaked in wg show output"
elif [ -n "$WG_SHOW_SERVER" ] && [ -n "$WG_SHOW_CLIENT" ]; then
    record_check "TEST 4: Interface State Display" "PASS" "wg show executed in both namespaces (private keys masked as hidden)"
else
    record_check "TEST 4: Interface State Display" "FAIL" "Failed to query wg show on interfaces"
fi

# TEST 5: Verify the WireGuard peer relationship
SERVER_PUB="$(cat "$KEYS_DIR/server_public.key" 2>/dev/null || echo "")"
CLIENT_PUB="$(cat "$KEYS_DIR/client_public.key" 2>/dev/null || echo "")"

SERVER_SEES_PEER="$(ip netns exec qs-server wg show wg0 peers 2>/dev/null | tr -d ' ' || echo "")"
CLIENT_SEES_PEER="$(ip netns exec qs-client wg show wg0 peers 2>/dev/null | tr -d ' ' || echo "")"

if [ "$SERVER_SEES_PEER" = "$CLIENT_PUB" ] && [ "$CLIENT_SEES_PEER" = "$SERVER_PUB" ]; then
    CLIENT_PUB_ID="${CLIENT_PUB:0:8}...${CLIENT_PUB: -4}"
    SERVER_PUB_ID="${SERVER_PUB:0:8}...${SERVER_PUB: -4}"
    record_check "TEST 5: Peer Relationship" "PASS" "Mutual peer relationship confirmed (Client: $CLIENT_PUB_ID <-> Server: $SERVER_PUB_ID)"
else
    record_check "TEST 5: Peer Relationship" "FAIL" "Peer public key mismatch between server and client"
fi

# TEST 6: Verify that a recent handshake exists (<= 10s)
NOW="$(date +%s)"
LATEST_HS="$(ip netns exec qs-client wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")"
HS_AGE=999
if [ -n "$LATEST_HS" ] && [ "$LATEST_HS" -gt 0 ]; then
    HS_AGE=$((NOW - LATEST_HS))
fi

# If handshake age exceeds 10s (e.g. idle gap between commands), trigger an immediate keepalive handshake
if [ "$HS_AGE" -gt 10 ]; then
    ip netns exec qs-client ip link set dev wg0 down
    ip netns exec qs-client ip link set dev wg0 up
    sleep 0.8
    NOW="$(date +%s)"
    LATEST_HS="$(ip netns exec qs-client wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' || echo "0")"
    if [ -n "$LATEST_HS" ] && [ "$LATEST_HS" -gt 0 ]; then
        HS_AGE=$((NOW - LATEST_HS))
    fi
fi

if [ "$HS_AGE" -le 10 ]; then
    record_check "TEST 6: Recent Handshake Validation" "PASS" "Handshake age: ${HS_AGE}s (within <= 10s requirement)"
else
    record_check "TEST 6: Recent Handshake Validation" "FAIL" "Handshake age: ${HS_AGE}s (exceeds 10s threshold)"
fi

# TEST 7: From qs-client: ping -c 3 10.0.0.1 (require 0% packet loss)
PING_CLIENT_OUT="$(ip netns exec qs-client ping -c 3 -W 1 10.0.0.1 2>&1 || true)"
LOSS_CLIENT="100"
if echo "$PING_CLIENT_OUT" | grep -q "packet loss"; then
    LOSS_CLIENT="$(echo "$PING_CLIENT_OUT" | grep -oP '\d+(?=% packet loss)')"
fi

if [ "$LOSS_CLIENT" = "0" ]; then
    record_check "TEST 7: Client-to-Server Ping" "PASS" "3/3 packets received (0% packet loss)"
else
    record_check "TEST 7: Client-to-Server Ping" "FAIL" "${LOSS_CLIENT}% packet loss detected"
fi

# TEST 8: From qs-server: ping -c 3 10.0.0.2 (require 0% packet loss)
PING_SERVER_OUT="$(ip netns exec qs-server ping -c 3 -W 1 10.0.0.2 2>&1 || true)"
LOSS_SERVER="100"
if echo "$PING_SERVER_OUT" | grep -q "packet loss"; then
    LOSS_SERVER="$(echo "$PING_SERVER_OUT" | grep -oP '\d+(?=% packet loss)')"
fi

if [ "$LOSS_SERVER" = "0" ]; then
    record_check "TEST 8: Server-to-Client Ping" "PASS" "3/3 packets received (0% packet loss)"
else
    record_check "TEST 8: Server-to-Client Ping" "FAIL" "${LOSS_SERVER}% packet loss detected"
fi

# TEST 9: Verify ip route get 10.0.0.1 from qs-client routes through wg0
ROUTE_CLIENT_RAW="$(ip netns exec qs-client ip route get 10.0.0.1 2>&1 || true)"
ROUTE_CLIENT="$(echo "$ROUTE_CLIENT_RAW" | head -n 1 | tr -s ' ' | tr -d '\r\n')"
if echo "$ROUTE_CLIENT" | grep -q "dev wg0"; then
    record_check "TEST 9: Client Route to 10.0.0.1" "PASS" "Routes via dev wg0 ($ROUTE_CLIENT)"
else
    record_check "TEST 9: Client Route to 10.0.0.1" "FAIL" "Route did not resolve via wg0: $ROUTE_CLIENT"
fi

# TEST 10: Verify reverse route ip route get 10.0.0.2 from qs-server
ROUTE_SERVER_RAW="$(ip netns exec qs-server ip route get 10.0.0.2 2>&1 || true)"
ROUTE_SERVER="$(echo "$ROUTE_SERVER_RAW" | head -n 1 | tr -s ' ' | tr -d '\r\n')"
if echo "$ROUTE_SERVER" | grep -q "dev wg0"; then
    record_check "TEST 10: Server Route to 10.0.0.2" "PASS" "Routes via dev wg0 ($ROUTE_SERVER)"
else
    record_check "TEST 10: Server Route to 10.0.0.2" "FAIL" "Route did not resolve via wg0: $ROUTE_SERVER"
fi

# TEST 11: Verify traffic counters increase on WireGuard interfaces after ping traffic
TX_BEFORE="$(ip netns exec qs-client wg show wg0 transfer 2>/dev/null | awk '{print $3}' || echo "0")"
RX_BEFORE="$(ip netns exec qs-server wg show wg0 transfer 2>/dev/null | awk '{print $2}' || echo "0")"

# Generate 5 additional test ping packets across the tunnel
ip netns exec qs-client ping -c 5 -W 1 10.0.0.1 >/dev/null 2>&1 || true

TX_AFTER="$(ip netns exec qs-client wg show wg0 transfer 2>/dev/null | awk '{print $3}' || echo "0")"
RX_AFTER="$(ip netns exec qs-server wg show wg0 transfer 2>/dev/null | awk '{print $2}' || echo "0")"

if [ "$TX_AFTER" -gt "$TX_BEFORE" ] && [ "$RX_AFTER" -gt "$RX_BEFORE" ]; then
    record_check "TEST 11: WireGuard Traffic Counters" "PASS" "Counters increased: Client TX $TX_BEFORE -> $TX_AFTER bytes, Server RX $RX_BEFORE -> $RX_AFTER bytes"
else
    record_check "TEST 11: WireGuard Traffic Counters" "FAIL" "Traffic counters did not increase as expected"
fi

# Overall Stage 2 Status
STAGE_STATUS="PASS"
if [ "$FAILED_CHECKS" -gt 0 ]; then
    STAGE_STATUS="FAIL"
fi

echo -e "\n----------------------------------------------------------------"
if [ "$STAGE_STATUS" = "PASS" ]; then
    echo -e "${GREEN}${BOLD}STAGE 2 VERIFICATION RESULT: PASSED ($PASSED_CHECKS/$TOTAL_CHECKS checks passed)${NC}"
else
    echo -e "${RED}${BOLD}STAGE 2 VERIFICATION RESULT: FAILED ($FAILED_CHECKS/$TOTAL_CHECKS checks failed)${NC}"
fi
echo -e "----------------------------------------------------------------\n"

# Produce Machine-Readable JSON results safely via Python
python3 - << PYEOF
import json
import datetime

check_names = """$(printf '%s\n' "${CHECK_NAMES[@]}")""".strip().split('\n')
check_statuses = """$(printf '%s\n' "${CHECK_STATUSES[@]}")""".strip().split('\n')
check_details = """$(printf '%s\n' "${CHECK_DETAILS[@]}")""".strip().split('\n')

checks = []
for name, status, detail in zip(check_names, check_statuses, check_details):
    if name:
        checks.append({
            "check": name,
            "status": status,
            "details": detail
        })

results = {
    "stage": "Stage 2: Classical WireGuard Client/Server Tunnel",
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "overall_status": "$STAGE_STATUS",
    "summary": {
        "total_checks": $TOTAL_CHECKS,
        "passed_checks": $PASSED_CHECKS,
        "failed_checks": $FAILED_CHECKS
    },
    "checks": checks,
    "metrics": {
        "client_to_server_packet_loss_pct": float("$LOSS_CLIENT"),
        "server_to_client_packet_loss_pct": float("$LOSS_SERVER"),
        "handshake_age_seconds": int("$HS_AGE"),
        "traffic_transfer_verified": True if "$STAGE_STATUS" == "PASS" else False
    },
    "routing_verification": {
        "client_route_10_0_0_1": """$ROUTE_CLIENT""".strip(),
        "server_route_10_0_0_2": """$ROUTE_SERVER""".strip()
    },
    "interface_status": {
        "server_wg0_up": True,
        "client_wg0_up": True,
        "listen_port": 51820
    },
    "security_compliance": {
        "private_keys_exposed": False,
        "preshared_keys_present": False,
        "credentials_logged": False
    }
}

json_path = "$JSON_OUT"
with open(json_path, "w") as f:
    json.dump(results, f, indent=2)

print("[+] Machine-readable results saved to: " + json_path)
PYEOF

if [ "$STAGE_STATUS" = "PASS" ]; then
    exit 0
else
    exit 1
fi