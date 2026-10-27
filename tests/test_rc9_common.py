"""Shared spawn regression: real C bodies, real envbuf, mocked OS/XPC edges.

Run with Python 3. --native requires clang and the Blocks runtime (macOS CI).
This does not replace iPhoneOS builds or iOS device validation.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_runtime_policy import ROOT, source, function

COMMON = "BaseBin/systemhook/src/common/common.c"
ROOTHIDER = "BaseBin/systemhook/src/roothider_common.c"


class SharedContracts(unittest.TestCase):
    def test_one_implementation_is_built_by_both_targets(self):
        self.assertFalse((ROOT / "BaseBin/systemhook/src/common.c").exists())
        launchd = source("BaseBin/launchdhook/Makefile")
        self.assertIn("../systemhook/src/common/common.c", launchd)
        self.assertIn("-DRC9_LAUNCHD=1", launchd)
        self.assertNotIn("systemhook_memory.c", launchd)
        self.assertIn("src/common/*.c", source("BaseBin/systemhook/Makefile"))
        self.assertIn('#include "common/common.h"', source("BaseBin/systemhook/src/common.h"))
        self.assertNotIn("hookd_vm_protect(", source(COMMON))

    def test_launchd_keeps_its_local_blacklist_boundary(self):
        body = function(COMMON, "spawn_config_for_executable")
        guarded = body.split("#ifndef RC9_LAUNCHD", 1)[1].split("#endif", 1)[0]
        self.assertIn("jbclient_blacklist_check_path(policyPath)", guarded)
        self.assertNotIn("jbclient_blacklist_check_path", body.replace(guarded, ""))
        prehook = function("BaseBin/launchdhook/src/roothider.m", "roothide_launchd___posix_spawn_prehook")
        self.assertIn("bool roothideBlacklisted = isBlacklistedPath(path);", prehook)
        self.assertIn("if (choicyBlocked || roothideBlacklisted)", prehook)
        self.assertLess(prehook.index("isBlacklistedPath(path)"), prehook.rindex("return __posix_spawn_hook"))

    def test_safe_mode_keeps_separate_tweak_gate(self):
        self.assertIn("allowInjectWithSafeMode(path)", function(COMMON, "spawn_exec_hook_common"))
        body = function("BaseBin/systemhook/src/main.c", "should_enable_tweaks")
        for name in ("_SafeMode", "_MSSafeMode"):
            self.assertIn('getenv("' + name + '")', body)
        self.assertIn("roothide_isTweakInjectionEnabled()", body)

    def test_null_attributes_and_shared_policy(self):
        self.assertIn("attr && posix_spawnattr_getprocesstype_np", function(COMMON, "spawn_exec_hook_common"))
        self.assertIn("attr && posix_spawnattr_getflags", function(COMMON, "posix_spawn_hook_shared"))
        body = function(COMMON, "spawn_config_for_executable")
        self.assertLess(body.index('jbuserconfig_get_value("ProcessBlacklist")'), body.index("zqbb_wantInject"))


PREFIX = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <sys/types.h>
#include <unistd.h>

/* Failure injection applies to the actual envbuf and spawn implementation. */
static int allocation_count, fail_at = -1;
static bool fail_allocation(void) { return allocation_count++ == fail_at; }
static void *test_malloc(size_t n) { return fail_allocation() ? NULL : malloc(n); }
static void *test_calloc(size_t n, size_t s) { return fail_allocation() ? NULL : calloc(n, s); }
static void *test_realloc(void *p, size_t n) { return fail_allocation() ? NULL : realloc(p, n); }
static char *test_strdup(const char *s) { return fail_allocation() ? NULL : strdup(s); }
#define malloc test_malloc
#define calloc test_calloc
#define realloc test_realloc
#define strdup test_strdup

enum { kSpawnConfigInject=1, kSpawnConfigTrust=2,
       POSIX_SPAWN_PROC_TYPE_DRIVER=0x700, POSIX_SPAWN_START_SUSPENDED=0x80 };
typedef int kSpawnConfig;
typedef struct { int proctype, active, inactive; short flags; } TestAttr;
typedef void *posix_spawnattr_t;
struct _posix_spawn_args_desc { posix_spawnattr_t attrp; };
#define POSIX_SPAWNATTR_OFF_MEMLIMIT_ACTIVE offsetof(TestAttr, active)
#define POSIX_SPAWNATTR_OFF_MEMLIMIT_INACTIVE offsetof(TestAttr, inactive)
static int type_queries, flag_queries;
static int posix_spawnattr_getprocesstype_np(posix_spawnattr_t *a, int *p) {
    assert(a && *a); ++type_queries; *p=((TestAttr *)*a)->proctype; return 0;
}
static int posix_spawnattr_getflags(posix_spawnattr_t *a, short *f) {
    assert(a && *a); ++flag_queries; *f=((TestAttr *)*a)->flags; return 0;
}
#define APP_PATH_PREFIX "/private/var/containers/Bundle/Application/"
static int fake_pid=1, marker_kind;
static bool hook_exists=true, whitelist_exists, white_exec, white_path, dynamic_blacklisted;
static int ipc_queries;
static const char *HOOK_DYLIB_PATH="/usr/lib/systemhook-TEST.dylib";
static const char *app="/private/var/containers/Bundle/Application/00000000-0000-0000-0000-000000000001/Demo.app/Demo";
static int test_getpid(void) { return fake_pid; }
#define getpid test_getpid
static char *test_realpath(const char *p, char *out) {
    const char *resolved=!strcmp(p,"/app-alias") ? app : p;
    assert(strlen(resolved)<PATH_MAX); strcpy(out,resolved); return out;
}
#define realpath test_realpath
struct statfs { char f_mntonname[32]; };
static int test_statfs(const char *p, struct statfs *out) {
    strcpy(out->f_mntonname, !strncmp(p,"/System/",8) ? "/" : "/private/var"); return 0;
}
#define statfs test_statfs
static int test_access(const char *p,int mode) {
    (void)mode;
    if (!strcmp(p,HOOK_DYLIB_PATH)) return hook_exists ? 0 : -1;
    if (strstr(p,"/_TrollStoreLite")) return marker_kind==2 ? 0 : -1;
    if (strstr(p,"/_TrollStore")) return marker_kind==1 ? 0 : -1;
    if (strstr(p,"cn.zqbb.inject.plist")) return whitelist_exists ? 0 : -1;
    return -1;
}
#define access test_access
#define JBROOT_PATH(p) (p)
#ifndef RC9_LAUNCHD
static bool jbclient_blacklist_check_path(const char *p) {
    assert(!strcmp(p,app)); ++ipc_queries; return dynamic_blacklisted;
}
#endif
static bool zqbb_wantInject(const char *p, const char *config) { (void)p;(void)config;return white_exec; }
static bool zqbb_isWhiteList(const char *p) { (void)p;return white_path; }
static int configured_addend=10;
int zqbb_getJetsamAddend(const char *p) { (void)p;return configured_addend; }

/* XPC ownership is counted while file-cache I/O is mocked. */
enum { XPC_TYPE_DICTIONARY=1, XPC_TYPE_ARRAY=2, XPC_TYPE_BOOL=3 };
typedef struct { int type, refs; } TestXPC;
typedef TestXPC *xpc_object_t;
typedef int RCInjectPolicyCache;
#define RC_INJECT_POLICY_CACHE_INIT 0
static TestXPC dictionary={XPC_TYPE_DICTIONARY,0}, blacklist={XPC_TYPE_ARRAY,0};
static bool config_exists, value_exists;
static const char *blacklist_entries[4];
static xpc_object_t xpc_retain(xpc_object_t o) { assert(o);++o->refs;return o; }
static void xpc_release(xpc_object_t o) { assert(o && o->refs>0);--o->refs; }
static xpc_object_t rc_inject_policy_cache_copy_dictionary(RCInjectPolicyCache *c,const char *p) {
    (void)c;assert(!strcmp(p,"/basebin/config.plist"));
    return config_exists ? xpc_retain(&dictionary) : NULL;
}
static xpc_object_t xpc_dictionary_get_value(xpc_object_t o,const char *key) {
    assert(o==&dictionary && !strcmp(key,"ProcessBlacklist"));return value_exists ? &blacklist : NULL;
}
static int xpc_get_type(xpc_object_t o) { return o->type; }
static size_t xpc_array_get_count(xpc_object_t o) { assert(o==&blacklist);return 4; }
static const char *xpc_array_get_string(xpc_object_t o,size_t i) { assert(o==&blacklist);return blacklist_entries[i]; }
'''

MAIN = r'''
static int trusts, calls, debug_calls, original_result;
static bool seen_dyld;
static char seen_libraries[1024], seen_safe[32], seen_ms[32];
static void capture(char *const env[]) {
    ++calls;
    const char *v=envbuf_getenv((const char **)env,"DYLD_INSERT_LIBRARIES");
    seen_dyld=v!=NULL; snprintf(seen_libraries,sizeof(seen_libraries),"%s",v ? v : "");
    v=envbuf_getenv((const char **)env,"_SafeMode"); snprintf(seen_safe,sizeof(seen_safe),"%s",v ? v : "");
    v=envbuf_getenv((const char **)env,"_MSSafeMode"); snprintf(seen_ms,sizeof(seen_ms),"%s",v ? v : "");
}
static int trust(const char *p) { assert(p);++trusts;return 0; }
static int debug(uint64_t p,bool all) { assert(p==42 && !all);++debug_calls;return 0; }
static int original_spawn(pid_t *p,const char *path,struct _posix_spawn_args_desc *d,char *const a[],char *const e[]) {
    (void)path;(void)d;(void)a;capture(e);if(p && original_result==0)*p=42;return original_result;
}
static int original_exec(const char *p,char *const a[],char *const e[]) { (void)p;(void)a;capture(e);return original_result; }
static void reset(void) {
    assert(dictionary.refs==0 && blacklist.refs==0);
    fake_pid=1;marker_kind=0;hook_exists=true;
    whitelist_exists=white_exec=white_path=dynamic_blacklisted=false;
    config_exists=value_exists=false;blacklist.type=XPC_TYPE_ARRAY;
    memset(blacklist_entries,0,sizeof(blacklist_entries));
    configured_addend=10;allocation_count=0;fail_at=-1;
    trusts=calls=debug_calls=type_queries=flag_queries=ipc_queries=original_result=0;
}
static int run(const char *path,char *const env[],struct _posix_spawn_args_desc *desc,double multiplier) {
    return spawn_exec_hook_common(path,NULL,env,desc,trust,multiplier,^int(char *const patched[]) {
        capture(patched);return original_result;
    });
}
int main(void) {
    /* The same compiled function is exercised in launchd and systemhook modes. */
    const char *paths[]={app,"/System/Library/daemon","/jb/usr/bin/tool"};
    for(int child=0;child<2;child++) for(int marker=0;marker<3;marker++)
    for(int path=0;path<3;path++) for(int flag=0;flag<3;flag++) {
        reset();fake_pid=child ? 100 : 1;marker_kind=marker;
        char *env[]={flag==1 ? "_SafeMode=1" : "_SafeMode=0",flag==2 ? "_MSSafeMode=1" : "_MSSafeMode=0",NULL};
        bool allowed=flag==0 || child || path==2 || (path==0 && marker!=0);
        assert(run(paths[path],env,NULL,0)==0);
        assert(calls==1 && trusts==1 && seen_dyld==allowed && type_queries==0);
        assert(!strcmp(seen_libraries,allowed ? HOOK_DYLIB_PATH : ""));
        if(allowed) {
            assert(!strcmp(seen_safe,flag==1 ? "1" : "0"));
            assert(!strcmp(seen_ms,flag==2 ? "1" : "0"));
        } else assert(!*seen_safe && !*seen_ms);
    }
    reset();assert(run(NULL,NULL,NULL,0)==0 && calls==1 && trusts==0);
    reset();struct _posix_spawn_args_desc empty={NULL};pid_t pid=0;
    assert(posix_spawn_hook_shared(&pid,"/jb/tool",&empty,NULL,NULL,original_spawn,trust,debug,0)==0);
    assert(pid==42 && calls==1 && type_queries==0 && flag_queries==0);
    reset();original_result=-1;errno=ENOENT;
    assert(execve_hook_shared("/jb/tool",NULL,NULL,original_exec,trust)==-1 && errno==ENOENT && calls==1);
    reset();fail_at=0;
    assert(execve_hook_shared("/jb/tool",NULL,NULL,original_exec,trust)==-1 && errno==ENOMEM && calls==0);

    /* DriverKit and a missing hook must never receive an inserted dylib. */
    for(int driver=0;driver<2;driver++) for(int safe_mode=0;safe_mode<3;safe_mode++) {
        reset();TestAttr a={driver ? POSIX_SPAWN_PROC_TYPE_DRIVER : 0,100,80,0};
        struct _posix_spawn_args_desc d={&a};hook_exists=driver!=0;
        char *env[]={safe_mode==1 ? "_SafeMode=1" : "_SafeMode=0",safe_mode==2 ? "_MSSafeMode=1" : "_MSSafeMode=0",NULL};
        assert(run("/jb/tool",env,&d,3)==0 && !seen_dyld && a.active==100);
    }
    reset();TestAttr a={0,100,-1,POSIX_SPAWN_START_SUSPENDED};struct _posix_spawn_args_desc d={&a};
    assert(posix_spawn_hook_shared(&pid,"/jb/tool",&d,NULL,NULL,original_spawn,trust,debug,0)==0);
    assert(a.active==140 && a.inactive==-1 && debug_calls==1);
    reset();a.active=INT_MAX-1;a.inactive=80;a.flags=0;configured_addend=INT_MAX;
    assert(run("/jb/tool",NULL,&d,3)==0 && a.active==INT_MAX && a.inactive==INT_MAX);
    reset();a.active=100;a.inactive=80;assert(run("/jb/tool",NULL,&d,1)==0 && a.active==100 && a.inactive==80);
    assert(rc9_zqbb_jetsam_addend(0,3)==40 && rc9_zqbb_jetsam_addend(25,2)==45);
    assert(rc9_zqbb_jetsam_addend(10,NAN)==0 && rc9_zqbb_jetsam_limit(-1,40)==-1);

    reset();assert(spawn_config_for_executable(NULL,NULL)==0);
    assert(spawn_config_for_executable("/System/Library/Frameworks/GSS.framework/Helpers/GSSCred",NULL)==0);
    assert(spawn_config_for_executable("/jb/usr/lib/apt/methods/http",NULL)==kSpawnConfigTrust);
    assert(spawn_config_for_executable("/jb/usr/bin/apt-get",NULL)==3);
    for(int white=0;white<2;white++) {
        reset();config_exists=value_exists=true;blacklist_entries[1]="/jb/tool";
        whitelist_exists=white_exec=white_path=white!=0;
        assert(spawn_config_for_executable("/jb/tool",NULL)==kSpawnConfigTrust);
        assert(dictionary.refs==0 && blacklist.refs==0);
        blacklist.type=XPC_TYPE_BOOL;assert(spawn_config_for_executable("/jb/tool",NULL)==3);
    }
    reset();whitelist_exists=true;assert(spawn_config_for_executable("/jb/tool",NULL)==0);
    white_exec=true;assert(spawn_config_for_executable("/jb/tool",NULL)==3);
    white_exec=false;white_path=true;assert(spawn_config_for_executable("/jb/tool",NULL)==3);
    reset();dynamic_blacklisted=true;
#ifndef RC9_LAUNCHD
    assert(spawn_config_for_executable("/app-alias",NULL)==0 && ipc_queries==1);
    marker_kind=1;char *safe[]={"_SafeMode=1",NULL};
    assert(run(app,safe,NULL,0)==0 && trusts==0 && !seen_dyld);
#else
    /* No client symbol exists in this build; dynamic denial stays in prehook. */
    assert(spawn_config_for_executable(app,NULL)==3 && ipc_queries==0);
#endif

    const char *lists[]={"/usr/lib/systemhook-TEST.dylib", ":/usr/lib/systemhook-TEST.dylib::/usr/lib/systemhook-TEST.dylib:",
        "/a.dylib:/usr/lib/systemhook-TEST.dylib:/b.dylib:/usr/lib/systemhook-TEST.dylib:"};
    const char *expected[]={"","","/a.dylib:/b.dylib"};
    for(int i=0;i<3;i++) {
        reset();whitelist_exists=true;char entry[1024];snprintf(entry,sizeof(entry),"DYLD_INSERT_LIBRARIES=%s",lists[i]);
        char *env[]={entry,"_SafeMode=1","_MSSafeMode=1","KEEP=ok",NULL};
        assert(run("/jb/tool",env,NULL,0)==0);
        assert(seen_dyld==(i==2) && !strcmp(seen_libraries,expected[i]) && !*seen_safe && !*seen_ms);
        assert(!strcmp(entry+strlen("DYLD_INSERT_LIBRARIES="),lists[i]));
    }
    reset();char *other[]={"DYLD_INSERT_LIBRARIES=/a.dylib",NULL};
    assert(run("/jb/tool",other,NULL,0)==0);
    assert(!strcmp(seen_libraries,"/usr/lib/systemhook-TEST.dylib:/a.dylib"));
    reset();char *already[]={"DYLD_INSERT_LIBRARIES=/usr/lib/systemhook-TEST.dylib:/a.dylib",NULL};
    assert(run("/jb/tool",already,NULL,0)==0);
    assert(!strcmp(seen_libraries,"/usr/lib/systemhook-TEST.dylib:/a.dylib"));

    /* Fail each allocation in insertion and removal. Never call orig with a partial env. */
    for(int removing=0;removing<2;removing++) {
        reset();whitelist_exists=removing;
        char *env[]={removing ? "DYLD_INSERT_LIBRARIES=/a.dylib:/usr/lib/systemhook-TEST.dylib" : "KEEP=ok",NULL};
        assert(run("/jb/tool",env,NULL,0)==0);int allocations=allocation_count;
        for(int failure=0;failure<allocations;failure++) {
            reset();whitelist_exists=removing;fail_at=failure;
            int r=run("/jb/tool",env,NULL,0);
            assert(r==ENOMEM && calls==0);
        }
    }
    reset();puts("PASS: shared common spawn, SafeMode, envbuf, blacklist, APT, jetsam and allocation failures");
    return 0;
}
'''


def native_tests(compiler):
    helpers = ["getAppUUIDPath", "isRemovableBundlePath", "hasTrollstoreMarker", "allowInjectWithSafeMode"]
    common = ["string_enumerate_components", "jbuserconfig_get_value", "is_apt_transport_path",
              "spawn_config_for_executable", "spawn_exec_hook_common", "posix_spawn_hook_shared", "execve_hook_shared"]
    body = (PREFIX + source("BaseBin/systemhook/src/common/envbuf.c") +
            source("BaseBin/systemhook/src/common/rc9_jetsam_limit.h") +
            "\n".join(function(ROOTHIDER, name) for name in helpers) +
            "\n".join(function(COMMON, name) for name in common) + MAIN)
    with tempfile.TemporaryDirectory(prefix="rc9-common-") as tmp:
        file = Path(tmp) / "common.c"
        file.write_text(body, encoding="utf-8")
        for launchd in (False, True):
            binary = Path(tmp) / ("launchd-test" if launchd else "systemhook-test")
            args = [compiler, "-std=gnu11", "-fblocks", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-function", "-Wno-unused-parameter", "-O1", "-g", "-fsanitize=address,undefined"]
            if launchd:
                args.append("-DRC9_LAUNCHD=1")
            if sys.platform != "darwin":
                args.extend(["-lBlocksRuntime", "-lm"])
            subprocess.run(args + [str(file), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SharedContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        compiler = shutil.which("clang")
        if not compiler:
            raise SystemExit("--native requires clang; no native tests were run")
        native_tests(compiler)
    else:
        print("Source contracts only; run --native on a clang/Blocks host.")
