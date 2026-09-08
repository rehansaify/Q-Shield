# Stage 3: Rosenpass Post-Quantum Key Exchange Integration

> [!IMPORTANT]
> **Cryptographic Scope and Hybrid Model**:
> **WireGuard itself remains a classical cryptographic transport. Post-quantum protection is provided by the Rosenpass-derived WireGuard preshared key.**
> This is a **hybrid** construction: classical Diffie-Hellman on Curve25519 is combined with post-quantum Key Encapsulation Mechanisms (Classic McEliece and ML-KEM). We do not claim unconditional security against every hypothetical quantum attack, but rather verifiable protection against the Harvest-Now-Decrypt-Later (HNDL) adversary targeting the discrete logarithm problem.

---

## 1. Why Stage 2 Alone is Not Post-Quantum

In Stage 2, WireGuard establishes its transport session using the standard Noise IKpsk2 handshake pattern. Key agreement relies entirely on **Curve25519 (X25519)** elliptic curve Diffie-Hellman.

- **The Threat (Harvest Now, Decrypt Later - HNDL)**: A passive adversary recording encrypted tunnel traffic today cannot decrypt it with classical supercomputers. However, once a Cryptanalytically Relevant Quantum Computer (CRQC) is realized, **Shor's algorithm** can solve the Elliptic Curve Discrete Logarithm Problem (ECDLP) in polynomial time, recovering the session keys and decrypting the recorded historical traffic.
- **Limitation**: WireGuard's core cryptographic primitives (X25519, ChaCha20-Poly1305, BLAKE2s) are fixed in the kernel protocol. WireGuard does not natively offer quantum-resistant key exchange algorithms.

---

## 2. What Rosenpass Adds

**Rosenpass** (v0.2.3) is an authenticated post-quantum key exchange protocol designed specifically to secure WireGuard tunnels against quantum adversaries.

- **Cryptographic Algorithms**:
  - **Classic McEliece** (`mceliece460896`): Based on the hardness of decoding general linear codes, a problem studied since 1978 with zero known sub-exponential quantum attacks.
  - **ML-KEM / Kyber**: A lattice-based key encapsulation mechanism providing high-performance post-quantum secrecy and smaller public keys.
- **Protocol Operation**: Rosenpass runs as an out-of-band userland daemon over UDP port 9999. It negotiates an authenticated 256-bit symmetric shared secret between `qs-server` and `qs-client`.

---

## 3. How Rosenpass Interacts with WireGuard & The PSK Slot

WireGuard provides an integrated 256-bit Pre-Shared Key (PSK) slot within its Noise IKpsk2 handshake:
$$\text{MixKeyAndHash}(\text{PSK})$$

```
+--------------------------------------------------------------------------------+
|                                 Q-Shield Node                                  |
|                                                                                |
|  +---------------------------+             +--------------------------------+  |
|  |     Rosenpass Daemon      |             |     WireGuard Engine (wg0)     |  |
|  |                           |             |                                |  |
|  | - Classic McEliece KEM    |             | - Curve25519 DH (X25519)       |  |
|  | - ML-KEM / Kyber          |             | - ChaCha20-Poly1305 AEAD       |  |
|  | - Derives 256-bit secret  |             | - Noise IKpsk2 Handshake       |  |
|  +-------------+-------------+             +---------------+----------------+  |
|                |                                           ^                   |
|                | Native PSK injection                      |                   |
|                | wg set wg0 peer <ID> preshared-key /dev/stdin                 |
|                +-------------------------------------------+                   |
+--------------------------------------------------------------------------------+
```

1. **Native Pipe Delivery**: Rosenpass natively invokes `wg set wg0 peer <PEER_PUBKEY> preshared-key /dev/stdin`.
2. **In-Kernel Key Ratchet**: WireGuard mixes the 256-bit Rosenpass secret into its internal chaining key and handshake hash.
3. **Seamless Handshake**: When the next Noise handshake occurs, the ephemeral session key is derived jointly from the classical X25519 exchange **and** the post-quantum PSK.

---

## 4. Why the Construction is Hybrid (Dual-Defense)

The security of the Q-Shield tunnel is defined by the **combiner principle**:
- If an adversary builds a quantum computer that breaks Curve25519, the session keys remain completely confidential because the adversary must still solve the decoding problem of Classic McEliece and the learning-with-errors problem of ML-KEM.
- If a mathematical breakthrough weakens a post-quantum lattice problem, the session remains secured by the classical hardness of Curve25519 against classical adversaries.
- **Session confidentiality holds if EITHER classical DH OR the post-quantum KEM holds.**

---

## 5. Secret Leak Prevention & Zero-Exposure Guarantee

To eliminate secret leakage:
1. **Zero-Disk PSK Exposure**: Rosenpass streams the generated PSK directly into WireGuard via standard input (`/dev/stdin`). The secret is never stored on disk.
2. **Zero-CLI Exposure**: The PSK is never passed as a command-line argument, preventing observation via `/proc` or `ps`.
3. **Kernel Masking**: WireGuard masks configured PSKs in `wg show` as `(hidden)`.
4. **Non-Secret Verification Fingerprint**: In automated testing, the presence and synchronization of the PSK is validated using `SHA-256(PSK)`, labeled strictly as a `non-secret verification fingerprint`. The raw PSK is never displayed or stored.
5. **Key Storage**: Rosenpass secret keys (`server.pqsk`, `client.pqsk`) are stored in `/etc/wireguard/qshield/rosenpass/` with permissions `0600` and are strictly excluded by `.gitignore`.

---

## 6. Execution & Lifecycle Runbook

All commands require root privileges.

### A. Deploy Stage 3 Post-Quantum Tunnel
```bash
sudo bash scripts/setup_rosenpass_stage3.sh
```
*Action*: Verifies Stage 1 and Stage 2 baselines, generates McEliece/ML-KEM keypairs, launches Rosenpass on `qs-server` and `qs-client`, completes the post-quantum exchange, and populates the WireGuard PSK.

### B. Run Stage 3 Verification (14 Automated Tests)
```bash
sudo bash scripts/verify_stage3.sh
```
*Action*: Runs all 14 tests, validates zero secret leakage, checks handshake freshness, verifies 0% ping packet loss, and exports `results/stage3_results.json`.

### C. Teardown Stage 3 (Restore Classical Baseline)
```bash
sudo bash scripts/teardown_rosenpass_stage3.sh
```
*Action*: Terminates Rosenpass processes, clears the WireGuard PSK (`preshared-key /dev/null`), and restores the Stage 2 classical WireGuard baseline without deleting namespaces or `wg0`.

---

## 7. Stage 3 Verification Checklist Matrix

| Check | Description | Status | Evidence |
| :--- | :--- | :---: | :--- |
| **TEST 1** | WireGuard interface baseline | **PASS** | `wg0` exists on both `qs-server` and `qs-client` |
| **TEST 2** | Baseline transport functionality | **PASS** | Initial ICMP ping succeeds before PQ injection |
| **TEST 3** | Rosenpass PQ key material | **PASS** | Classic McEliece + ML-KEM keys verified (mode `0600`) |
| **TEST 4** | Rosenpass server process | **PASS** | Server daemon running actively |
| **TEST 5** | Rosenpass client process | **PASS** | Client daemon running actively |
| **TEST 6** | UDP transport link | **PASS** | Port 9999 bound and listening on `10.100.0.1` |
| **TEST 7** | Rosenpass post-quantum exchange | **PASS** | Exchange authenticated and completed |
| **TEST 8** | WireGuard PSK installed | **PASS** | `preshared key:` populated on both server and client |
| **TEST 9** | Zero PSK leakage & fingerprint | **PASS** | PSK masked as `(hidden)`; non-secret SHA-256 matches |
| **TEST 10** | Hybrid handshake recency | **PASS** | Noise IKpsk2 handshake completed with PSK (age: 1s) |
| **TEST 11** | Client -> Server PQ ping | **PASS** | 3/3 packets received over PQ tunnel (0% loss) |
| **TEST 12** | Server -> Client PQ ping | **PASS** | 3/3 packets received over PQ tunnel (0% loss) |
| **TEST 13** | Traffic counter progression | **PASS** | WireGuard `transfer` counters advanced monotonically |
| **TEST 14** | Daemon persistence | **PASS** | Both Rosenpass daemons remain stably running |