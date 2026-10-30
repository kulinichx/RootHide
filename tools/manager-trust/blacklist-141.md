# RootHide Manager 1.4.1 Trust Port

Scope: the existing blacklist manager trust feature, not Inject Manager.

The source is pinned to official RootHideManagerApp commit
`829f592ecb5b09ef3ac069aad6d55d7319680852`. Apply only
`source/blacklist/1.4.1/DetectionTrust.patch`; it includes the NSError
compatibility fix. Do not apply the old 1.4.0 XcodeNSError.patch.

The new patch retains upstream TrollStore/TrollStore Lite clear-data
protection, application proxy refactoring, scanning UI, and translations.
The trust helpers are identical to the archived 1.3.9 implementation.
Existing RootHideConfig.plist preference keys are retained.

The `manager-blacklist-141.yml` workflow builds on macOS using the same
pinned RootHide Theos revision as the verified 1.4.0 rebuild. It runs:

```text
python3 tools/manager-trust/test_blacklist_141.py /path/to/RootHideManagerApp
python3 tools/manager-trust/verify_blacklist_141.py candidate.deb --source /path/to/RootHideManagerApp
```

The 1.4.0 verifier retains its default version and existing behavior; the
1.4.1 verifier explicitly selects 1.4.1 and adds upstream marker/rules checks.
Source checks verify that only four files differ and all unrelated upstream
logic and translations remain intact.

The candidate package retains upstream Debian version 1.4.1, identity,
minimum iOS version, entitlements, installer, and cleanup rules. It ships no
user preferences and adds no injected module. Embedded signature hashes
are verified, not Apple developer signing or acceptance on a real device.

Device installation, migration of saved preferences, and interaction
acceptance still require testing on the target device. Back up
RootHideConfig.plist and any custom cleanup rules before an in-place
upgrade. Retain the prior working package for rollback.
