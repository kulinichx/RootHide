# RootHide Manager 1.4.0 Trust Port

Scope: the blacklist manager only. White-list manager work is paused.

The functional source is the user-confirmed `com.roothide.manager_1.3.9+trust2_iphoneos-arm64e.deb` in `参照官方dopamine/黑白名单管理器`. The port uses its blacklist manager implementation recorded by `source/blacklist/provenance.json` (source commit `b15df6a01b027d2e6850912576be9a6899ab151d`), not the ZQBB Inject Manager.

The target is the official `RootHide/RootHideManagerApp` source commit `224589666166a932ec5ff4151748a20d21f0cf7e`. Its Debian control version is `1.4.0`; the existing `source/blacklist/DetectionTrust.patch` passes `git apply --check` against that exact commit.

The patch adds per-mount BindFS trust and a persistent VPN/proxy warning preference. It keeps the existing RootHideConfig.plist store and leaves the upstream blacklist, cleanup rules, application identifier, and version unchanged.

`.github/workflows/manager-blacklist-140.yml` builds this source on macOS with the pinned RootHide Theos revision. The intended output is `RootHide Manager-1.4.0-kulinichx-iphoneos-arm64e.deb`, with package version still `1.4.0`. Device installation and behavior are not claimed until the artifact is built and tested.

The earlier binary-injection candidate used `DetectionTrustHook.dylib` from Inject Manager and is invalid for the blacklist app. `build_kulinichx_3301.py` is disabled to prevent rebuilding it.
