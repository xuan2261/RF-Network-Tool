#!/usr/bin/env python3
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parent
files=[
 'core_contract_v1_3_1.py','evidence_contract_v1_3_1.py','history_contract_v1_3_1.py','profile_policy_contract_v1_3_1.py',
 'runid_contract_v1_3_1.py','scan_state_contract_v1_3_1.py','target_persistence_contract_v1_3_1.py',
 'async_ping_contract_v1_4_0.py','oui_task_contract_v1_4_0.py','responsiveness_contract_v1_4_0.py','monitoring_contract_v1_4_0.py',
 'runtime_integrity_contract_v1_4_2.py','ipv6_ndp_contract_v1_4_2.py','ci_workflow_contract_v1_4_2.py','real_machine_harness_contract_v1_4_2.py','security_audit_v1_4_2.py','static_audit_v1_4_2.py'
]
failed=[]
for f in files:
 print(f'\n=== {f} ===',flush=True)
 r=subprocess.run([sys.executable,str(root/f)])
 if r.returncode:failed.append(f)
print(f'\nACTIVE STATIC TEST FILES {len(files)} FAILED {len(failed)}')
if failed:print('FAILED:',', '.join(failed))
sys.exit(1 if failed else 0)