#!/usr/bin/env python3
"""Fail-closed verification for a published immutable GitHub release."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def expected_asset_names(version: str) -> list[str]:
    prefix = f"RF-Network-Tool-v{version}-FULL-QA-CI-E2E"
    return [
        f"{prefix}-PORTABLE.zip",
        f"{prefix}-PROJECT.zip",
        f"{prefix}-PORTABLE.spdx.json",
        f"{prefix}-PROJECT.spdx.json",
        "SHA256SUMS.txt",
    ]


def read_checksums(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            raise ValueError(f"Malformed checksum line: {raw!r}")
        digest, name = parts
        name = name.lstrip("*")
        if not SHA256_RE.fullmatch(digest):
            raise ValueError(f"Invalid SHA-256 for {name}: {digest}")
        if name in result:
            raise ValueError(f"Duplicate checksum entry: {name}")
        result[name] = digest
    return result


def verify(
    release: dict,
    asset_dir: Path,
    version: str,
    expected_sha: str,
    tag_sha: str,
) -> tuple[list[str], dict]:
    failures: list[str] = []
    expected_sha = expected_sha.lower()
    tag_sha = tag_sha.lower()
    tag = f"v{version}"

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        failures.append(f"invalid version: {version}")
    if not SHA40_RE.fullmatch(expected_sha):
        failures.append(f"invalid expected SHA: {expected_sha}")
    if not SHA40_RE.fullmatch(tag_sha):
        failures.append(f"invalid resolved tag SHA: {tag_sha}")
    if tag_sha != expected_sha:
        failures.append(f"tag SHA mismatch: resolved={tag_sha} expected={expected_sha}")

    if release.get("tag_name") != tag:
        failures.append(f"release tag mismatch: {release.get('tag_name')!r} != {tag!r}")
    if release.get("target_commitish") != expected_sha:
        failures.append(
            f"release target_commitish mismatch: {release.get('target_commitish')!r} != {expected_sha!r}"
        )
    if release.get("draft") is not False:
        failures.append("published release must have draft=false")
    if release.get("prerelease") is not False:
        failures.append("published release must have prerelease=false")
    if release.get("immutable") is not True:
        failures.append("published release must have immutable=true")

    names = expected_asset_names(version)
    expected = set(names)
    assets_raw = release.get("assets")
    if not isinstance(assets_raw, list):
        failures.append("release assets must be a list")
        assets_raw = []

    by_name: dict[str, dict] = {}
    duplicates: list[str] = []
    for asset in assets_raw:
        if not isinstance(asset, dict):
            failures.append("release asset entry must be an object")
            continue
        name = asset.get("name")
        if not isinstance(name, str):
            failures.append("release asset is missing a string name")
            continue
        if name in by_name:
            duplicates.append(name)
        else:
            by_name[name] = asset
    if duplicates:
        failures.append(f"duplicate release assets: {sorted(set(duplicates))}")

    actual = set(by_name)
    if actual != expected:
        failures.append(
            f"release asset set mismatch: missing={sorted(expected-actual)} extra={sorted(actual-expected)}"
        )

    local_digests: dict[str, str] = {}
    local_sizes: dict[str, int] = {}
    for name in names:
        path = asset_dir / name
        if not path.is_file():
            failures.append(f"local release asset missing: {name}")
            continue
        if path.stat().st_size <= 0:
            failures.append(f"local release asset is empty: {name}")
            continue
        local_digests[name] = sha256_file(path)
        local_sizes[name] = path.stat().st_size

    checksum_name = "SHA256SUMS.txt"
    checksum_members = expected - {checksum_name}
    checksum_path = asset_dir / checksum_name
    try:
        checksums = read_checksums(checksum_path) if checksum_path.is_file() else {}
    except Exception as exc:
        failures.append(f"invalid SHA256SUMS.txt: {exc}")
        checksums = {}

    if set(checksums) != checksum_members:
        failures.append(
            f"SHA256SUMS asset set mismatch: missing={sorted(checksum_members-set(checksums))} "
            f"extra={sorted(set(checksums)-checksum_members)}"
        )
    for name in sorted(checksum_members):
        digest = local_digests.get(name)
        if digest is not None and checksums.get(name) != digest:
            failures.append(f"SHA256SUMS mismatch for {name}: {checksums.get(name)!r} != {digest}")

    for name in names:
        asset = by_name.get(name)
        digest = local_digests.get(name)
        if asset is None or digest is None:
            continue
        if asset.get("state") != "uploaded":
            failures.append(f"release asset state is not uploaded for {name}: {asset.get('state')!r}")
        if asset.get("digest") != f"sha256:{digest}":
            failures.append(
                f"release asset digest mismatch for {name}: {asset.get('digest')!r} != sha256:{digest}"
            )
        if asset.get("size") != local_sizes[name]:
            failures.append(
                f"release asset size mismatch for {name}: {asset.get('size')!r} != {local_sizes[name]}"
            )

    evidence = {
        "schemaVersion": 1,
        "version": version,
        "tag": tag,
        "sourceRevision": expected_sha,
        "resolvedTagRevision": tag_sha,
        "immutable": release.get("immutable"),
        "draft": release.get("draft"),
        "prerelease": release.get("prerelease"),
        "releaseUrl": release.get("html_url"),
        "assetDigests": {
            name: f"sha256:{local_digests[name]}"
            for name in names
            if name in local_digests
        },
        "pass": len(failures) == 0,
        "failures": failures,
    }
    return failures, evidence


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--release-json", required=True, type=Path)
    p.add_argument("--asset-dir", required=True, type=Path)
    p.add_argument("--version", required=True)
    p.add_argument("--expected-sha", required=True)
    p.add_argument("--tag-sha", required=True)
    p.add_argument("--evidence-out", required=True, type=Path)
    args = p.parse_args()

    release = json.loads(args.release_json.read_text(encoding="utf-8"))
    failures, evidence = verify(
        release=release,
        asset_dir=args.asset_dir,
        version=args.version,
        expected_sha=args.expected_sha,
        tag_sha=args.tag_sha,
    )
    args.evidence_out.parent.mkdir(parents=True, exist_ok=True)
    args.evidence_out.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if failures:
        for item in failures:
            print(f"FAIL {item}", file=sys.stderr)
        print(f"IMMUTABLE RELEASE VERIFICATION FAILED ({len(failures)} issue(s))", file=sys.stderr)
        return 1

    print("IMMUTABLE RELEASE VERIFICATION PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
