# Code Review v1.4.2

The v1.4.2 branch now contains both verification infrastructure and narrowly scoped runtime compatibility repairs discovered by executing the exact code on Windows PowerShell 5.1.

## Verified review findings

1. Runtime behavior changes are limited to cause-aligned compatibility/integrity repairs: generic `List[object]` enumeration uses `.ToArray()`; scan-row and Ping/Monitoring integrity fixes from v1.4.1 remain intact.
2. CI is fail-closed: release packaging depends on deterministic/static contracts and both hosted Windows runtime lanes.
3. Required QA jobs do not use `continue-on-error`.
4. Windows labels are pinned to `windows-2022` and `windows-2025`.
5. PowerShell parser/PSScriptAnalyzer, launcher diagnostic E2E, worker IPC, scan profiles, Ping/Monitoring recovery, OUI tasking, persistence, locking, and packaging are exercised by executable gates.
6. Interactive GUI automation is isolated to a manual self-hosted workflow because desktop UI automation needs an interactive Windows session.
7. E2E launch uses an isolated temporary runtime copy to avoid mutating the checked-out source/data directory.
8. Release packaging explicitly excludes `.git` metadata and tests the final ZIP for VCS contamination.
9. Generated SHA/manifest/check-result files are not source-controlled; they are generated from the exact release candidate.
10. GitHub Actions are on Node 24 generations.

## Residual review debt

PSScriptAnalyzer still reports non-blocking style/maintainability warnings and information, primarily empty catch blocks, positional parameters, and naming conventions. Error/ParseError findings are zero. The correctness-oriented `PSAvoidAssignmentToAutomaticVariable` and `PSPossibleIncorrectComparisonWithNull` classes are explicitly release-blocking and must remain zero.

The remaining material verification gap is interactive WinForms functional E2E on a logged-in self-hosted Windows runner.
