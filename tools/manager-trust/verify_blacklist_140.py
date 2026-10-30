"""Verify a source-built blacklist trust port without installing the package."""
import argparse
import hashlib
import json
import plistlib
import struct
from pathlib import Path

import build

APP = "Applications/RootHide.app"
REQUIRED_TEXT = (
    "TrustedBindMountsV1",
    "IgnoreVPNProxyWarningV1",
    "showBindMountTrustPrompt:",
    "trustBindMount:",
    "normalizedBindMountSource:",
    "showVPNProxyWarningPrompt",
)
TRANSLATIONS = (
    "BindFS Mount Trust",
    "Trust This Mount",
    "Keep Warning",
    "VPN/Proxy Warning",
    "Don't Show VPN/Proxy Warning Again",
)


def verify(path, source):
    raw = path.read_bytes()
    control, payload = build.deb_read(raw)
    fields = {}
    for line in control["control"][1].decode().splitlines():
        if line and not line[0].isspace() and ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    for key, value in (
        ("Package", "com.roothide.manager"),
        ("Version", "1.4.0"),
        ("Architecture", "iphoneos-arm64e"),
    ):
        build.require(fields.get(key) == value, f"Unexpected {key}")
    build.require(
        control["postinst"][1] == (source / "layout/DEBIAN/postinst").read_bytes(),
        "Installer changed",
    )
    build.require(
        not any("DetectionTrustHook" in n or "RCInjectAnalysis" in n for n in payload),
        "Unexpected injected module",
    )
    build.require(
        not any(n.endswith("RootHideConfig.plist") for n in payload),
        "Package must not ship or replace user preferences",
    )
    info = plistlib.loads(payload[f"{APP}/Info.plist"][1])
    for key, value in (
        ("CFBundleIdentifier", "com.roothide.manager"),
        ("CFBundleExecutable", "RootHide"),
        ("CFBundleShortVersionString", "1.4.0"),
        ("MinimumOSVersion", "15.0"),
    ):
        build.require(info.get(key) == value, f"Unexpected bundle {key}")
    binary = payload[f"{APP}/RootHide"][1]
    required_entitlements = plistlib.loads((source / "entitlements.plist").read_bytes())
    required_entitlements.update(
        plistlib.loads((source / "nickchan.entitlements").read_bytes())
    )
    arches = []
    for subtype, _, blob in build.slices(binary):
        for text in REQUIRED_TEXT:
            build.require(text.encode() in blob, f"Missing trust implementation: {text}")
        dependencies = [name for _, name in build.libraries(blob)]
        build.require(
            not any("DetectionTrustHook" in name or "RCInjectAnalysis" in name for name in dependencies),
            "Unexpected injected dependency",
        )
        signing = build.verify_signature(blob)
        parts = build.signature(blob)[1]
        build.require(5 in parts, "Missing XML entitlements")
        entitlements_blob = parts[5][1]
        magic, length = struct.unpack_from(">II", entitlements_blob)
        build.require(magic == 0xFADE7171 and length == len(entitlements_blob), "Invalid entitlements")
        entitlements = plistlib.loads(entitlements_blob[8:])
        for key, value in required_entitlements.items():
            build.require(entitlements.get(key) == value, f"Entitlement changed: {key}")
        arches.append(
            {"subtype": hex(subtype), "signature": signing, "required_entitlements_preserved": True}
        )
    locales = {}
    for language in ("en", "zh_CN"):
        strings = plistlib.loads(payload[f"{APP}/{language}.lproj/Localizable.strings"][1])
        for key in TRANSLATIONS:
            build.require(bool(strings.get(key)), f"Missing {language} translation: {key}")
        locales[language] = {key: strings[key] for key in TRANSLATIONS}
    return {
        "package": fields["Package"],
        "package_version": fields["Version"],
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size": len(raw),
        "bundle_version": info["CFBundleShortVersionString"],
        "minimum_os": info["MinimumOSVersion"],
        "postinst_unchanged": True,
        "no_user_preferences_shipped": True,
        "no_injected_modules": True,
        "architectures": arches,
        "translations": locales,
        "device_tested": False,
        "signing_note": "Code-page and embedded special-slot hashes verified; not proof of device acceptance.",
    }


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
