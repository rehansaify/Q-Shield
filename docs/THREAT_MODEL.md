# Q-Shield: Threat Model & Security Analysis

## 1. Introduction & Methodology

This document defines the formal threat model for **Q-Shield**, adhering to **RFC 3552** (*Writing RFCs That Address Security Considerations*) and the **STRIDE** methodology (*Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege*).

Q-Shield is a hybrid post-quantum secure remote-access VPN combining **in-kernel WireGuard** with **Rosenpass-derived post-quantum pre-shared keys**, evaluated alongside **NetBird** for overlay network management.

---

## 2. Asset Identification

The primary assets protected by Q-Shield include:

| Asset | Description | Sensitivity |
| :--- | :--- | :---: |
| **Tunnel Payload Data** | User IP packets passing through the VPN tunnel (`10.0.0.0/24`). | **Critical** |
| **WireGuard Ephemeral Keys** | Ephemeral Curve25519 ECDH keypairs generated per session. | **High** |
| **WireGuard Static Identity Keys** | Long-term Curve25519 identity keypairs identifying peers. | **High** |
| **Post-Quantum Pre-Shared Keys (PSKs)** | 256-bit symmetric secrets negotiated by Rosenpass. | **Critical** |
| **Rosenpass Long-Term Keys** | Classic McEliece and ML-KEM identity keypairs. | **High** |
| **Routing & Policy Configuration** | Namespace routing tables, firewall rules, and allowed IPs. | **Medium** |

---

## 3. Trust Boundaries

```text
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ Endpoint Trust Boundary (Host OS / Linux Kernel)                       â”‚
â”‚   â€¢ In-Kernel WireGuard Module (Memory-only key storage)               â”‚
â”‚   â€¢ Isolated Namespaces: qs-server / qs-client                         â”‚
â”‚   â€¢ Rosenpass Daemon Process Memory (Mode 0600 keys)                   â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                                    â”‚
                                    â–¼ [Untrusted Boundary]
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ Untrusted Underlay Network (Transport Link 10.100.0.0/24 or Internet)  â”‚
â”‚   â€¢ Subject to passive eavesdropping, packet capture, recording        â”‚
â”‚   â€¢ Subject to active MitM, packet injection, replay, and dropping     â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                                    â”‚
                                    â–¼ [External Boundary]
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ External Control Plane (NetBird Management Server)                     â”‚
â”‚   â€¢ Coordinates overlay membership, peer public keys, and routing ACLs â”‚
â”‚   â€¢ Never receives or handles post-quantum session PSKs                â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

---

## 4. Adversary Models & Attack Vectors

### 4.1. Passive Network Attacker (Harvest-Now-Decrypt-Later / HNDL)
- **Profile**: A well-resourced nation-state or intelligence adversary capable of mass surveillance and long-term packet recording across public internet transit lines.
- **Goal**: Record encrypted WireGuard handshakes and payload traffic today. When a Cryptanalytically Relevant Quantum Computer (CRQC) running Shor's algorithm becomes available in the future, recover private keys and decrypt historical plaintext.
- **Mitigation in Q-Shield**:
  - The WireGuard handshake incorporates a post-quantum pre-shared key ($K_{pq}$) negotiated via Rosenpass.
  - Even if the adversary later calculates the discrete logarithm of the Curve25519 static and ephemeral keys, recovering the session key requires solving the post-quantum problems (Classic McEliece syndrome decoding and ML-KEM Module-LWE).

### 4.2. Active Man-in-the-Middle (MitM) Attacker
- **Profile**: An adversary capable of intercepting, modifying, injecting, or replaying UDP datagrams on ports 51820 (WireGuard) and 9999 (Rosenpass).
- **Mitigation in Q-Shield**:
  - **WireGuard**: Protected by the Noise IK framework. Handshakes are authenticated using static public keys, and packet injection is prevented via ChaCha20-Poly1305 MACs and replay windows.
  - **Rosenpass**: Authenticated post-quantum key exchange ensures that an active attacker cannot forge or tamper with the exchange without holding the responder's static post-quantum private key.

### 4.3. Compromised Management Plane
- **Profile**: An attacker compromises the central NetBird Management Server.
- **Impact & Mitigation**:
  - **Impact**: The attacker could revoke peers, alter routing rules, or push malicious access control policies.
  - **Mitigation**: The management plane **never learns or generates post-quantum session PSKs**. The cryptographic confidentiality of existing end-to-end data tunnels remains intact even if the control plane is compromised.

---

## 5. Cryptographic Composition & Hybrid Assumptions

> [!IMPORTANT]
> **Nuanced Cryptographic Claim**:
> Do **not** assume that combining cryptographic primitives automatically guarantees absolute immunity.
> In Q-Shield, the hybrid construction is **intended to retain confidentiality if one constituent cryptographic assumption fails, subject to proper protocol composition and implementation correctness**.

### Cryptographic Layer Analysis

| Layer | Primitive | Cryptographic Assumption | Failure Impact |
| :--- | :--- | :--- | :--- |
| **Classical ECDH** | Curve25519 | Computational Diffie-Hellman / Discrete Logarithm | Broken by quantum computers running Shor's algorithm; security relies entirely on Rosenpass PSK. |
| **Post-Quantum KEM 1** | Classic McEliece 460896 | Hardness of decoding random linear codes (Goppa codes) | Unbroken since 1978. If broken, security relies on ML-KEM and Curve25519. |
| **Post-Quantum KEM 2** | ML-KEM-768 (Kyber) | Hardness of Module Learning With Errors (M-LWE) | NIST FIPS 203 standard. If broken, security relies on McEliece and Curve25519. |
| **Symmetric Encryption** | ChaCha20-Poly1305 | Pseudo-random permutation and polynomial authenticator | Resistant to quantum speedups (Grover's algorithm halves effective key strength to 128 bits, remaining secure). |

Under the Noise IKpsk2 composition:

$$CK_{final} = \text{HKDF}(CK_{classical}, K_{pq})$$

An adversary must break both the classical key exchange **and** the post-quantum KEMs to compromise session confidentiality.

---

## 6. Endpoint Security, Memory & Operational Risks

### 6.1. Endpoint Compromise & Memory Disclosure
- **Threat**: An attacker gaining root/administrator privileges on the endpoint can dump process memory, inspect the Linux kernel keyring, or attach debuggers.
- **Analysis**: Q-Shield assumes the endpoint operating system and kernel are trustworthy. If the kernel or root account is compromised, the adversary can extract session keys regardless of post-quantum cryptography.
- **Mitigation**:
  - Key files (`*.pqsk`, `*.key`) are restricted to mode `0600` and owned by root.
  - PSKs are streamed via `/dev/stdin` and never persisted to the filesystem.
  - `wg show` automatically masks private and pre-shared keys as `(hidden)`.

### 6.2. Side-Channel & Timing Risks
- **Threat**: Cache timing or execution time variance revealing private key bits during post-quantum decapsulation.
- **Mitigation**: Both Classic McEliece and ML-KEM in `liboqs` / Rosenpass are engineered with constant-time implementations to mitigate timing side channels.

### 6.3. Denial of Service (DoS) Against Post-Quantum Handshakes
- **Threat**: Post-quantum public keys and ciphertexts are significantly larger than classical keys (Classic McEliece public keys exceed 500 KB). Flooding an endpoint with oversized KEM handshakes could exhaust memory or bandwidth.
- **Mitigation**: Rosenpass employs cookie mechanisms and rate-limiting on UDP port 9999 to mitigate unauthenticated resource exhaustion.

---

## 7. Residual Risks & Operational Assumptions

1. **Host Trust Assumption**: The local Linux host, kernel, and physical hardware are assumed free of rootkits and hardware keyloggers.
2. **Implementation Flaws**: Vulnerabilities in third-party libraries (e.g., `wireguard-go`, Rust Rosenpass, C `liboqs`) could compromise security independently of theoretical mathematical hardness.
3. **Denial of Service**: Network-level jamming or UDP packet blocking will disrupt availability, although confidentiality remains uncompromised.