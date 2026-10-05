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
    jbserver = read("BaseBin/libjailbreak/src/jbserver.c")
    cfprefsd_hook = read("BaseBin/roothidehooks/cfprefsd.x")
    workflow = read(".github/workflows/roothide.yml")

    # The basebin graph must build the RootHide package, not the independent
    # rootlesshooks package.
    require(basebin_makefile, "roothidehooks", "RootHide basebin target")
    forbid(basebin_makefile, "rootlesshooks", "rootless target in basebin graph")
    require(roothide_makefile, "THEOS_PACKAGE_SCHEME = roothide", "RootHide Theos scheme")

    # systemhook must receive the RootHide check-in and load the RootHide
    # dylib. The test deliberately checks the concrete dispatch strings.
    require(systemhook, "if (!roothide_init_with_checkin(JB_RootPath))", "fail-closed RootHide check-in")
    require(systemhook, "load_required_runtime_dylib", "required runtime dylib loader")
    require(systemhook, 'load_required_runtime_dylib("forkfix"', "forkfix load result propagation")
    require(systemhook, 'load_required_runtime_dylib("process hooks"', "process hook load result propagation")
    require(systemhook, 'load_required_runtime_dylib("watchdog hook"', "watchdog hook load result propagation")
    require(systemhook, "if (!roothide_init_with_executable(gExecutablePath))", "process patch load result propagation")
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
    require(roothider_main, "bool roothide_init_with_executable", "process-specific init result propagation")
    require(roothider_main, "process patch load failed", "process patch load error reporting")
    forbid(roothider_main, 'dlopen(JBROOT_PATH("/usr/lib/roothidepatch.dylib")', "ignored process patch load result")
    forbid(roothider_main, "ASSERT(roothidehooks != NULL)", "fatal path hook load assertion")
    forbid(roothider_main, "ASSERT(pathhook != NULL)", "fatal path hook symbol assertion")
    require(roothider_main, "pthread_mutex_t pathHookLock", "retryable path hook synchronization")
    require(roothider_main, "bool pathHookLoaded = false", "path hook successful-load state")
    require(roothider_main, "pathHookLoaded = true;", "path hook success commit")
    require(roothider_main, "dlclose(roothidehooks);", "failed path hook handle cleanup")
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
    require(roothide_domain, "roothide_privileged_action_allowed", "RootHide privileged action guard")
    require(roothide_domain, 'roothide_privileged_action_allowed(callerToken, "jailbreakd lookup")', "jailbreakd lookup caller validation")
    require(roothide_domain, 'roothide_privileged_action_allowed(callerToken, "trust executable")', "executable trust caller validation")
    require(roothide_domain, 'roothide_privileged_action_allowed(callerToken, "trust library")', "library trust caller validation")
    require(jbserver, "jbserver_xpc_value_matches_type", "jbserver XPC argument type validation")
    require(jbserver, "xpc_get_type(domainValue) != XPC_TYPE_UINT64", "jbserver domain type validation")
    require(jbserver, "xpc_get_type(actionValue) != XPC_TYPE_UINT64", "jbserver action type validation")
    require(jbserver, "if (!xreply)", "jbserver reply creation validation")
    require(cfprefsd_hook, "pid_t previousClientPid = gCurrentClientPid;", "cfprefsd nested client PID preservation")
    require(cfprefsd_hook, "gCurrentClientPid = previousClientPid;", "cfprefsd client PID restoration")
    require(cfprefsd_hook, "CFPREFS_PATH_BUFFER_SIZE", "cfprefsd explicit path buffer capacity")
    require(cfprefsd_hook, "strnlen((char *)buffer, CFPREFS_PATH_BUFFER_SIZE)", "cfprefsd bounded source path scan")
    require(cfprefsd_hook, "strlcpy((char*)buffer, newpath, CFPREFS_PATH_BUFFER_SIZE)", "cfprefsd bounded redirected path copy")
    forbid(cfprefsd_hook, "strcpy((char*)buffer, newpath)", "cfprefsd unbounded redirected path copy")
    require(workflow, "make -C BaseBin roothidehooks", "focused roothidehooks build coverage")
    require(workflow, "artifacts/roothidehooks.dylib", "focused roothidehooks artifact coverage")

    print("PASS: RootHide-only build, check-in, launchd and dylib contract")


if __name__ == "__main__":
    main()
