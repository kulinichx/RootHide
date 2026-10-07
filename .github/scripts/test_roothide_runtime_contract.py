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
    systemhook_common = read("BaseBin/systemhook/src/common/common.c")
    roothider_main = read("BaseBin/systemhook/src/roothider_main.c")
    launchdhook = read("BaseBin/launchdhook/src/main.m")
    roothide_client = read("BaseBin/libjailbreak/src/jbclient_roothide.c")
    dopamine_client = read("BaseBin/libjailbreak/src/jbclient_xpc.c")
    dopamine_client_header = read("BaseBin/libjailbreak/src/jbclient_xpc.h")
    dopamine_domains = read("BaseBin/libjailbreak/src/jbserver_domains.h")
    dopamine_domain = read("BaseBin/launchdhook/src/jbserver/jbdomain_dopamine.c")
    roothide_root = read("BaseBin/libjailbreak/src/jbroot.c")
    roothide_domain = read("BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c")
    roothide_signatures = read("BaseBin/libjailbreak/src/roothider/signatures.m")
    jbserver = read("BaseBin/libjailbreak/src/jbserver.c")
    jbserver_global = read("BaseBin/launchdhook/src/jbserver/jbserver_global.c")
    jbserver_boomerang = read("BaseBin/libjailbreak/src/jbserver_boomerang.c")
    systemwide_domain = read("BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c")
    root_domain = read("BaseBin/launchdhook/src/jbserver/jbdomain_root.c")
    xpc_hook = read("BaseBin/libjailbreak/src/roothider/xpc_hook.m")
    cfprefsd_hook = read("BaseBin/roothidehooks/cfprefsd.x")
    envbuf = read("BaseBin/systemhook/src/common/envbuf.c")
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
    require(roothider_main, 'JBROOT_PATH("/basebin/roothidehooks.dylib")', "RootHide path hook dylib")
    require(roothider_main, "roothide_runtime_contract_check(", "RootHide startup contract check")
    require(roothider_main, "rootdir[0] != '/'", "absolute RootHide check-in root")
    require(roothider_main, "char normalizedRoot[PATH_MAX]", "normalized RootHide runtime root")
    require(roothider_main, 'snprintf(hooksPath, hooksPathSize, "%s/basebin/roothidehooks.dylib", normalizedRoot)', "exact RootHide path hook construction")
    require(roothider_main, 'snprintf(initPath, initPathSize, "%s/usr/lib/roothideinit.dylib", normalizedRoot)', "exact RootHide init path construction")
    forbid(roothider_main, "access(hooksPath, R_OK)", "TOCTOU path hook preflight")
    forbid(roothider_main, "access(initPath, R_OK)", "TOCTOU init dylib preflight")
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
    require(dopamine_domains, "#define JBS_DOMAIN_DOPAMINE 5", "Dopamine XPC domain")
    require(dopamine_domains, "JBS_DOPAMINE_GET_ROOT", "Dopamine root action")
    require(dopamine_domains, "JBS_DOPAMINE_DROP_ROOT", "Dopamine root release action")
    require(dopamine_client_header, "jbclient_dopamine_get_root", "Dopamine root client declaration")
    require(dopamine_client_header, "jbclient_dopamine_drop_root", "Dopamine root release declaration")
    require(dopamine_client, "jbclient_dopamine_get_root", "Dopamine root client implementation")
    require(dopamine_client, "jbclient_dopamine_drop_root", "Dopamine root release implementation")
    require(dopamine_domain, "dopamine_domain_allowed", "Dopamine domain caller guard")
    require(dopamine_domain, "kwrite32(ucred + koffsetof(ucred, uid), 0)", "Dopamine root credential transition")
    require(dopamine_domain, "kwrite32(ucred + koffsetof(ucred, uid), 501)", "Dopamine credential restoration")
    require(roothide_root, "jbinfo(rootPath)", "RootHide runtime root provider")
    require(roothide_domain, "ROOTHIDE_MAX_PREFERRED_ARCHS", "bounded preferred architecture count")
    require(roothide_domain, "xpc_get_type(typeValue) != XPC_TYPE_UINT64", "preferred architecture type validation")
    require(roothide_domain, "type > UINT32_MAX || subtype > UINT32_MAX", "preferred architecture range validation")
    forbid(roothide_domain, "preferredArchTypes[preferredArchCount]", "client-sized preferred architecture VLA")
    require(roothide_domain, "roothide_privileged_action_allowed", "RootHide privileged action guard")
    require(roothide_domain, 'roothide_privileged_action_allowed(callerToken, "jailbreakd lookup")', "jailbreakd lookup caller validation")
    require(roothide_domain, 'JBROOT_PATH("/basebin/jailbreakd")', "exact jailbreakd checkin path")
    require(roothide_domain, "realpath(processPath, normalizedProcessPath)", "normalized jailbreakd caller path")
    require(roothide_domain, "realpath(expectedPath, normalizedExpectedPath)", "normalized jailbreakd expected path")
    require(roothide_domain, "strcmp(normalizedProcessPath, normalizedExpectedPath) != 0", "normalized jailbreakd checkin path binding")
    forbid(roothide_domain, "strcmp(processPath, expectedPath)", "raw jailbreakd checkin path comparison")
    require(roothide_domain, 'roothide_privileged_action_allowed(callerToken, "trust executable")', "executable trust caller validation")
    require(roothide_domain, 'roothide_privileged_action_allowed(callerToken, "trust library")', "library trust caller validation")
    require(roothide_domain, "pid_t callerPid = audit_token_to_pid(*callerToken);", "library trust audit-token PID binding")
    require(roothide_domain, "const char *callerExecutablePath = proc_get_path(callerPid, NULL);", "library trust executable path derivation")
    require(roothide_domain, "strnlen(path, PATH_MAX)", "bounded trust path validation")
    require(roothide_domain, "!roothide_path_argument_valid(callerLibraryPath, false, true)", "absolute caller image validation")
    require(roothide_domain, "!roothide_path_argument_valid(currentWorkingDir, false, true)", "absolute trust working directory validation")
    forbid(roothide_domain, '{ .name = "caller-executable-path", .type = JBS_TYPE_STRING, .out = false }', "client-claimed library caller executable path")
    forbid(roothide_client, 'xpc_dictionary_set_string(xargs, "caller-executable-path", executablePath);', "client-claimed caller executable path")
    require(jbserver, "jbserver_xpc_value_matches_type", "jbserver XPC argument type validation")
    require(jbserver, "xpc_get_type(domainValue) != XPC_TYPE_UINT64", "jbserver domain type validation")
    require(jbserver, "xpc_get_type(actionValue) != XPC_TYPE_UINT64", "jbserver action type validation")
    require(jbserver, "if (!xreply)", "jbserver reply creation validation")
    require(jbserver, "!server || !server->domains || !xmsg", "null server and message rejection")
    require(jbserver, "domainIdx > server->maxDomain", "domain index upper bound")
    require(jbserver, "server->domains[domainIdx - 1]", "bounded direct domain lookup")
    require(jbserver_global, "sizeof(gGlobalDomains) / sizeof(gGlobalDomains[0])", "global domain count derivation")
    require(jbserver_boomerang, "sizeof(gBoomerangDomains) / sizeof(gBoomerangDomains[0])", "boomerang domain count derivation")
    forbid(jbserver_global, ".maxDomain = 1", "stale global domain upper bound")
    forbid(jbserver_boomerang, ".maxDomain = 1", "stale boomerang domain upper bound")
    require(systemwide_domain, '{ .name = "siginfo-length", .type = JBS_TYPE_UINT64, .out = false }', "DATA argument length slot")
    require(root_domain, '{ .name = "cdhash-length", .type = JBS_TYPE_UINT64, .out = false }', "cdhash DATA length slot")
    require(jbserver_boomerang, "if (!xreply) return -4;", "boomerang reply allocation validation")
    require(xpc_hook, "if (!reply) return -1;", "null hooked XPC reply validation")
    require(xpc_hook, "if (!xmsg || xpc_get_type(xmsg) != XPC_TYPE_DICTIONARY) return;", "hooked XPC message validation")
    require(xpc_hook, "failed to allocate bundle identifier", "bundle allocation failure handling")
    require(jbserver, "for (uint64_t i = 1; i < actionIdx && action->handler; i++)", "bounded-width action traversal")
    require(jbserver, "i < 8 && action->args[i].name", "argument descriptor bounds-before-dereference")
    forbid(jbserver, "action->args[i].name && i < 8", "argument descriptor out-of-bounds condition order")
    require(cfprefsd_hook, "pid_t previousClientPid = gCurrentClientPid;", "cfprefsd nested client PID preservation")
    require(cfprefsd_hook, "gCurrentClientPid = previousClientPid;", "cfprefsd client PID restoration")
    require(cfprefsd_hook, "CFPREFS_PATH_BUFFER_SIZE", "cfprefsd explicit path buffer capacity")
    require(cfprefsd_hook, "strnlen((char *)buffer, CFPREFS_PATH_BUFFER_SIZE)", "cfprefsd bounded source path scan")
    require(cfprefsd_hook, "strlcpy((char*)buffer, newpath, CFPREFS_PATH_BUFFER_SIZE)", "cfprefsd bounded redirected path copy")
    forbid(cfprefsd_hook, "strcpy((char*)buffer, newpath)", "cfprefsd unbounded redirected path copy")
    require(envbuf, "ENVBUF_MAX_ENTRIES", "bounded environment entry count")
    require(envbuf, "return calloc(1, sizeof(char *));", "empty mutable environment allocation")
    require(envbuf, "if (!envcopy)", "environment copy allocation failure handling")
    require(envbuf, "for (int j = 0; j < i; j++) free(envcopy[j]);", "partial environment copy cleanup")
    require(envbuf, "k < ENVBUF_MAX_ENTRIES && envp[k] != NULL", "bounded environment search")
    require(envbuf, "valueLength > SIZE_MAX - 2 || nameLength > SIZE_MAX - valueLength - 2", "environment string size overflow check")
    require(envbuf, "prevLen < 1 || prevLen >= ENVBUF_MAX_ENTRIES", "environment growth bound")
    require(roothide_signatures, "ROOTHIDE_MAX_RECURSIVE_CDHASHES", "recursive cdhash collection bound")
    require(roothide_signatures, "if(!path || !cdhashesOut || !cdhashCountOut) return -1;", "recursive cdhash output validation")
    require(systemhook_common, "if (!envc) return orig(envp);", "environment copy failure fallback")
    require(roothider_main, "if (!envc)", "RootHide environment copy failure handling")
    require(workflow, "make -C BaseBin roothidehooks", "focused roothidehooks build coverage")
    require(workflow, "python3 .github/scripts/test_envbuf_runtime.py", "envbuf executable negative test coverage")
    require(workflow, "python3 .github/scripts/test_pathhook_runtime.py", "path hook executable retry coverage")
    require(workflow, "python3 .github/scripts/test_jbserver_runtime.py", "jbserver malformed XPC executable coverage")
    require(workflow, "artifacts/roothidehooks.dylib", "focused roothidehooks artifact coverage")

    print("PASS: RootHide-only build, check-in, launchd and dylib contract")


if __name__ == "__main__":
    main()
