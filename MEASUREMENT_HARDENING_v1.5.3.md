# v1.5.3 candidate: measurement correctness and discovery lifecycle

Base: 5dc8c076c5bf76e31d29606e9cba322d1d15c72d (published v1.5.2).
This change does not move the v1.5.2 tag or publish a release. VERSION remains the
last released version until finalization. Windows 10 physical qualification of
the final candidate is required before promotion.

## Accepted scope

- Collector health (OK / WAITING / PAUSED / STALE / ENGINE ERROR) is separate
  from the last observed network state. Grid and summary use the same rule.
- Local measurement exceptions are counted separately and excluded from the
  ICMP network-loss denominator and outage counter.
- Accounting uses Stopwatch timestamps with a freshness cap; display projections
  do not mutate committed accounting. Unknown, paused and failed-collector gaps
  are not silently treated as continuous reachability.
- Reset rotates a statistics epoch. Pause/resume rotates the target generation.
  Results and missing-result errors from old requests cannot change new stats.
- PingWorker records worker-observed completion timestamps per target, polling
  completed tasks independently. These are not hardware packet timestamps.
- TimeSpan.Days formats whole days correctly. No rounding of fractional days.
- Real Monitoring columns have measured minimum widths, full headers, frozen
  identification columns and horizontal scroll. No font shrink to hide clipping.
- Device Details reads adapter information without resetting CIDR/status.
- Name discovery requires process exit 0 AND independent session/run-bound
  SUCCESS terminal JSON with a completed requested observation window. Missing,
  malformed, cancelled, early, contradictory and failed evidence is not green.
- Final scan summary retains Online, L2, NDP6 and IPv4 counts plus core/total time.

## Verification

`tests/WINDOWS_MEASUREMENT_TEST_v1_5_3.ps1` extracts exact production function
ASTs. It replaces only the clock and IO/UI side effects of accounting unit tests;
it does not replace the accounting implementation with a separate model.
Its layout tests instantiate the production DataGridView column initializer.
Font-scale tests are not a claim of operating-system DPI testing.
`-BaselineRed` executes two assertions on v1.5.2: 36-hour duration and excluding
measurement errors from network loss. Both must reproduce before applying fixes.

Existing Windows integration now checks a real five-second discovery worker,
terminal success, malformed input, explicit cancellation, and PingWorker sample
metadata. Native measurement tests run in hosted CI and the physical harness.
Physical workflow independently validates measurement JSON and exact revision.

The user's earlier 6.3-second DEEP residual-time observation remains unexplained
without that run's logs. This patch prevents an early/crashed name worker from
being reported as successful; it does not assert a live-network root cause.

## Release gate

All original parser/static/lint/runtime/packaging gates remain active. No analyzer
baseline increase or test suppression. Final exact-head hosted CI and physical
Windows 10 results must be inspected, not inferred from file/step existence.
