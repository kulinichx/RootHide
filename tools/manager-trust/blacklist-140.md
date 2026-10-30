# RootHide Manager 1.4.0 Trust Port

Scope: the blacklist manager only. White-list manager work is paused.

The user-confirmed functional reference is `cn.zqbb.inject.manager_3.2.1-5+trust2_iphoneos-arm64e.deb` (SHA-256 `a4a49541a8e2261be12ab4422820db5404039c3c17c8a37eb2f55a931a810572`). It is used as behavior reference only; its executable and Inject Manager hook are not copied into RootHide Manager.

The target is the official `RootHide/RootHideManagerApp` source commit `224589666166a932ec5ff4151748a20d21f0cf7e`. Its Debian control version is `1.4.0`; the existing `source/blacklist/DetectionTrust.patch` passes `git apply --check` against that exact commit.

The patch adds per-mount BindFS trust and a persistent VPN/proxy warning preference. It keeps the existing RootHideConfig.plist store and leaves the upstream blacklist, cleanup rules, application identifier, and version unchanged.

`.github/workflows/manager-blacklist-140.yml` builds this source on macOS with the pinned RootHide Theos revision. The intended output is `RootHide Manager-1.4.0-kulinichx-iphoneos-arm64e.deb`, with package version still `1.4.0`. Device installation and behavior are not claimed until the artifact is built and tested.

The earlier binary-injection candidate used `DetectionTrustHook.dylib` from Inject Manager and is invalid for the blacklist app. `build_kulinichx_3301.py` is disabled to prevent rebuilding it.
