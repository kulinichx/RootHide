"""Release source contracts; these do not execute UIKit, Security, or iOS.

Protect the existing upgrade/persistence behavior without changing its policy.
Run with: python -m unittest discover -s tests
"""
import re
import unittest

from test_rc9_services import extract, source


LICENSE = "Application/Dopamine/UI/DOSupporterLicense.h"
THEME = "Application/Dopamine/UI/DOCustomGlassThemeSync.h"
MEDIA = "Application/Dopamine/UI/DOCustomGlassMediaStore.h"


def body(path, name):
    text = source(path)
    # Exclude forward declarations so the verifier resolves to its definition.
    match = re.search(
        r"^static inline [^{;]+\b" + re.escape(name) + r"\([^;]*?\)\s*\{",
        text, re.M,
    )
    if not match:
        raise AssertionError(f"Definition not found: {path}: {name}")
    return extract(text, match.group(0))


class LicenseUpgradeContracts(unittest.TestCase):
    def test_legacy_keys_and_external_state_location_are_preserved(self):
        text = source(LICENSE)
        for value in (
            '@"DORHSupporter.LicenseCode"',
            '@"/var/mobile/Library/Application Support/DopamineRH"',
            '@"supporter-state.plist"', '@"DeviceCode"',
            '@"LicenseCode"', '@"LicenseRemoved"',
        ):
            self.assertIn(value, text)
        writer = body(LICENSE, "DORHSupporterWritePersistentState")
        self.assertIn("if (!directoryReady)", writer)
        self.assertIn("atomically:YES", writer)

    def test_invalid_license_cannot_overwrite_existing_state(self):
        store = body(LICENSE, "DORHSupporterStoreLicenseCode")
        reject = store.index("if (!info)")
        self.assertLess(store.index("DORHSupporterVerifyLicenseCode("), reject)
        self.assertIn("return NO;", store[reject:store.index("NSString *trimmed")])
        self.assertLess(reject, store.index("DORHSupporterReadPersistentState()"))
        self.assertLess(
            store.index("removeObjectForKey:DORHSupporterPersistentLicenseRemovedKey"),
            store.index("DORHSupporterWritePersistentState(state)"),
        )

    def test_tombstone_precedes_stale_defaults_and_self_healing(self):
        current = body(LICENSE, "DORHSupporterCurrentLicenseInfo")
        tombstone = extract(current, "if (DORHSupporterLicenseTombstoned())")
        self.assertIn("DORHSupporterPurgeDefaultsLicense();", tombstone)
        self.assertIn("return nil;", tombstone)
        self.assertLess(
            current.index(tombstone),
            current.index("NSString *persistentLicense"),
        )
        self.assertLess(
            current.index("if (!info)"),
            current.index("DORHSupporterSetPersistentString("),
        )

    def test_migration_keeps_identity_and_verifies_legacy_license(self):
        migration = body(LICENSE, "DORHSupporterDeviceCode")
        self.assertLess(
            migration.index("if (persisted.length != 0)"),
            migration.index("UIDevice.currentDevice.identifierForVendor"),
        )
        legacy = extract(migration, "if (legacyDevice.length != 0")
        self.assertIn("DORHSupporterVerifyLicenseCodeForDevice(", legacy)
        self.assertIn("legacyLicense, legacyDevice, NULL) != nil", legacy)
        self.assertIn("if (!DORHSupporterLicenseTombstoned())", legacy)
        self.assertIn("cachedDeviceCode = legacyDevice;", legacy)

    def test_remove_license_keeps_identity_and_writes_tombstone(self):
        removal = body(LICENSE, "DORHSupporterRemoveLicense")
        self.assertIn(
            "removedState[DORHSupporterPersistentLicenseRemovedKey] = @YES;",
            removal,
        )
        self.assertLess(
            removal.index("removeObjectForKey:DORHSupporterPersistentLicenseCodeKey"),
            removal.index("DORHSupporterWritePersistentState(removedState)"),
        )
        self.assertNotIn(
            "removeObjectForKey:DORHSupporterPersistentDeviceCodeKey", removal,
        )
        self.assertIn("removeObjectForKey:DORHSupporterLicenseDefaultsKey", removal)

    def test_verifier_keeps_signature_product_entitlement_and_device_checks(self):
        verifier = body(LICENSE, "DORHSupporterVerifyLicenseCodeForDevice")
        self.assertLess(
            verifier.index("SecKeyVerifySignature("),
            verifier.index("JSONObjectWithData:payload"),
        )
        self.assertIn("kSecKeyAlgorithmECDSASignatureMessageX962SHA256", verifier)
        self.assertIn('isEqualToString:@"RH1"', verifier)
        self.assertIn('isEqualToString:@"DopamineRH"', verifier)
        self.assertIn('containsObject:@"custom_glass"', verifier)
        self.assertIn("version.integerValue != 1", verifier)
        self.assertIn("if (![device isEqualToString:currentDeviceCode])", verifier)
        self.assertIn('@"License is for another device"', verifier)


class GlassUpgradeContracts(unittest.TestCase):
    def test_theme_bootstrap_runs_before_application_start(self):
        main = source("Application/Dopamine/main.m")
        self.assertLess(
            main.index("DOCustomGlassThemeSyncBootstrap();"),
            main.index("return UIApplicationMain("),
        )

    def test_theme_snapshot_does_not_copy_unrelated_preferences(self):
        snapshot = body(THEME, "DOCustomGlassThemeSyncLocalSnapshot")
        self.assertIn("[key hasPrefix:DOCustomGlassThemeSyncPrefix]", snapshot)
        self.assertIn('@"DOCustomGlassTheme."', source(THEME))
        self.assertNotIn("DORHSupporter", snapshot)
        writer = body(THEME, "DOCustomGlassThemeSyncWrite")
        self.assertIn("payload[DOCustomGlassThemeSyncVersionKey] = @1;", writer)
        self.assertIn("atomically:YES", writer)

    def test_authoritative_theme_keeps_removals_across_jailbreak_states(self):
        bootstrap = body(THEME, "DOCustomGlassThemeSyncBootstrap")
        first_migration = extract(bootstrap, "if (!authoritative)")
        self.assertIn("[merged addEntriesFromDictionary:local];", first_migration)
        self.assertIn("external[DOCustomGlassThemeSyncVersionKey] != nil", bootstrap)
        removal = extract(bootstrap, "if (authoritative)")
        self.assertIn("if (!merged[key])", removal)
        self.assertIn("[defaults removeObjectForKey:key];", removal)

    def test_media_keys_and_bundle_container_resolution_are_preserved(self):
        text = source(MEDIA)
        for key in ("AvatarFilename", "WallpaperFilename", "WallpaperVideoFilename"):
            self.assertIn(f'@"DOCustomGlassTheme.{key}"', text)
        container = body(MEDIA, "DOCustomGlassMediaStoreContainerURL")
        self.assertIn("NSBundle.mainBundle.bundleIdentifier", container)
        self.assertIn("DOCustomGlassMediaStoreLSContainerURL(bundleIdentifier)", container)
        self.assertIn("DOCustomGlassMediaStoreMCMContainerURL(bundleIdentifier)", container)
        self.assertNotIn("NSHomeDirectory(", container)
        self.assertNotIn("NSSearchPathForDirectoriesInDomains(", container)
        filename = body(MEDIA, "DOCustomGlassMediaStoreIsSafeFilename")
        self.assertIn("filename.lastPathComponent", filename)
        self.assertIn('![filename isEqualToString:@".."]', filename)
        self.assertIn(
            "if (!DOCustomGlassMediaStoreIsSafeFilename(filename))",
            body(MEDIA, "DOCustomGlassMediaStoreFileURL"),
        )

    def test_image_is_written_and_decoded_before_replacing_old_media(self):
        image = body(MEDIA, "DOCustomGlassMediaStoreSaveImage")
        operations = (
            "writeToURL:newURL options:NSDataWritingAtomic",
            "dataWithContentsOfURL:newURL",
            "if (!decodedImage)",
            "[defaults setObject:newFilename forKey:defaultsKey]",
            "if (![committedFilename isEqualToString:newFilename])",
            "removeItemAtURL:oldURL",
        )
        positions = [image.index(operation) for operation in operations]
        self.assertEqual(positions, sorted(positions))
        failure = extract(image, "if (!decodedImage)")
        self.assertIn("removeItemAtURL:newURL", failure)
        self.assertNotIn("removeItemAtURL:oldURL", failure)
        self.assertNotIn("if (![defaults synchronize])", image)

    def test_static_wallpaper_only_clears_video_after_successful_save(self):
        wallpaper = body(MEDIA, "DOCustomGlassMediaStoreSaveWallpaper")
        self.assertLess(
            wallpaper.index("DOCustomGlassMediaStoreSaveImage("),
            wallpaper.index("if (saved)"),
        )
        self.assertRegex(
            wallpaper,
            r"if \(saved\)\s+DOCustomGlassMediaStoreClearWallpaperVideo\(\);",
        )

    def test_video_requires_local_nonempty_file_and_saved_poster(self):
        video = body(MEDIA, "DOCustomGlassMediaStoreSaveWallpaperVideo")
        self.assertIn("if (!sourceURL.isFileURL || !posterImage)", video)
        operations = (
            "copyItemAtURL:sourceURL", "if (fileSize == 0)",
            "DOCustomGlassMediaStoreSaveImage(posterImage", "if (!posterSaved)",
            "[defaults setObject:newVideoFilename",
        )
        positions = [video.index(operation) for operation in operations]
        self.assertEqual(positions, sorted(positions))
        failure = extract(video, "if (!posterSaved)")
        self.assertIn("removeItemAtURL:newVideoURL", failure)
        self.assertNotIn("removeItemAtURL:oldVideoURL", failure)


if __name__ == "__main__":
    unittest.main()
