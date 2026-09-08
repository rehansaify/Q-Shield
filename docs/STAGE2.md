# Stage 2: Classical WireGuard Client/Server Tunnel

> [!WARNING]
> **Cryptographic Scope and Security Warning**:
> **This is the classical WireGuard baseline. It is NOT post-quantum secure by itself.**
> Stage 2 provides classical symmetric encryption (ChaCha20-Poly1305) and key exchange (Curve25519) within the Noise IKpsk2 framework, but does not yet incorporate post-quantum pre-shared keys. It is vulnerable to future Cryptanalytically Relevant Quantum Computers (CRQCs) via Shor's algorithm (Harvest Now, Decrypt Later). Quantum resistance will be layered in Stage 3 using Rosenpass.

---

## 1. Architecture Overview

Stage 2 establishes a functioning, point-to-point classical WireGuard tunnel between two isolated Linux network namespaces (`qs-server` and `qs-client`). This establishes the underlying high-performance data transport plane before post-quantum key establishment is introduced.

```
+------------------------------------+                         +------------------------------------+
|        Namespace: qs-server        |                         |        Namespace: qs-client        |
|                                    |                         |                                    |
|  Interface: veth-server            |                         |  Interface: veth-client            |
|  IPv4:      10.100.0.1/24          | <=====================> |  IPv4:      10.100.0.2/24          |
|  Listen:    UDP 51820              |   veth transport link   |  Endpoint:  10.100.0.1:51820       |
|                                    |                         |                                    |
|  Interface: wg0 (WireGuard)        |                         |  Interface: wg0 (WireGuard)        |
|  IPv4:      10.0.0.1/24            | < - - - - - - - - - - > |  IPv4:      10.0.0.2/24            |
|  Peer:      Client Public Key      |   WireGuard Encrypted   |  Peer:      Server Public Key      |
|  AllowedIP: 10.0.0.2/32            |         Tunnel          |  AllowedIP: 10.0.0.0/24            |
|  Routes:    10.0.0.0/24 dev wg0    |                         |  Routes:    10.0.0.0/24 dev wg0    |
+------------------------------------+                         +------------------------------------+
```

---

## 2. Network Topology & Addressing

| Parameter | Server (`qs-server`) | Client (`qs-client`) |
| :--- | :--- | :--- |
| **Namespace** | `qs-server` | `qs-client` |
| **Physical/Veth Link** | `veth-server` (`10.100.0.1/24`) | `veth-client` (`10.100.0.2/24`) |
| **WireGuard Interface** | `wg0` | `wg0` |
| **Tunnel IPv4** | `10.0.0.1/24` | `10.0.0.2/24` |
| **Listen Port** | `UDP 51820` | Dynamic ephemeral UDP |
| **Remote Endpoint** | None (acts as receiver) | `10.100.0.1:51820` |
| **AllowedIPs** | `10.0.0.2/32` | `10.0.0.0/24` |
| **PersistentKeepalive** | N/A | `5` seconds |

All WireGuard interfaces exist strictly within their respective network namespaces. Port 51820 is bound inside `qs-server` and is not exposed on the host.

---

## 3. Key Management & Zero-Leakage Policy

- **Storage Location**: `/etc/wireguard/qshield/keys/` with directory permission `0700`.
- **Private Keys**:
  - Generated using `wg genkey` with `umask 077` and file mode `0600`.
  - Owned by `root:root`.
  - Stored outside tracked Git directories.
  - Never displayed in terminal stdout, verification scripts, or JSON results.
- **Public Keys**:
  - Derived via `wg pubkey` with file mode `0644`.
  - Shared mutually between client and server configuration blocks.

---

## 4. Execution & Lifecycle Commands

All commands require root privileges (`wsl -u root -d Ubuntu` or `sudo`).

### A. Deploy Stage 2 Tunnel
```bash
sudo bash scripts/setup_wireguard_stage2.sh
```
*Action*: Verifies Stage 1 namespaces, creates server/client keypairs (if not already existing), configures `wg0` interfaces, sets routes, and waits for a confirmed handshake.

### B. Verify Stage 2 (11 Automated Tests)
```bash
sudo bash scripts/verify_stage2.sh
```
*Action*: Runs all 11 automated checks, asserts 0% packet loss, verifies routing and handshake age (<= 10s), and writes results to `results/stage2_results.json`.

### C. Teardown Stage 2 Only
```bash
sudo bash scripts/teardown_wireguard_stage2.sh
```
*Action*: Safely deletes `wg0` from both `qs-server` and `qs-client` while leaving the Stage 1 namespaces and virtual link completely intact.

---

## 5. Verification Results Summary

The 11 automated verification tests in `scripts/verify_stage2.sh` validate:

1. **Server Interface**: `wg0` present in `qs-server`.
2. **Client Interface**: `wg0` present in `qs-client`.
3. **Listen Port**: Server actively listening on `UDP 51820`.
4. **Zero Key Exposure**: `wg show` executes cleanly without exposing private keys (displayed as `(hidden)`).
5. **Peer Relationship**: Server and client correctly identify each other by their respective public keys.
6. **Recent Handshake**: Initial Noise handshake established within <= 10 seconds of query.
7. **Client-to-Server ICMP Ping**: `ping -c 3 10.0.0.1` achieves 0% packet loss across tunnel.
8. **Server-to-Client ICMP Ping**: `ping -c 3 10.0.0.2` achieves 0% packet loss across tunnel.
9. **Client Routing**: `ip route get 10.0.0.1` explicitly routes through `dev wg0`.
10. **Server Routing**: `ip route get 10.0.0.2` explicitly routes through `dev wg0`.
11. **Traffic Counters**: Transferred bytes (`transfer`) monotonically increase on both endpoints following ping traffic.

---

## 6. Troubleshooting

### Issue: "Stage 1 namespaces are missing"
- **Cause**: Namespaces were not set up or were cleared.
- **Resolution**: Run `sudo bash scripts/setup_namespaces.sh` and re-run `setup_wireguard_stage2.sh`.

### Issue: "Handshake age exceeds 10s"
- **Cause**: Tunnel has been completely idle without traffic.
- **Resolution**: Client `persistent-keepalive 5` will refresh the session, or trigger traffic with `sudo ip netns exec qs-client ping -c 1 10.0.0.1`.

### Issue: "Peer public key mismatch"
- **Cause**: Out-of-sync key files in `/etc/wireguard/qshield/keys/`.
- **Resolution**: Remove existing keys (`sudo rm -rf /etc/wireguard/qshield/keys`) and re-run `setup_wireguard_stage2.sh` to generate a fresh synchronized pair.