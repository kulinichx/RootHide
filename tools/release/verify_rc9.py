"""Read-only RC9 package identity checks; no extraction or device installation."""
import argparse
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
MAX_MEMBER_BYTES = 128 * 1024 * 1024
COMPONENTS = (
    "systemhook.dylib", "launchdhook.dylib", "roothidehooks.dylib",
    "libjailbreak.dylib", "jailbreakd",
)
BUILD_PATHS = (
    "Application", "BaseBin", "Makefile", ".gitmodules",
    ".github/patches", ".github/workflows/roothide.yml",
)
SOURCE_FINGERPRINTS = (
    "Application/Dopamine/UI/DOSupporterLicense.h",
    "Application/Dopamine/UI/DOCustomGlassThemeSync.h",
    "Application/Dopamine/UI/DOCustomGlassMediaStore.h",
    "Application/Dopamine/main.m",
    ".github/workflows/roothide.yml",
    "tests/test_rc9_release_contracts.py",
    "tests/test_rc9_release_package.py",
    "tools/release/verify_rc9.py",
)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_unique(names):
    duplicates = [name for name, count in Counter(names).items() if count > 1]
    if duplicates:
        raise ValueError("Duplicate archive members: " + ", ".join(duplicates[:5]))


def checked_size(size, name):
    if not 0 <= size <= MAX_MEMBER_BYTES:
        raise ValueError(f"Archive member too large: {name}")


def tar_bytes(archive, name):
    member = archive.getmember(name)
    if not member.isfile():
        raise ValueError(f"Expected regular file: {name}")
    checked_size(member.size, name)
    with archive.extractfile(member) as stream:
        return stream.read()


def inspect_artifact(path, *, expected_build_id, expected_version,
                     expected_bundle_id, expected_minimum_os, expected_sha256=None):
    if not re.fullmatch(r"[0-9a-f]{40}", expected_build_id):
        raise ValueError("Expected build ID must be a full 40-character Git SHA")
    if expected_sha256 and not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise ValueError("Expected package hash must be a full SHA-256")
    package_hash = sha256_file(path)
    errors = []

    def expect(label, actual, expected):
        if actual != expected:
            errors.append(f"{label}: expected {expected!r}, observed {actual!r}")

    if expected_sha256:
        expect("package SHA-256", package_hash, expected_sha256)
    with zipfile.ZipFile(path) as package:
        names = package.namelist()
        require_unique(names)
        info_paths = [
            name for name in names
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
        ]
        if len(info_paths) != 1:
            raise ValueError("Expected exactly one top-level application Info.plist")
        prefix = info_paths[0].removesuffix("Info.plist")

        def zip_bytes(name):
            member = package.getinfo(name)
            checked_size(member.file_size, name)
            return package.read(member)

        info = plistlib.loads(zip_bytes(info_paths[0]))
        if not isinstance(info, dict):
            raise ValueError("Application Info.plist must contain a dictionary")
        executable = info.get("CFBundleExecutable")
        if (not isinstance(executable, str) or not executable or executable in (".", "..")
                or "/" in executable or "\\" in executable):
            raise ValueError("Invalid application executable name")
        app = {
            key: info.get(key) for key in (
                "CFBundleIdentifier", "CFBundleShortVersionString",
                "CFBundleExecutable", "MinimumOSVersion",
            )
        }
        app["executable_sha256"] = hashlib.sha256(zip_bytes(prefix + executable)).hexdigest()
        expect("Bundle ID", info.get("CFBundleIdentifier"), expected_bundle_id)
        expect("app version", info.get("CFBundleShortVersionString"), expected_version)
        expect("minimum iOS", info.get("MinimumOSVersion"), expected_minimum_os)

        with tarfile.open(fileobj=io.BytesIO(zip_bytes(prefix + "basebin.tar")), mode="r:") as archive:
            require_unique(member.name for member in archive.getmembers())
            fields = {}
            for line in tar_bytes(archive, "basebin/.build-info").decode("utf-8").splitlines():
                if not line.strip():
                    continue
                key, separator, value = line.partition("=")
                if not separator or key in fields:
                    raise ValueError("Malformed or duplicate basebin build-info field")
                fields[key] = value
            version = tar_bytes(archive, "basebin/.version").decode("utf-8").strip()
            expect("basebin version", version, expected_version)
            expect("build-info version", fields.get("ProductVersion"), expected_version)
            expect("BaseBinBuildID", fields.get("BaseBinBuildID"), expected_build_id)
            components = {
                name: hashlib.sha256(tar_bytes(archive, "basebin/" + name)).hexdigest()
                for name in COMPONENTS
            }
        bundled_packages = {
            name.removeprefix(prefix): hashlib.sha256(zip_bytes(name)).hexdigest()
            for name in sorted(names)
            if name.startswith(prefix) and "/" not in name[len(prefix):] and name.endswith(".deb")
        }

    return {
        "schema_version": 1,
        "artifact_checks_passed": not errors,
        "release_approval": "not_assessed",
        "limitations": [
            "Identity and file hashes only; not Apple signature or executable-load verification.",
            "No native build, device upgrade, license operation or UIKit behavior was executed.",
            "The independently installed zqbb manager version must be recorded on the device.",
        ],
        "artifact": {"path": str(path), "sha256": package_hash, "size": path.stat().st_size},
        "expected": {
            "build_id": expected_build_id, "version": expected_version,
            "bundle_id": expected_bundle_id, "minimum_os": expected_minimum_os,
            "sha256": expected_sha256,
        },
        "app": app,
        "basebin": {"build_info": fields, "version": version, "component_sha256": components},
        "bundled_package_sha256": bundled_packages,
        "errors": errors,
    }


def source_snapshot(build_id):
    def git(*args):
        result = subprocess.run(
            ["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if result.returncode:
            raise ValueError(result.stderr.strip())
        return result.stdout.rstrip("\r\n")

    snapshot = {
        "scope": "Tracked app/runtime and listed build inputs; not a reproducible-build proof.",
        "current_source_sha256": {
            name: sha256_file(ROOT / name) for name in SOURCE_FINGERPRINTS
        },
    }
    try:
        snapshot["head"] = git("rev-parse", "HEAD")
        snapshot["worktree_status"] = git("status", "--short", "--untracked-files=normal").splitlines()
        snapshot["tracked_build_input_changes_since_artifact"] = git(
            "diff", "--name-only", build_id, "--", *BUILD_PATHS,
        ).splitlines()
        snapshot["tracked_app_runtime_changes_since_artifact"] = git(
            "diff", "--name-only", build_id, "--", "Application", "BaseBin",
        ).splitlines()
    except (OSError, ValueError) as error:
        snapshot["error"] = str(error)
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--expected-build-id", required=True)
    parser.add_argument(
        "--expected-version",
        default=(ROOT / "BaseBin/_external/basebin/.version").read_text().strip(),
    )
    parser.add_argument("--expected-bundle-id", default="com.opa334.Dopamine-roothide")
    parser.add_argument("--expected-minimum-os", default="16.0")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output and (args.output.suffix != ".json" or args.output.resolve() == args.artifact.resolve()):
        parser.error("Report output must be a separate .json file")
    try:
        report = inspect_artifact(
            args.artifact, expected_build_id=args.expected_build_id,
            expected_version=args.expected_version, expected_bundle_id=args.expected_bundle_id,
            expected_minimum_os=args.expected_minimum_os, expected_sha256=args.expected_sha256,
        )
    except (OSError, ValueError, KeyError, EOFError, tarfile.TarError,
            zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}")
        return 1
    report["source_snapshot"] = source_snapshot(args.expected_build_id)
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if report["artifact_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
