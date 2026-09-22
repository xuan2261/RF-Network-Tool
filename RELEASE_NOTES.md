# RF & Network Diagnostic Tool v1.4.3 — Release Hardening Candidate

## Scope

This candidate keeps the v1.4.2 runtime behavior while hardening versioning, packaging, and release publication.

- `VERSION` is the single source of truth for the application/release version.
- Launcher, GUI title, scan-engine log, HTTP User-Agent, package names, manifest names, CI artifacts, and release tag validation derive from `VERSION`.
- Release ZIPs remain byte-reproducible and receive GitHub artifact provenance attestations.
- Each PROJECT/PORTABLE ZIP also receives a deterministic SPDX 2.3 JSON SBOM derived from the exact ZIP bytes and a dedicated SBOM attestation verified before publication.
- Tag publication is generic for semantic tags (`v*.*.*`) but fails closed unless the pushed tag exactly equals `v` + `VERSION`.
- Release publication is create-only: an existing tag/release is never clobbered.
- Publication uses a draft first so all assets are attached before the release is published.

## Verification boundary

Hosted static/model/security, Windows PowerShell 5.1 runtime, chaos/recovery, synthetic performance, launcher diagnostic E2E, package integrity, byte reproducibility, and provenance must all pass before a release job can run.

Full interactive WinForms UIAutomation and real-LAN qualification remain physical-machine gates. Do not publish v1.4.3 until those gates are reviewed for the release candidate.
