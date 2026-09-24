#!/usr/bin/env python3
"""Portable regression tests for the packaging guard; not jailbreak/device tests."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile

script = pathlib.Path(__file__).with_name('check_package_managers.py')
spec = importlib.util.spec_from_file_location('guard', script)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
SILEO = {'Display Name': 'Sileo', 'Key': 'org.coolstar.SileoStore', 'Icon': 'Sileo', 'Package': 'sileo.deb'}
ZEBRA = {'Display Name': 'Zebra', 'Key': 'xyz.willy.Zebra', 'Icon': 'Zebra', 'Package': 'zebra.deb'}


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = pathlib.Path(self.tmp.name) / 'Dopamine.app'
        self.app.mkdir()
        for name in ('sileo.deb', 'roothideapp.deb', 'libroot.deb'):
            (self.app / name).write_bytes(b'fixture only, not an installable DEB')
        (self.app / 'PkgManagers.plist').write_bytes(plistlib.dumps([SILEO]))

    def test_sileo_only_bundle_passes(self):
        guard.check_app(self.app)

    def test_zebra_payload_rejected(self):
        (self.app / 'zebra.deb').write_bytes(b'old resource')
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_case_variant_payload_rejected(self):
        (self.app / 'ZEBRA.DEB').write_bytes(b'old resource')
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_stale_license_rejected(self):
        (self.app / 'LICENSE_Zebra.md').write_text('old resource')
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_zebra_picker_entry_rejected(self):
        (self.app / 'PkgManagers.plist').write_bytes(plistlib.dumps([SILEO, ZEBRA]))
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_missing_sileo_rejected(self):
        (self.app / 'sileo.deb').unlink()
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_missing_roothide_manager_rejected(self):
        (self.app / 'roothideapp.deb').unlink()
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_backups_must_not_ship(self):
        (self.app / 'settings.plist.bak').write_text('backup')
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_active_zebra_asset_directory_rejected(self):
        asset = self.app / 'Zebra.imageset'
        asset.mkdir()
        (asset / 'Contents.json').write_text('{}')
        with self.assertRaises(ValueError):
            guard.check_app(self.app)

    def test_tipa_archive_passes(self):
        tipa = pathlib.Path(self.tmp.name) / 'fixture.tipa'
        with zipfile.ZipFile(tipa, 'w') as archive:
            for p in self.app.iterdir():
                archive.write(p, 'Payload/Dopamine.app/' + p.name)
        guard.check_tipa(tipa)

    def test_old_zebra_only_preferences_do_not_bypass_picker(self):
        # Mirrors the existing available-managers intersection. Does not execute ObjC.
        enabled = {ZEBRA['Key']}
        available = [SILEO]
        selected = [m['Key'] for m in available if m['Key'] in enabled]
        self.assertEqual(selected, [])
        enabled.add(SILEO['Key'])
        selected = [m['Key'] for m in available if m['Key'] in enabled]
        self.assertEqual(selected, [SILEO['Key']])


if __name__ == '__main__':
    unittest.main(verbosity=2)
