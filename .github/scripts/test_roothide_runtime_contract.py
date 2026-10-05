#!/usr/bin/env python3
"""Static contract checks for the RootHide-only runtime path.

This test verifies build and dispatch wiring only. It does not emulate iOS,
validate kernel offsets, or prove that a device can complete a jailbreak.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"unexpected {label}: {needle}")


def main() -> None:
    basebin_makefile = read("BaseBin/Makefile")
    roothide_makefile = read("BaseBin/roothidehooks/Makefile")
    systemhook = read("BaseBin/systemhook/src/main.c")
    roothider_main = read("BaseBin/systemhook/src/roothider_main.c")
    launchdhook = read("BaseBin/launchdhook/src/main.m")
    roothide_client = read("BaseBin/libjailbreak/src/jbclient_roothide.c")
    roothide_root = read("BaseBin/libjailbreak/src/jbroot.c")
    roothide_domain = read("BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c")

    # The basebin graph must build the RootHide package, not the independent
    # rootlesshooks package.
    require(basebin_makefile, "roothidehooks", "RootHide basebin target")
    forbid(basebin_makefile, "rootlesshooks", "rootless target in basebin graph")
    require(roothide_makefile, "THEOS_PACKAGE_SCHEME = roothide", "RootHide Theos scheme")

    # systemhook must receive the RootHide check-in and load the RootHide
    # dylib. The test deliberately checks the concrete dispatch strings.
    require(systemhook, "if (!roothide_init_with_checkin(JB_RootPath))", "fail-closed RootHide check-in")
    require(systemhook, 'JBROOT_PATH("/basebin/roothidehooks.dylib")', "systemhook RootHide dylib")
    forbid(systemhook, 'JBROOT_PATH("/basebin/rootlesshooks.dylib")', "systemhook rootless dylib")

    # The fallback path and the process path hook must use the same RootHide
    # runtime root and package.
    require(roothider_main, 'JBROOT_PATH("/usr/lib/roothideinit.dylib")', "RootHide init dylib")
    require(roothider_main, 'JBROOT_PATH("/basebin/roothidehooks.dylib")', "RootHide path hook dylib")
    require(roothider_main, "roothide_runtime_contract_check(", "RootHide startup contract check")
    require(roothider_main, "rootdir[0] != '/'", "absolute RootHide check-in root")
    require(roothider_main, "access(hooksPath, R_OK)", "RootHide path hook presence check")
    require(roothider_main, "access(initPath, R_OK)", "RootHide init dylib presence check")
    require(roothider_main, "runtime init load failed", "RootHide init load error reporting")
    require(roothider_main, "bool roothide_init_with_checkin", "RootHide check-in result propagation")
    require(roothider_main, "return false;", "RootHide startup failure propagation")
    require(roothider_main, "return true;", "RootHide startup success propagation")
    forbid(roothider_main, "ASSERT(roothidehooks != NULL)", "fatal path hook load assertion")
    forbid(roothider_main, "ASSERT(pathhook != NULL)", "fatal path hook symbol assertion")
    require(launchdhook, "roothide_launchd_preinit();", "launchd RootHide preinit")
    require(launchdhook, "roothide_launchd_postinit(firstLoad);", "launchd RootHide postinit")

    # The client/server boundary is the RootHide XPC domain, not a rootless
    # compatibility channel.
    require(roothide_client, "JBS_DOMAIN_ROOTHIDE", "RootHide XPC domain")
    require(roothide_root, "jbinfo(rootPath)", "RootHide runtime root provider")
    require(roothide_domain, "ROOTHIDE_MAX_PREFERRED_ARCHS", "bounded preferred architecture count")
    require(roothide_domain, "xpc_get_type(typeValue) != XPC_TYPE_UINT64", "preferred architecture type validation")
    require(roothide_domain, "type > UINT32_MAX || subtype > UINT32_MAX", "preferred architecture range validation")
    forbid(roothide_domain, "preferredArchTypes[preferredArchCount]", "client-sized preferred architecture VLA")

    print("PASS: RootHide-only build, check-in, launchd and dylib contract")


if __name__ == "__main__":
    main()
