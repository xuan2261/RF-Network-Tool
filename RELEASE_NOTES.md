# RF & Network Diagnostic Tool v1.5.1 — Route-Aware Private Multi-Subnet Candidate

## Scope

v1.5.1 builds on the physically qualified and merged v1.5.0 IPv6/NDP foundation and adds an explicit, bounded route-aware IPv4 scope planner.

- Existing manual CIDR scan behavior remains unchanged when Route-aware is OFF.
- Route-aware is opt-in and preserves the user-entered primary CIDR.
- Automatic route discovery reads Windows `Get-NetRoute -AddressFamily IPv4 -InterfaceIndex <selected>` only.
- Only RFC1918 destination ranges are eligible for automatic expansion.
- Default/public/wrong-interface/host-only/invalid routes are rejected.
- Automatic routes must be /24 through /30, so each added scope has at most 254 hosts.
- At most 4 automatic scopes are accepted and total unique targets are capped at 1024.
- Overlapping targets are deduplicated before the existing ScanWorker receives them.
- Route-table read failure is non-fatal: the scan falls back to the primary CIDR only.
- No route or IP mutation cmdlets are used.
- The v1.5.0 passive IPv6/NDP snapshot remains unchanged.

## Architecture

The route planner is isolated in `RF-Network-Tool-RoutePlanner.ps1` and is dot-sourced by the WinForms UI. The ScanWorker engine and its ICMP/ARP/neighbor/NDP execution path remain unchanged; the planner only prepares a bounded `Targets[]` set.

## Verification boundary

Hosted static/model/security tests, deterministic route fixtures on Windows PowerShell 5.1, Windows 2022/2025 runtime integration, chaos/recovery, performance, GUI accessibility behavior, cleanliness, package/SBOM integrity, reproducibility and attestations must pass on the exact PR head.

Because v1.5.1 changes the target-selection scope on the GUI path, a fresh Windows 10 FULL physical qualification on the exact final head is required before merge. Route-aware should be exercised on a private routed test topology when available; the normal exact-head GUI/LAN/cleanliness gates remain mandatory.
