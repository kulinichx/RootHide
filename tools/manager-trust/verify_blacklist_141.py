"""Verify the 1.4.1 source rebuild and its retained upstream protections."""
import argparse
import json
from pathlib import Path

import build
import verify_blacklist_140


def verify(path, source):
    report = verify_blacklist_140.verify(path, source, version="1.4.1")
    _, payload = build.deb_read(path.read_bytes())
    binary = payload["Applications/RootHide.app/RootHide"][1]
    for subtype, _, blob in build.slices(binary):
        for text in ("_TrollStore", "_TrollStoreLite", "applicationProxy", "Scanning..."):
            build.require(text.encode() in blob, f"Missing 1.4.1 implementation: {text}")
    for name, (_, data) in payload.items():
        if name.endswith(".json"):
            build.require(
                name == "Applications/RootHide.app/varCleanRules.json"
                and data == (source / "RootHide/VarCleanRules.json").read_bytes(),
                f"Unexpected cleanup rules: {name}",
            )
    report["upstream_141_protection_markers_present"] = True
    report["cleanup_rules_unchanged"] = True
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("deb", type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = verify(args.deb, args.source)
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        args.report.write_text(encoded, encoding="utf-8")
    print(encoded)
