# RF-Network-Tool

Portable Windows RF & network diagnostics tool.

Current stable baseline: **v1.5.3 monitoring correctness and discovery lifecycle hardening**.

Verification note: v1.5.3 passed hosted Windows Server 2022/2025 CI and reproducible packaging, but Windows 10 interactive physical qualification was **not run** for this release.

The repository includes:
- Windows PowerShell 5.1 / WinForms runtime
- async scan/discovery/ping/task workers
- opt-in route-aware private multi-subnet planning with bounded target expansion
- MAC-bound/provenance-aware device naming history
- Monitoring dashboard with separate collector-health/network-state semantics
- monotonic/reset-safe Monitoring accounting and auditable samples
- bounded Deep Analysis / Refresh worker lifecycle
- fail-closed name-discovery terminal validation
- static/model regression tests
- native Windows measurement regression tests
- Windows integration and launcher E2E tests
- GitHub Actions CI for Windows Server 2022 and 2025

See `README.txt`, `RELEASE_NOTES.md`, and `MEASUREMENT_HARDENING_v1.5.3.md` for verification scope and limitations.
