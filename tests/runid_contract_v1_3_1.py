#!/usr/bin/env python3
"""Run-identity contract: stale scan/name worker state must never be applied."""
import sys

def accept(expected,payload):
    return bool(payload) and (not expected or payload.get('runId')==expected)
checks={
 'scan_accept_matching':accept('scan-new',{'runId':'scan-new','schemaVersion':3}),
 'scan_reject_stale':not accept('scan-new',{'runId':'scan-old','schemaVersion':3}),
 'scan_reject_missing':not accept('scan-new',{'schemaVersion':3}),
 'discovery_accept_matching':accept('disc-new',{'runId':'disc-new','schemaVersion':4}),
 'discovery_reject_stale':not accept('disc-new',{'runId':'disc-old','schemaVersion':4}),
 'discovery_reject_missing':not accept('disc-new',{'schemaVersion':4}),
 'no_expected_allows_compat':accept('',{'schemaVersion':4}),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed));sys.exit(1 if failed else 0)