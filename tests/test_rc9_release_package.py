"""Package checker tests use synthetic archives, never installable release data."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "rc9_release_verify", ROOT / "tools/release/verify_rc9.py",
)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)

BUILD_ID = "a" * 40
EXPECTED = {
    "expected_build_id": BUILD_ID,
    "expected_version": "3.0.7",
    "expected_bundle_id": "com.opa334.Dopamine-roothide",
    "expected_minimum_os": "16.0",
}


class ReleasePackageChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "candidate.tipa"

    def package(self, *, info_changes=None, build_info=None, base_version="3.0.7",
                missing=None, duplicate_tar=False, duplicate_zip=False):
        info = {
            "CFBundleIdentifier": EXPECTED["expected_bundle_id"],
            "CFBundleShortVersionString": "3.0.7",
            "CFBundleExecutable": "Dopamine",
            "MinimumOSVersion": "16.0",
        }
        info.update(info_changes or {})
        if build_info is None:
            build_info = f"ProductVersion=3.0.7\nBaseBinBuildID={BUILD_ID}\n"
        files = {
            "basebin/.build-info": build_info.encode(),
            "basebin/.version": (base_version + "\n").encode(),
            **{f"basebin/{name}": b"synthetic identity fixture" for name in verify.COMPONENTS},
        }
        files.pop(missing, None)
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            if duplicate_tar:
                data = files["basebin/.build-info"]
                member = tarfile.TarInfo("basebin/.build-info")
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        with zipfile.ZipFile(self.path, "w") as archive:
            archive.writestr("Payload/Dopamine.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/Dopamine.app/Dopamine", b"synthetic app")
            archive.writestr("Payload/Dopamine.app/basebin.tar", stream.getvalue())
            archive.writestr("Payload/Dopamine.app/roothideapp.deb", b"synthetic resource")
            if duplicate_zip:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr("Payload/Dopamine.app/Info.plist", plistlib.dumps(info))

    def test_matching_package_passes_without_claiming_device_or_signature_validation(self):
        self.package()
        report = verify.inspect_artifact(self.path, **EXPECTED)
        self.assertTrue(report["artifact_checks_passed"])
        self.assertEqual(report["release_approval"], "not_assessed")
        self.assertEqual(report["artifact"]["sha256"], hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.assertEqual(len(report["basebin"]["component_sha256"]), 5)
        self.assertIn("roothideapp.deb", report["bundled_package_sha256"])

    def test_filename_does_not_define_package_identity(self):
        self.package()
        renamed = self.path.with_name("RC7-or-RC9-display-name.tipa")
        self.path.rename(renamed)
        self.assertTrue(verify.inspect_artifact(renamed, **EXPECTED)["artifact_checks_passed"])

    def test_mismatched_app_fields_are_reported(self):
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "MinimumOSVersion"):
            with self.subTest(key=key):
                self.package(info_changes={key: "wrong"})
                report = verify.inspect_artifact(self.path, **EXPECTED)
                self.assertFalse(report["artifact_checks_passed"])
                self.assertTrue(report["errors"])

    def test_mismatched_basebin_identity_is_reported(self):
        for text in (
            f"ProductVersion=3.0.7\nBaseBinBuildID={'b' * 40}\n",
            f"ProductVersion=0.0\nBaseBinBuildID={BUILD_ID}\n",
        ):
            with self.subTest(build_info=text):
                self.package(build_info=text)
                self.assertFalse(verify.inspect_artifact(self.path, **EXPECTED)["artifact_checks_passed"])

    def test_wrong_hash_and_basebin_version_are_reported(self):
        self.package(base_version="0.0")
        report = verify.inspect_artifact(self.path, **EXPECTED, expected_sha256="0" * 64)
        self.assertFalse(report["artifact_checks_passed"])
        self.assertEqual(len(report["errors"]), 2)

    def test_missing_component_is_rejected(self):
        self.package(missing="basebin/systemhook.dylib")
        with self.assertRaises(KeyError):
            verify.inspect_artifact(self.path, **EXPECTED)

    def test_duplicate_archive_members_are_rejected(self):
        for options in ({"duplicate_zip": True}, {"duplicate_tar": True}):
            with self.subTest(options=options):
                self.package(**options)
                with self.assertRaisesRegex(ValueError, "Duplicate archive members"):
                    verify.inspect_artifact(self.path, **EXPECTED)

    def test_duplicate_build_info_field_is_rejected(self):
        self.package(build_info=f"ProductVersion=3.0.7\nBaseBinBuildID={BUILD_ID}\nBaseBinBuildID={BUILD_ID}\n")
        with self.assertRaisesRegex(ValueError, "duplicate basebin build-info"):
            verify.inspect_artifact(self.path, **EXPECTED)

    def test_unpinned_build_id_is_rejected(self):
        self.package()
        with self.assertRaisesRegex(ValueError, "full 40-character"):
            verify.inspect_artifact(self.path, **{**EXPECTED, "expected_build_id": "main"})

    def test_executable_path_escape_is_rejected(self):
        self.package(info_changes={"CFBundleExecutable": "../Dopamine"})
        with self.assertRaisesRegex(ValueError, "Invalid application executable"):
            verify.inspect_artifact(self.path, **EXPECTED)

    def test_cli_mismatch_fails_and_keeps_package_unchanged(self):
        self.package()
        original_hash = verify.sha256_file(self.path)
        output = self.path.with_suffix(".json")
        result = subprocess.run(
            [
                sys.executable, str(ROOT / "tools/release/verify_rc9.py"), str(self.path),
                "--expected-build-id", BUILD_ID, "--expected-sha256", "0" * 64,
                "--output", str(output),
            ],
            capture_output=True,
        )
        self.assertEqual(result.returncode, 1, result.stderr.decode(errors="replace"))
        report = json.loads(output.read_text(encoding="utf-8"))
        self.assertFalse(report["artifact_checks_passed"])
        self.assertEqual(report["release_approval"], "not_assessed")
        self.assertIn("package SHA-256", report["errors"][0])
        self.assertEqual(verify.sha256_file(self.path), original_hash)


if __name__ == "__main__":
    unittest.main()
