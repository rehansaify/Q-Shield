# Q-Shield: Diagnostic & Troubleshooting Runbook

This guide provides practical triage procedures for diagnosing and resolving common operational issues across the Q-Shield stack.

---

## 1. WSL2 Network Namespace Persistence & `/run/netns`

### Symptom: `Cannot open network namespace "qs-server": No such file or directory`
- **Root Cause**: In Windows WSL2, when all active terminal shells exit, the WSL2 background VM enters a sleep state after ~15 seconds of inactivity. This unmounts transient in-memory mounts like `/run` and `/run/netns`, destroying active network namespaces.
- **Diagnosis**:
  ```bash
  # Check if namespaces currently exist
  ip netns list
  ```
- **Remediation**:
  1. Re-create the namespaces and re-run the stage setup scripts:
     ```bash
     sudo ./scripts/setup_namespaces.sh
     sudo ./scripts/setup_wireguard_stage2.sh
     sudo ./scripts/setup_rosenpass_stage3.sh
     ```
  2. To prevent WSL2 from entering sleep during development, run a lightweight keepalive process in a background shell:
     ```bash
     nohup bash -c "while true; do sleep 3600; done" </dev/null >/dev/null 2>&1 &
     ```

---

## 2. WireGuard Handshake & Interface Failures

### Symptom: WireGuard tunnel fails to pass traffic (`10.0.0.1` unreachable via ping)
- **Diagnosis**:
  ```bash
  # Check interface status inside namespaces
  sudo ip -n qs-server link show wg0
  sudo ip -n qs-client link show wg0

  # Check WireGuard handshake age and endpoint reachability
  sudo ip netns exec qs-client wg show wg0
  ```
- **Triage Checklist**:
  1. **Handshake Timestamp**: If `latest handshake` is missing or older than 180 seconds, the handshake has not completed.
  2. **Underlay Connectivity**: Verify that the transport link between namespaces is functional:
     ```bash
     sudo ip netns exec qs-client ping -c 2 10.100.0.1
     ```
  3. **Port Binding**: Ensure WireGuard UDP port 51820 is bound:
     ```bash
     sudo ip netns exec qs-server ss -u -l -n -p | grep 51820
     ```
  4. **AllowedIPs Configuration**: Confirm that `AllowedIPs` on `qs-client` includes `10.0.0.0/24` or `10.0.0.1/32`.
- **Remediation**:
  Re-initialize the WireGuard stage:
  ```bash
  sudo ./scripts/teardown_wireguard_stage2.sh
  sudo ./scripts/setup_wireguard_stage2.sh
  ```

---

## 3. Rosenpass UDP 9999 & Key Exchange Issues

### Symptom: Rosenpass daemons active, but WireGuard shows no Pre-Shared Key
- **Diagnosis**:
  ```bash
  # Check if Rosenpass processes are running
  ps aux | grep rosenpass

  # Inspect Rosenpass daemon logs
  cat /var/log/qshield/rosenpass-server.log
  cat /var/log/qshield/rosenpass-client.log

  # Check WireGuard PSK presence
  sudo ip netns exec qs-client wg show wg0 preshared-key
  ```
- **Common Root Causes**:
  1. **Keyfile Permissions**: Rosenpass refuses to start if secret key files have permissions more permissive than `0600`.
     ```bash
     sudo chmod 0600 /etc/wireguard/qshield/rosenpass/*.pqsk
     ```
  2. **Port 9999 Collision**: Another process is holding UDP port 9999.
     ```bash
     sudo ip netns exec qs-server ss -u -l -n -p | grep 9999
     ```
  3. **Key Mismatch**: The public key configured in the peer block does not match the actual public key of the remote peer.
- **Remediation**:
  Restart the Rosenpass stage:
  ```bash
  sudo ./scripts/teardown_rosenpass_stage3.sh
  sudo ./scripts/setup_rosenpass_stage3.sh
  sudo ./scripts/verify_stage3.sh
  ```

---

## 4. PSK Synchronization & Rotation Continuity

### Symptom: Packets drop during key rotation
- **Diagnosis**:
  ```bash
  # Run the live rotation monitor
  sudo ./scripts/monitor_psk_rotation.sh 180
  ```
- **Analysis**:
  - WireGuard supports hitless PSK updates. When Rosenpass supplies a new PSK via `/dev/stdin`, WireGuard updates its internal peer table and incorporates the new PSK on the next handshake.
  - If packets are dropped, verify whether the system CPU is constrained during the Classic McEliece encapsulation/decapsulation calculations.
  - In our validated tests, 1,520 packets at 100ms intervals achieved **0.0% packet loss**.

---

## 5. NetBird Integration Diagnosis (Stage 5)

### Understanding Validated Local Behavior vs. Unvalidated Cloud Features
In Stage 5, NetBird was evaluated as an overlay network manager:
- **Validated**:
  - NetBird binary v0.78.1 is functional and executable.
  - NetBird client daemons start cleanly inside `qs-server` and `qs-client` via isolated unix sockets (`/var/run/netbird/server.sock`, `client.sock`).
  - Embedded Go Rosenpass package is recognized (`Quantum resistance: true`).
- **Unvalidated / Blocked**:
  - TUN interface `wt0` creation.
  - Dynamic mesh peer establishment.
  - Access control policy enforcement.

### Symptom: `Daemon status: NeedsLogin` or `Management: Disconnected`
- **Explanation**:
  NetBird requires authentication with a NetBird Management Server (cloud `https://api.netbird.io:443` or self-hosted endpoint) before it will create the `wt0` interface or assign an IP. In the isolated offline test environment, no setup key was provided.
- **Status in Verification Suite**:
  This is the intended behavior in an offline environment. `scripts/verify_stage5.sh` correctly reports `BLOCKED` rather than failing, because external credentials are intentionally not fabricated.
- **How to Unblock in a Production/Live Setup**:
  If you have a live NetBird account or self-hosted management instance:
  ```bash
  # Export your management credentials
  export NETBIRD_MANAGEMENT_URL="https://api.netbird.io:443"
  export NETBIRD_SETUP_KEY="<YOUR_SETUP_KEY_FROM_DASHBOARD>"

  # Re-run Stage 5 setup with credentials
  sudo -E ./scripts/setup_netbird_stage5.sh
  ```

---

## 6. Diagnostic Command Cheat Sheet

```bash
# 1. Quick sanity check of all stages
sudo ip netns list
sudo ip -n qs-server addr show
sudo ip -n qs-client addr show

# 2. WireGuard handshake and key status
sudo ip netns exec qs-client wg show wg0

# 3. Test ping across hybrid post-quantum tunnel
sudo ip netns exec qs-client ping -c 3 10.0.0.1
sudo ip netns exec qs-server ping -c 3 10.0.0.2

# 4. Check Rosenpass daemon logs
tail -n 20 /var/log/qshield/rosenpass-server.log
tail -n 20 /var/log/qshield/rosenpass-client.log

# 5. Check NetBird daemon status (if Stage 5 setup was run)
sudo ./bin/netbird status --daemon-addr unix:///var/run/netbird/server.sock
sudo ./bin/netbird status --daemon-addr unix:///var/run/netbird/client.sock
```