#!/usr/bin/env python3
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
module_path = root / "release_tools" / "verify_published_release.py"
spec = importlib.util.spec_from_file_location("verify_published_release", module_path)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(mod)

VERSION = "9.8.7"
SHA = "0123456789abcdef0123456789abcdef01234567"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_fixture(base: Path):
    names = mod.expected_asset_names(VERSION)
    payloads = {
        names[0]: b"portable-zip",
        names[1]: b"project-zip",
        names[2]: b'{"sbom":"portable"}\n',
        names[3]: b'{"sbom":"project"}\n',
    }
    for name, data in payloads.items():
        (base / name).write_bytes(data)
    checksum_lines = [
        f"{digest(base / name)}  {name}"
        for name in sorted(payloads)
    ]
    (base / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")

    assets = []
    for name in names:
        path = base / name
        assets.append(
            {
                "name": name,
                "state": "uploaded",
                "size": path.stat().st_size,
                "digest": f"sha256:{digest(path)}",
            }
        )
    release = {
        "tag_name": f"v{VERSION}",
        "target_commitish": SHA,
        "draft": False,
        "prerelease": False,
        "immutable": True,
        "html_url": f"https://github.example/releases/v{VERSION}",
        "assets": assets,
    }
    return release


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print("PASS", name)


with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    release = make_fixture(base)

    failures, evidence = mod.verify(release, base, VERSION, SHA, SHA)
    check("valid_release_passes", failures == [] and evidence["pass"] is True)

    bad = copy.deepcopy(release)
    bad["immutable"] = False
    failures, _ = mod.verify(bad, base, VERSION, SHA, SHA)
    check("mutable_release_rejected", any("immutable=true" in x for x in failures))

    failures, _ = mod.verify(release, base, VERSION, SHA, "f" * 40)
    check("wrong_tag_revision_rejected", any("tag SHA mismatch" in x for x in failures))

    bad = copy.deepcopy(release)
    bad["target_commitish"] = "f" * 40
    failures, _ = mod.verify(bad, base, VERSION, SHA, SHA)
    check("wrong_target_commitish_rejected", any("target_commitish mismatch" in x for x in failures))

    bad = copy.deepcopy(release)
    bad["assets"][0]["digest"] = "sha256:" + ("0" * 64)
    failures, _ = mod.verify(bad, base, VERSION, SHA, SHA)
    check("wrong_release_digest_rejected", any("digest mismatch" in x for x in failures))

    bad = copy.deepcopy(release)
    bad["assets"].append(
        {"name": "unexpected.bin", "state": "uploaded", "size": 1, "digest": "sha256:" + ("0" * 64)}
    )
    failures, _ = mod.verify(bad, base, VERSION, SHA, SHA)
    check("extra_release_asset_rejected", any("asset set mismatch" in x for x in failures))

    checksum = base / "SHA256SUMS.txt"
    original = checksum.read_text(encoding="utf-8")
    checksum.write_text(original.replace(original[:64], "0" * 64, 1), encoding="utf-8")
    failures, _ = mod.verify(release, base, VERSION, SHA, SHA)
    check("checksum_tamper_rejected", any("SHA256SUMS mismatch" in x for x in failures))

print("RELEASE PUBLICATION VERIFIER TESTS PASSED")
