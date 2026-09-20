# Changelog v1.4.2 — Full QA / CI-E2E

- Preserves the v1.4.1 runtime-integrity fixes. Runtime logic is unchanged except release/user-agent identity strings.
- Adds GitHub Actions CI with pinned `windows-2022` and `windows-2025` Windows PowerShell 5.1 integration lanes.
- Adds a pinned PSScriptAnalyzer 1.25.0 parser/lint gate.
- Adds launcher diagnostic E2E on hosted Windows and an interactive WinForms UI smoke E2E workflow for a logged-in self-hosted Windows runner.
- Adds request-level PingWorker failure/recovery integration coverage.
- Adds CI workflow regression contracts and package checks for the new QA assets.
- Release packaging remains fail-closed behind static/model + Windows runtime jobs in CI.