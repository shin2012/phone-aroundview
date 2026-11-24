#!/usr/bin/env python3
"""Refuse a TestFlight upload whose app version has no CHANGELOG entry.

Prints the version for later steps (GITHUB_OUTPUT `version`)."""
import os, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parents[2]
spec = (root / "ios/project.yml").read_text(encoding="utf-8")
m = re.search(r"MARKETING_VERSION:\s*'?(\d+\.\d+\.\d+)'?", spec)
if not m:
    sys.exit("MARKETING_VERSION(x.y.z)을 ios/project.yml에서 찾지 못했습니다.")
version = m.group(1)
changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
if not re.search(rf"^## {re.escape(version)}\b", changelog, re.M):
    sys.exit(f"CHANGELOG.md에 '## {version}' 항목이 없습니다. 버전을 올리고 변경 내용을 적으세요.")
print(f"버전 {version}")
out = os.environ.get("GITHUB_OUTPUT")
if out:
    with open(out, "a", encoding="utf-8") as f:
        f.write(f"version={version}\n")
