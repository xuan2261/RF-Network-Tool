# RF-Network-Tool v1.5.3 — current status

This file is the **stateful post-release status** for v1.5.3. Evergreen usage belongs in `README.md` / `README.txt`; implementation contracts belong in source/tests.

## Release identity

- version: **1.5.3**
- tag: `v1.5.3`
- release commit: `1ae01b7b4e3da80f80d004f0b41f5e4929605128`
- published release: https://github.com/xuan2261/RF-Network-Tool/releases/tag/v1.5.3
- release state: published, not draft, not prerelease
- v1.5.3 Release API immutability flag at last check: **false**
- repository immutable-releases setting: **enabled=true**, `enforced_by_owner=false`

## Verification ledger

| Evidence | Result |
| --- | --- |
| Runtime PR CI `36070746171` on `9c49389f...` | PASS |
| Runtime post-merge CI `36071327268` on `dff1f2d3...` | PASS |
| Release-finalization PR CI `36080153768` | PASS |
| Final main CI `36080645401` on release commit | PASS |
| Publication workflow `36081055104` | PASS |
| Windows Server 2022 / PowerShell 5.1 | PASS |
| Windows Server 2025 / PowerShell 5.1 | PASS |
| Native Monitoring correctness / layout suite | PASS |
| Static/model + PSScriptAnalyzer | PASS |
| Chaos/recovery + synthetic performance | PASS |
| Reproducible packaging + SPDX SBOM + attestations | PASS |
| Windows 10 interactive physical Full qualification | **PASS — post-release backfill run #9 (`36140460684`)** |

Publication without Windows 10 physical qualification was an explicit user-authorized exception because the laptop was unavailable. The publication-time statement is preserved in `RELEASE_NOTES.md`; it does not describe the later backfill state.

## Physical backfill evidence

- workflow: `RF Network Tool Physical Qualification`
- successful run: #9 / `36140460684`
- exact qualified revision: `1ae01b7b4e3da80f80d004f0b41f5e4929605128`
- runner: Windows 10 Pro build 19045, Windows PowerShell 5.1.19041.6456
- sanitized artifact: `physical-qualification-evidence` / artifact `10868745380`
- artifact digest: `sha256:8fcc80d5f683bac13b42c3582891e07a835a2541143945eebd23a5e450de36ee`
- aggregate physical result: `18 PASS / 0 FAIL / 0 SKIP`
- required gates: `measurement_correctness`, `interactive_gui_e2e`, `deep_ui_e2e`, `route_scope_planner`, `route_scope_live`, `real_lan_fast_balanced`, machine-cleanliness baseline/post — all PASS
- independent deep-UI evidence: `status=PASS`, `stage=completed`, `workerCompleted=true`, `workerSucceeded=true`, `lastPhase=Completed`

An earlier backfill attempt (#8 / `36139701374`) failed `deep_ui_e2e` and is not treated as passing evidence. Run #9 on the same release SHA subsequently passed the complete gate set.

## Published assets

| Asset | SHA-256 |
| --- | --- |
| `RF-Network-Tool-v1.5.3-FULL-QA-CI-E2E-PORTABLE.zip` | `d06f29248a36d58e89f20c18abe58c24f14c5baaaab78131e1f43967eabbadc1` |
| `RF-Network-Tool-v1.5.3-FULL-QA-CI-E2E-PROJECT.zip` | `3b8324e7b7b13215f26448510fa6d9d464476a08dc738f18ca3b7d9dbb2ad417` |
| `RF-Network-Tool-v1.5.3-FULL-QA-CI-E2E-PORTABLE.spdx.json` | `38f9888b30c4d64587d19bed0643dae306cda4396ca0390d60304fc4f469fe6f` |
| `RF-Network-Tool-v1.5.3-FULL-QA-CI-E2E-PROJECT.spdx.json` | `24a8872fe1edb7e20fdc14be0a814addf5c0a99940d5f7c6fbff4f33fe946ca8` |
| `SHA256SUMS.txt` | `f40036bfe0f7c6ae7b890d531b1e5062353a63fda73c73467e186674955abe44` |

Use the public `SHA256SUMS.txt` in the release when verifying downloaded ZIP/SBOM assets.

## Follow-ups

### #21 — Windows 10 physical backfill — COMPLETE

https://github.com/xuan2261/RF-Network-Tool/issues/21

Run #9 (`36140460684`) qualified the exact v1.5.3 release SHA and satisfied every required physical gate. The sanitized evidence artifact was inspected before closing the issue. No tag or release asset was moved or replaced.

### #22 — Enable immutable releases for future releases — OPEN

https://github.com/xuan2261/RF-Network-Tool/issues/22

The repository immutable-releases setting is now enabled and verified as `{"enabled":true,"enforced_by_owner":false}`. GitHub documents that this setting applies to **future releases only**. Published immutable release tags/assets are locked while title/notes and selected release metadata remain editable.

The already-published v1.5.3 release still reports `immutable=false`, as expected because the setting is not retroactive. Issue #22 remains open until the next release is created draft-first with all assets attached before publication and the published release is verified with `immutable=true`.

The generic tag-release workflow is hardened for the next release: it verifies the exact tag revision before publication, requires the draft asset set to match exactly, validates local checksums, and after publication requires Release API `immutable=true` plus exact uploaded asset SHA-256/size matches before Issue #22 can be closed.

## Change policy after publication

- Do not move `v1.5.3`.
- Do not replace v1.5.3 ZIP/SBOM/checksum assets to patch behavior.
- If later use finds a runtime defect, fix it in **v1.5.4+**.
- Preserve v1.5.3 release notes as the publication-time verification statement.
