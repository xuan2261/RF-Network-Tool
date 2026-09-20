# Code Review v1.4.2

The production runtime was diffed against v1.4.1. No behavior-bearing runtime logic changed in v1.4.2; only release display strings and HTTP User-Agent version strings changed. The new code is confined to tests, CI workflows, release tooling, and QA documentation.

Key review findings:

1. CI is fail-closed: package generation depends on both static contracts and the hosted Windows runtime matrix.
2. No `continue-on-error` is used in required QA jobs.
3. Windows labels are pinned (`windows-2022`, `windows-2025`) instead of relying on the moving `windows-latest` alias.
4. Interactive GUI automation is intentionally separated onto a manually dispatched self-hosted runner because GUI automation requires an interactive user session.
5. E2E launch runs from an isolated temporary copy to avoid mutating source-controlled runtime data.