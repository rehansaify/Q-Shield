# Stage 4: Configurable Periodic PSK Rotation & Tunnel Continuity

## 1. Overview

Stage 4 validates the continuous cryptographic and operational reliability of Q-Shield under dynamic post-quantum key updates. 

Rather than creating an artificial or redundant key-rotation daemon, Stage 4 acts as a non-invasive **observability and verification layer** around Rosenpass's native protocol rotation. The test measures how WireGuard's active sessions handle continuous post-quantum pre-shared key (PSK) updates while high-frequency data traffic is actively traversing the tunnel.

---

## 2. Distinction: Expected vs. Measured Behavior

| Attribute | Expected Behavior (Protocol Spec) | Measured Behavior (Empirical Test) |
| :--- | :--- | :--- |
| **Rotation Mechanism** | Periodic out-of-band re-keying via Rosenpass daemon over UDP 9999 | Out-of-band daemon updating WireGuard via `/dev/stdin` confirmed |
| **Rotation Interval** | Approximately every 120 seconds | Observed intervals: **27 seconds** (initial cycle) and **131 seconds** (subsequent cycle). Average: **79.0 seconds** |
| **Peer Convergence** | Server and client converge on the identical 256-bit PSK | **100% convergence**: Matching SHA-256 fingerprints across all epochs |
| **Cryptographic Forward Secrecy**| Successive keys must be distinct ($A \neq B \neq C$) | **Confirmed**: Distinct fingerprints across all 3 epochs |
| **Tunnel Impact** | Zero downtime; packets in flight decrypt with existing session | **0.0% packet loss**: Exactly 1,520/1,520 packets received |
| **Latency / Jitter** | Sub-millisecond round-trip time with negligible rotation penalty | **Min RTT: 0.188 ms**, **Avg RTT: 0.536 ms**, **Max RTT: 1.78 ms** |
| **Secret Material Security** | PSKs must never appear in logs or process arguments | **Zero leakage**: Only non-secret SHA-256 fingerprints recorded |

---

## 3. How PSK Epochs and Fingerprints Are Handled

### Epoch Progression
An "epoch" represents a distinct cryptographic generation of the WireGuard PSK. The test observed three distinct epochs ($A \to B \to C$):

```
+------------------+         +------------------+         +------------------+
|     Epoch 1      |  (27s)  |     Epoch 2      |  (131s) |     Epoch 3      |
| aee6c3a8...0d17  | ======> | 39cdb970...9a68  | ======> | 77b32997...3a10  |
| Server == Client |         | Server == Client |         | Server == Client |
+------------------+         +------------------+         +------------------+
```

### Non-Secret Verification Fingerprint
To verify that both peers converge on the exact same secret without exposing or logging raw 256-bit symmetric keys, the monitoring harness computes:
$$\text{Fingerprint} = \text{SHA-256}(\text{Raw PSK})$$

- **Non-Reversible**: SHA-256 is a one-way collision-resistant hash function. An adversary observing the fingerprint cannot compute or derive the underlying PSK.
- **In-Memory Pipe**: The raw PSK is piped directly from kernel netlink into `sha256sum` in memory without ever being assigned to persistent environment variables, command arguments, or disk files.
- **Kernel Masking**: WireGuard masks the active key in `wg show` as `(hidden)`.

---

## 4. Continuity & Handshake Dynamics

### Tunnel Continuity Measurement
A continuous stream of ICMP echo requests was generated from `qs-client` (10.0.0.2) to `qs-server` (10.0.0.1) at **100 ms intervals (10 packets/second)** throughout the test duration of 158 seconds.

- **Total Packets Transmitted**: 1,520
- **Total Packets Received**: 1,520
- **Packet Loss**: **0.0%**
- **RTT Statistics**:
  - Minimum: 0.188 ms
  - Average: 0.536 ms
  - Maximum: 1.780 ms
  - Mean Deviation (mdev): 0.192 ms

### Handshake Transition Mechanics
WireGuard decouples transport encryption from key exchange:
1. When Rosenpass installs a new PSK via `wg set wg0 peer <ID> preshared-key /dev/stdin`, the kernel WireGuard peer table updates immediately.
2. The active data transport session continues using the current symmetric session keys.
3. On the next handshake initiation (triggered by the periodic timer or keepalive), WireGuard executes the Noise IKpsk2 handshake with the new post-quantum PSK mixed into the handshake state ($\text{MixKeyAndHash}$).
4. Once the handshake completes, the session keys ratchet forward seamlessly without resetting TCP connections or dropping in-flight UDP packets.

---

## 5. Execution Guide

All commands must be executed as root (`sudo` or `wsl -u root -d Ubuntu`).

### A. Run PSK Rotation Monitor
```bash
sudo bash scripts/monitor_psk_rotation.sh --epochs 3
```
*Action*: Monitors both namespaces, displays live epoch transitions in a table, and calculates rotation intervals.

### B. Run Rotation Cryptographic Test
```bash
sudo bash scripts/test_psk_rotation.sh
```
*Action*: Asserts that $A \neq B \neq C$ and that server/client fingerprints converge across all transitions.

### C. Run Tunnel Continuity Test
```bash
sudo bash scripts/test_rotation_continuity.sh
```
*Action*: Transmits 100ms ping traffic across 3 epochs, verifies 0% packet loss, and outputs packet/RTT metrics.

### D. Run Complete Stage 4 Verification
```bash
sudo bash scripts/verify_stage4.sh
```
*Action*: Orchestrates the complete suite, validates all 9 verification checks, and generates `results/stage4_results.json`.

---

## 6. Limitations of the Test

1. **Virtual Link Environment**: The test was conducted over virtual ethernet (`veth`) interfaces inside Linux network namespaces. Under physical networks with real-world jitter or packet reordering, transient packet loss could occur if network packets are dropped by underlying routers.
2. **Native Re-Key Schedule**: Rosenpass 0.2.3 enforces internal timing heuristics (~120s between exchanges with small initial variance). The verification harness observes these intervals rather than overriding internal state.