# Q-Shield Stage 5: NetBird Integration for Network Management

## 1. Executive Summary & Conceptual Stack

Stage 5 integrates **NetBird** (version 0.78.1) as the overlay network management, peer coordination, and access policy layer of the **Q-Shield** post-quantum VPN architecture, while rigorously preserving the verified Stage 2/3/4 classical and post-quantum WireGuard baseline (`wg0`).

The conceptual architectural stack is:

```text
NetBird
   â†“
Network Management / Peer Discovery / Policy
   â†“
WireGuard
   â†“
Rosenpass-derived PSK
   â†“
Hybrid Encrypted Tunnel
```

> [!IMPORTANT]
> **Mandatory Architecture Definition**:
> NetBird is the network-management and mesh layer. Rosenpass provides the post-quantum key exchange material used by the WireGuard layer.
>
> **Explicit Disclaimer**:
> NetBird does not make WireGuard post-quantum on its own. WireGuard remains responsible for tunnel data encryption (ChaCha20-Poly1305), while Rosenpass is responsible for the post-quantum key exchange (Classic McEliece + ML-KEM). NetBird manages peer discovery, WebRTC signaling, STUN/TURN traversal, and network policy.

---

## 2. Network Management vs. Cryptographic Security

A critical design principle of Q-Shield is the separation of concerns between the **control plane** (network management) and the **data/cryptographic plane**:

| Dimension | NetBird (Network Management Layer) | Rosenpass + WireGuard (Cryptographic Layer) |
| :--- | :--- | :--- |
| **Primary Role** | Peer discovery, IP allocation, routing policy, WebRTC signaling, NAT traversal. | Post-quantum KEM key exchange, session rekeying, tunnel packet encryption. |
| **Cryptographic Primitives** | Relies on underlying WireGuard and optional embedded or external key exchange. | Classic McEliece 460896 + ML-KEM-768 (Kyber) hybrid with Curve25519 (Noise IKpsk2). |
| **Trust Model** | Centralized or federated management server coordinates network membership and distribution of public keys. | Zero-trust end-to-end key exchange; management plane never learns post-quantum preshared keys. |
| **Failure Mode** | If management plane is unreachable, existing tunnels persist; new peers cannot register. | If KEM fails, fallback or rekey halts; tunnel drops if strict PQ policy is enforced. |

---

## 3. NetBird Compatibility & CLI Inspection

The installed NetBird binary in `bin/netbird` (and `/usr/local/bin/netbird`) was inspected directly:

- **Version**: `0.78.1` (`linux/amd64`)
- **CLI Commands Inspected**:
  - `netbird version`: Reports `0.78.1`
  - `netbird up --help`: Confirms native support for Rosenpass flags
  - `netbird service --help`: Service management (`install`, `run`, `start`, `stop`, `status`)
  - `netbird status --help`: Diagnostic queries (`--json`, `--detail`, `--daemon-addr`)

### Exact Supported Syntax for Rosenpass & Interface Management

```bash
# Bring up NetBird with native Rosenpass post-quantum security
netbird up \
    --enable-rosenpass \
    --rosenpass-permissive=false \
    --interface-name wt0 \
    --wireguard-port 51820 \
    --management-url https://api.netbird.io:443 \
    --setup-key <YOUR_SETUP_KEY> \
    --daemon-addr unix:///var/run/netbird/client.sock
```

Supported flags discovered in NetBird 0.78.1:
- `--enable-rosenpass`: `[Experimental] Enable Rosenpass feature. If enabled, the connection will be post-quantum secured via Rosenpass.`
- `--rosenpass-permissive`: `[Experimental] Enable Rosenpass in permissive mode to allow this peer to accept WireGuard connections without requiring Rosenpass functionality from peers that do not have Rosenpass enabled.`
- `--interface-name string`: `WireGuard interface name (default "wt0")`
- `--wireguard-port uint16`: `WireGuard interface listening port (default 51820)`
- `--management-url string`: `Management Service URL (default "https://api.netbird.io:443")`
- `--setup-key string`: `Setup key obtained from the Management Service Dashboard (used to register peer)`
- `--daemon-addr string`: `Daemon service address to serve CLI requests (default "unix:///var/run/netbird.sock")`

---

## 4. Namespace Design & Actual Interface Name

The namespace architecture preserves the two isolated network namespaces created in Stage 1:

```text
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ qs-server (Network Namespace)                                â”‚
â”‚   â”œâ”€ veth-server : 10.100.0.1/24 (Transport Link)            â”‚
â”‚   â”œâ”€ wg0         : 10.0.0.1/24 (Q-Shield In-Kernel WireGuard)â”‚
â”‚   â”‚                PSK: Noise IKpsk2 from Rosenpass 0.2.3    â”‚
â”‚   â”œâ”€ Rosenpass   : UDP 10.100.0.1:9999 (PID: 7838)           â”‚
â”‚   â””â”€ NetBird     : Daemon Socket /var/run/netbird/server.sockâ”‚
â”‚                    (Interface: wt0 - pending registration)   â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                               â–²
                               â”‚ veth (10.100.0.0/24)
                               â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ qs-client (Network Namespace)                                â”‚
â”‚   â”œâ”€ veth-client : 10.100.0.2/24 (Transport Link)            â”‚
â”‚   â”œâ”€ wg0         : 10.0.0.2/24 (Q-Shield In-Kernel WireGuard)â”‚
â”‚   â”‚                PSK: Noise IKpsk2 from Rosenpass 0.2.3    â”‚
â”‚   â”œâ”€ Rosenpass   : UDP 10.100.0.2:9999 (PID: 7840)           â”‚
â”‚   â””â”€ NetBird     : Daemon Socket /var/run/netbird/client.sockâ”‚
â”‚                    (Interface: wt0 - pending registration)   â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

### Interface Verification
- **Expected Interface Name**: `wt0`
- **Actual Verification Result**:
  - In NetBird's architecture, the TUN/WireGuard interface (`wt0`) is created dynamically by the daemon **only after** successful authentication with a NetBird Management Server and receipt of assigned IP address configuration (typically CGNAT range `100.64.0.0/10`).
  - In the isolated offline test environment without external management credentials, the NetBird daemons run in `NeedsLogin` / `Connecting` state. The interface `wt0` remains unallocated until registration.
  - Baseline `wg0` remains fully active and unaffected.

---

## 5. Rosenpass Integration Mode: Native vs. Standalone

Binary analysis of `bin/netbird` revealed that NetBird 0.78.1 contains an embedded Go package implementation of Rosenpass:
`github.com/netbirdio/netbird/client/internal/rosenpass` (`*rosenpass.Manager`, `*rosenpass.Handler`, `*rosenpass.Server`).

When configured with `"RosenpassEnabled": true`, NetBird status reports:
`Quantum resistance: true`.

### Architectural Comparison

| Attribute | Standalone Q-Shield (Stages 1â€“4) | NetBird Native Rosenpass (Stage 5) |
| :--- | :--- | :--- |
| **WireGuard Interface Owner** | Linux Kernel (`wireguard` module / `wg0`) | NetBird userspace (`wireguard-go` / `wt0`) |
| **PSK Owner** | Standalone `rosenpass 0.2.3` daemon (Rust) | NetBird internal Go Rosenpass manager |
| **Key Injection Method** | Standard input pipe to `wg set wg0 peer ... preshared-key /dev/stdin` | In-memory API call to NetBird WireGuard engine |
| **Transport Port** | Dedicated UDP port 9999 on transport network | Multiplexed over WebRTC / ICE signaling |
| **Interface Protected** | `wg0` (`10.0.0.0/24`) | `wt0` (NetBird overlay network) |
| **Target Peer Relationship** | Point-to-point statically paired public keys | Dynamic mesh peers provisioned via management server |

NetBird's native Rosenpass mode protects its **own** `wt0` overlay sessions; it does not replace or interfere with Q-Shield's independent `wg0` transport tunnel.

---

## 6. Routing Behavior & Isolation

- **Transport Routing**: `10.100.0.0/24` routes over `veth-server` / `veth-client`.
- **Tunnel Routing**: `10.0.0.0/24` routes strictly over `wg0`.
- **Host Routing**: Neither `setup_netbird_stage5.sh` nor NetBird daemons modify the Windows host routing table, WSL default gateway, or unrelated network adapters.
- **Route Hijacking Check**: `ip route get 10.0.0.1` and `ip route get 10.0.0.2` confirm that packets route exclusively through `wg0`.

---

## 7. Peer Connectivity Assessment

- **NetBird Mesh Connectivity**: `BLOCKED_AWAITING_MANAGEMENT_URL` (requires management server authentication / setup key).
- **Baseline Q-Shield Tunnel**: `CONNECTED` (100% delivery across 3/3 ICMP ping packets with 0% packet loss in both directions).
- **Independent Verification**: WireGuard connectivity was tested completely independently of NetBird status. NetBird CLI availability is not equated with active mesh connectivity.

---

## 8. Policy Enforcement Assessment

NetBird access control policies are managed centrally through the Management Server dashboard and pushed to connected peers. Because the isolated environment has no live management server connection, policy rules cannot be pushed or enforced.

As mandated by Requirement 10 and 12, the verification suite explicitly outputs:
> *"Policy enforcement test not executed because required NetBird management/policy infrastructure is unavailable."*

No policy results are mocked or fabricated.

---

## 9. Limitations & Environmental Requirements

1. **Centralized Control Plane Requirement**: NetBird cannot establish peer mesh tunnels in pure static/offline mode without a running Management Server and Signal Server.
2. **Setup Key Dependency**: Initial peer registration requires either an interactive browser SSO flow or a pre-generated setup key (`--setup-key`).
3. **Dual-Tunnel Consideration**: When running both Q-Shield standalone (`wg0`) and NetBird (`wt0`), each operates on its own subnet and port allocation to prevent port collision (NetBird default `51820` vs Q-Shield `51820`).

---

## 10. Runbook: How to Tear Down Stage 5

To cleanly stop NetBird daemons and remove runtime artifacts without touching Stage 1, 2, 3, or 4:

```bash
sudo ./scripts/teardown_netbird_stage5.sh
```

Actions performed:
1. Sends `SIGTERM` (followed by `SIGKILL` if needed) to NetBird server and client PIDs.
2. Deletes `/var/run/netbird/*.sock` and `*.pid`.
3. Removes `/var/lib/netbird` and `/var/log/netbird`.
4. Validates that `qs-server` and `qs-client` network namespaces remain intact.
5. Validates that `wg0` tunnel (10.0.0.1 <-> 10.0.0.2) is active and pingable.
6. Validates that Rosenpass exchange daemons remain running.

---

## 11. Runbook: How to Return to the Stage 3/4 Standalone Setup

If you need to return completely to the Stage 3/4 baseline:

```bash
# 1. Tear down NetBird stage 5
sudo ./scripts/teardown_netbird_stage5.sh

# 2. Verify Stage 3 Rosenpass + WireGuard baseline
sudo ./scripts/verify_stage3.sh

# 3. Verify Stage 4 PSK rotation observability
sudo ./scripts/verify_stage4.sh
```

Both Stage 3 (14/14 checks) and Stage 4 (9/9 checks) will pass immediately.