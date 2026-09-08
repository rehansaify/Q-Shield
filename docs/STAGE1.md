# Stage 1: Environment & Tooling Preparation

## 1. Overview

Stage 1 establishes the foundational Linux runtime environment, system utilities, post-quantum cryptographic binaries, and isolated network namespace topology required for the Q-Shield post-quantum remote-access VPN project.

No cryptographic keys, WireGuard interfaces, or Rosenpass sessions were configured in this stage, strictly fulfilling the stage-gate isolation requirements.

---

## 2. Directory Structure

The project has been organized according to the required specification:

```
Q-Shield/
├── bin/                        # Verified standalone executables
│   ├── netbird                 # NetBird v0.78.1 (x86_64-linux)
│   ├── rosenpass               # Rosenpass v0.2.3 (x86_64-linux)
│   └── rp                      # Rosenpass helper tool
├── config/                     # Configuration directory (staged for later phases)
├── scripts/                    # Lifecycle and verification automation
│   ├── setup_namespaces.sh     # Idempotent namespace and veth link provisioner
│   ├── teardown_namespaces.sh  # Safe teardown of namespaces and virtual links
│   └── verify_stage1.sh        # Stage 1 automated verification test runner
├── tests/                      # Test suite directory
├── benchmarks/                 # Performance benchmarking scripts directory
├── results/                    # Machine-readable test and benchmark artifacts
│   └── stage1_results.json     # Machine-readable JSON output of Stage 1 checks
├── docs/                       # Architectural and operational documentation
│   └── STAGE1.md               # Stage 1 documentation and execution runbook
└── .gitignore                  # Strict exclusion rules for keys, PSKs, logs, and tokens
```

---

## 3. Network Topology

An isolated virtual network environment was implemented using Linux network namespaces (`ip netns`) and virtual ethernet (`veth`) pairs:

```
+------------------------------------+        +------------------------------------+
|        Namespace: qs-server        |        |        Namespace: qs-client        |
|                                    |        |                                    |
|  Interface: veth-server            |        |  Interface: veth-client            |
|  IPv4:      10.100.0.1/24          | <====> |  IPv4:      10.100.0.2/24          |
|  Loopback:  lo (UP)                |  veth  |  Loopback:  lo (UP)                |
|  Forwarding: net.ipv4.ip_forward=1 |  pair  |  Forwarding: net.ipv4.ip_forward=1 |
+------------------------------------+        +------------------------------------+
```

### Key Network Properties
- **Isolation**: Both client and server network stacks run in complete isolation from the host and from each other, communicating solely across the virtual link.
- **Deterministic Latency**: Baseline link latency between namespaces is measured at sub-millisecond speeds (avg ~0.04 ms, 0% packet loss).
- **Idempotency**: Running `setup_namespaces.sh` multiple times safely resets existing virtual links and namespaces without corrupting host state.

---

## 4. Execution Guide

All operations must be run with root privileges inside the Linux environment.

### A. Set Up Isolated Namespaces
```bash
sudo bash scripts/setup_namespaces.sh
```
*Expected output*: Network namespaces `qs-server` and `qs-client` created, veth pair created, IPs `10.100.0.1/24` and `10.100.0.2/24` assigned and brought UP.

### B. Run Stage 1 Verification
```bash
sudo bash scripts/verify_stage1.sh
```
*Expected output*: 8 checks run, all return `[ PASS ]`, results written to `results/stage1_results.json`.

### C. Teardown Namespaces
```bash
sudo bash scripts/teardown_namespaces.sh
```
*Expected output*: Removes `qs-server`, `qs-client`, and any dangling veth links.

---

## 5. Stage 1 Verification Results

The automated verification script (`scripts/verify_stage1.sh`) verified:

| Check Item | Requirement | Status | Evidence |
| :--- | :--- | :---: | :--- |
| **System Utilities** | `ip`, `iptables`, `nft`, `iperf3`, `tcpdump`, `jq`, `wg`, `wg-quick` | **PASS** | All 8 utilities present in PATH |
| **WireGuard Kernel Module** | Module loaded & supported in kernel | **PASS** | `/sys/module/wireguard` operational |
| **Rosenpass Binary** | Executable returns valid version | **PASS** | `rosenpass 0.2.3` |
| **NetBird Binary** | Executable returns valid version | **PASS** | `NetBird v0.78.1` |
| **Network Namespaces** | `qs-server` & `qs-client` exist | **PASS** | Active in `ip netns list` |
| **Virtual Ethernet Link** | `veth-server` <-> `veth-client` IP assignment | **PASS** | `10.100.0.1/24` and `10.100.0.2/24` UP |
| **Peer Reachability** | 5 ICMP echo requests | **PASS** | 5/5 packets received (0% packet loss) |
| **Link Latency** | Baseline RTT statistics | **PASS** | min/avg/max = 0.033/0.044/0.060 ms (mdev: 0.009 ms) |

---

## 6. Security & Key Non-Exposure Assurance

In accordance with strict security requirements:
- No cryptographic keypairs were generated.
- No WireGuard tunnels were provisioned.
- No Rosenpass exchanges were initiated.
- `.gitignore` was configured to unconditionally block private keys (`*.key`, `*.priv`, `*.secret`, `*.pqsk`), WireGuard PSKs (`*.psk`), tokens, and logs.