# RF & Network Diagnostic Tool v1.5.0 — IPv6/NDP Foundation Candidate

## Scope

v1.5.0 builds on the fully qualified v1.4.3 release-hardening baseline and adds a deliberately passive IPv6 Neighbor Discovery foundation.

- IPv4 FAST/BALANCED/DEEP scan semantics remain unchanged.
- After IPv4 ICMP/ARP/Neighbor processing, the scan worker snapshots Windows IPv6 neighbor-cache entries on the selected interface only.
- The tool does not enumerate or brute-force IPv6 address space and does not create, modify, or remove neighbor/IP entries.
- Unreachable/incomplete, zero-MAC, unspecified, loopback, multicast, and malformed IPv6 entries are excluded.
- State exposes additive `ipv6Neighbors` plus `IPv6NeighborCount` / `IPv6NeighborError` metrics.
- UI/history surface only the NDP6 count in this foundation release; IPv4 and IPv6 identity are not merged yet.
- The v1.4.3 deterministic SPDX 2.3 SBOM and provenance/SBOM attestation pipeline remains mandatory.

## Verification boundary

Hosted static/model/security, Windows PowerShell 5.1 runtime, chaos/recovery, performance, MSAA tab behavior, cleanliness, package/SBOM integrity, reproducibility, and attestations must pass on the exact PR head.

Because this candidate changes the runtime scan worker, a fresh Windows 10 FULL physical qualification on the exact head is required before merge. Real-LAN FAST/BALANCED, GUI navigation, source revision, and post-run cleanliness must all PASS with overall FAIL=0.
