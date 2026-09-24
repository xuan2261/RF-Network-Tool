#!/usr/bin/env python3
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
version=(root/'VERSION').read_text(encoding='ascii').strip()
tag='v'+version
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
launcher=(root/'RF-Network-Tool-Launcher.ps1').read_text(encoding='utf-8-sig')
task=(root/'RF-Network-Tool-TaskWorker.ps1').read_text(encoding='utf-8-sig')
disc=(root/'RF-Network-Tool-DiscoveryWorker.ps1').read_text(encoding='utf-8-sig')
e2e=(root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig')
build=(root/'release_tools/build_release.py').read_text(encoding='utf-8')
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
checks={
 'version_semver':bool(re.fullmatch(r'\d+\.\d+\.\d+',version)),
 'candidate_is_v152':version=='1.5.2',
 'launcher_reads_version':all(x in launcher for x in ["Join-Path $BaseDir 'VERSION'",'$AppVersion','Launcher v$AppVersion']),
 'main_reads_version':all(x in main for x in ["Join-Path $BaseDir 'VERSION'",'$AppVersion','Portable v$AppVersion']),
 'workers_dynamic_useragent':all('$UserAgent' in x and 'RF-Network-Tool/1.4.2' not in x for x in [task,disc]),
 'e2e_dynamic_version':all(x in e2e for x in ['$appVersion','$escapedVersion',"'VERSION'"]),
 'builder_reads_version':"(project/'VERSION').read_text" in build and "tag=f'v{version}'" in build,
 'generic_release_tags':"tags: ['v*.*.*']" in ci,
 'generic_release_fail_closed':'Tag/version mismatch' in ci and 'GITHUB_REF_NAME' in ci,
 'generic_release_draft_first':'--draft' in ci and '--draft=false' in ci,
 'repo_readme_current_version':(root/'README.md').is_file() and tag in (root/'README.md').read_text(encoding='utf-8'),
 'current_release_notes':(root/'RELEASE_NOTES.md').is_file() and tag in (root/'RELEASE_NOTES.md').read_text(encoding='utf-8'),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
