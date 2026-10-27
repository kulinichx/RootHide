"""RC9 policy regression checks. Run with Python 3; --native requires clang.

Source checks run without Apple SDKs. Native checks compile the actual C
function bodies with mocked OS/XPC boundaries, not a reimplementation of them.
Neither mode replaces an arm64/arm64e build or iOS 16 device validation.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def function(path, name):
    text = source(path)
    match = re.search(r"^(?:static )?(?:bool|int) " + re.escape(name) + r"\s*\([^;]*?\)\s*\{", text, re.M)
    if not match:
        raise AssertionError(f"Function not found: {path}: {name}")
    # These audited function bodies have balanced braces in their comments.
    start = text.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
        end += 1
    return text[match.start():end]


class SourceContracts(unittest.TestCase):
    def test_whitelist_is_independent_of_tweak_toggle(self):
        body = function("BaseBin/libjailbreak/src/roothider/_wantsInject.c", "zqbb_wantsInject")
        self.assertNotIn("roothide_isTweakInjectionEnabled(", body)
        self.assertNotIn(".safe_mode", body)
        self.assertIn("xpc_dictionary_get_bool(xplist, execName)", body)
        self.assertIn("xpc_release(xplist)", body)

    def test_tweak_gate_uses_call_local_root_path(self):
        body = function("BaseBin/systemhook/src/_zqbb.c", "roothide_isTweakInjectionEnabled")
        self.assertNotRegex(body, r"static\s+(?:const\s+)?char\s*\*")
        self.assertIn(".safe_mode", body)
        self.assertIn("tweakInjectionEnabled", body)
        self.assertIn("xpc_release(dict)", body)
        self.assertIn("roothide_isTweakInjectionEnabled()", function("BaseBin/systemhook/src/main.c", "should_enable_tweaks"))

    def test_gate_implementation_is_linked(self):
        self.assertIn("bool roothide_isTweakInjectionEnabled(void);", source("BaseBin/systemhook/src/_zqbb.h"))
        self.assertIn("src/_zqbb.c", source("BaseBin/systemhook/Makefile"))
        self.assertIn("../systemhook/src/_zqbb.c", source("BaseBin/launchdhook/Makefile"))

    def test_dual_manager_contract_is_preserved(self):
        body = source("BaseBin/libjailbreak/src/roothider/blacklist.m")
        self.assertIn("access(injectPlistPath, F_OK) == 0", body)
        self.assertIn("cn.zqbb.inject.wantsblacklist.plist", body)
        self.assertIn("cn.zqbb.dopaRH", body)
        self.assertIn("jbinfo(appIdentifier)", body)
        for path in ("BaseBin/libjailbreak/src/roothider/_whitelist.c", "BaseBin/systemhook/src/_zqbb.c"):
            self.assertIn("strstr(path, key)", source(path))
        self.assertIn("Do not create cn.zqbb.inject.plist here.", source("Application/Dopamine/Jailbreak/DOJailbreaker.m"))

    def test_spawn_gates_and_failure_pid(self):
        system = function("BaseBin/systemhook/src/roothider_main.c", "roothide_systemhook___posix_spawn_posthook")
        self.assertIn("bool should_suspend = (spawnConfig & kSpawnConfigInject) &&", system)
        self.assertIn("bool patch_exec = should_suspend &&", system)
        self.assertIn("if (ret == 0 && pidp) *pidp = pid;", system)
        self.assertGreater(system.index("if (ret == 0 && pidp) *pidp = pid;"), system.index("return 202;"))
        launchd = function("BaseBin/launchdhook/src/roothider.m", "roothide_launchd___posix_spawn_posthook")
        self.assertIn("bool should_suspend = !is_apt_transport_path(path) &&", launchd)
        self.assertGreater(launchd.index("if (ret == 0 && pidp) *pidp = pid;"), launchd.index("ret = 202;"))

    def test_sysctl_name_requires_exact_length(self):
        body = function("BaseBin/systemhook/src/roothider_common.c", "__sysctlbyname_hook")
        self.assertIn("namelen == strlen(target)", body)
        self.assertIn("strncmp(name, target, namelen)", body)

    def test_system_preferences_and_preboot(self):
        prefs = source("BaseBin/roothidehooks/cfprefsd.x")
        for name in ("ReportSystemMemory", "TokenBucketRateLimiter", "PerfPowerServices"):
            self.assertIn(f'@"{name}.plist"', prefs)
        self.assertIn('strcmp(fs.f_mntonname, "/private/preboot") == 0', source("BaseBin/roothidehooks/common.m"))

    def test_userspace_reboot_skips_touch_firmware_reload(self):
        body = source("BaseBin/launchdhook/src/daemon_hook.m")
        launch_daemons = body.split('if (!strcmp(key, "LaunchDaemons")) {', 1)[1].split('else if (!strcmp(key, "Paths"))', 1)[0]
        self.assertIn('xpc_get_type(origXvalue) == XPC_TYPE_DICTIONARY', launch_daemons)
        self.assertIn('xpc_dictionary_set_value(origXvalue, "/System/Library/LaunchDaemons/com.apple.mtmergeprops.plist", NULL);', launch_daemons)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>
enum { kSpawnConfigInject=1, kSpawnConfigTrust=2, NBINPREFS=4,
       POSIX_SPAWN_START_SUSPENDED=0x80, POSIX_SPAWN_SETEXEC=0x40,
       POSIX_SPAWN_PROC_TYPE_DRIVER=0x700 };
typedef int kSpawnConfig;
typedef int cpu_type_t;
typedef uint32_t cpu_subtype_t;
typedef struct { short flags; int proctype; } TestAttr;
typedef void *posix_spawnattr_t;
struct _posix_spawn_args_desc { posix_spawnattr_t attrp; };
typedef struct { int type; bool enabled; } TestXPC;
typedef TestXPC *xpc_object_t;
enum { XPC_TYPE_BOOL=1, XPC_TYPE_DICTIONARY=2, XPC_TYPE_INT64=3 };
#define XPC_ARRAY_APPEND ((size_t)-1)
static TestXPC dict={XPC_TYPE_DICTIONARY, false}, value={XPC_TYPE_BOOL, true};
static bool safe_mode, missing_dict, missing_value, whitelist;
static int releases, copies;
typedef int RCInjectPolicyCache;
#define RC_INJECT_POLICY_CACHE_INIT 0
static RCInjectPolicyCache injectPolicyCache;
static const char *root="/root-one";
static char last_config[512];
static const char *test_jbroot(const char *path, char *buffer) {
    snprintf(buffer, 512, "%s%s", root, path); return buffer;
}
#define JBROOT_PATH(path) test_jbroot(path, __builtin_alloca(512))
static int test_access(const char *path, int mode) {
    (void)mode; return safe_mode && strstr(path, ".safe_mode") ? 0 : -1;
}
#define access test_access
static xpc_object_t rc_inject_policy_cache_copy_dictionary(RCInjectPolicyCache *cache, const char *path) {
    (void)cache; ++copies; assert(path); snprintf(last_config, sizeof(last_config), "%s", path);
    return missing_dict ? NULL : &dict;
}
static xpc_object_t xpc_dictionary_get_value(xpc_object_t d, const char *key) {
    (void)d; (void)key; return missing_value ? NULL : &value;
}
static int xpc_get_type(xpc_object_t v) { return v->type; }
static bool xpc_bool_get_value(xpc_object_t v) { return v->enabled; }
static bool xpc_dictionary_get_bool(xpc_object_t d, const char *key) { (void)d; (void)key; return whitelist; }
static void xpc_release(xpc_object_t v) { assert(v); ++releases; }
static xpc_object_t xpc_array_create_empty(void) { return &dict; }
static xpc_object_t xpc_dictionary_create_empty(void) { return &dict; }
static void xpc_dictionary_set_uint64(xpc_object_t d,const char *k,uint64_t v) {(void)d;(void)k;(void)v;}
static void xpc_array_set_value(xpc_object_t a,size_t i,xpc_object_t v) {(void)a;(void)i;(void)v;}
static int policy, starts, cancels, patches, resumes, kills, spawns, spawn_error, start_error, patch_error, trusts;
static bool copy_fail, set_fail, dyld_enabled;
static bool has_insert_libraries;
static short seen_flags;
static kSpawnConfig spawn_config_for_executable(const char *p, char *const a[]) { (void)p;(void)a; return policy; }
static bool jbclient_dyld_patch_enabled(void) { return dyld_enabled; }
static int posix_spawnattr_getflags(posix_spawnattr_t *a, short *f) { *f=((TestAttr *)*a)->flags; return 0; }
static int posix_spawnattr_setflags(posix_spawnattr_t *a, short f) { ((TestAttr *)*a)->flags=f; return 0; }
static int posix_spawnattr_getprocesstype_np(posix_spawnattr_t *a, int *p) { *p=((TestAttr *)*a)->proctype; return 0; }
static int posix_spawnattr_getarchpref_np(posix_spawnattr_t *a,size_t n,cpu_type_t *t,cpu_subtype_t *s,size_t *o) {
    (void)a;(void)n;(void)t;(void)s;*o=0;return 0;
}
static int jbclient_trust_executable_recurse(const char *p,xpc_object_t a) {(void)p;(void)a;++trusts;return 0;}
static int jbdSpawnExecStart(const char *p,bool r) {(void)p;(void)r;++starts;return start_error;}
static int jbdSpawnExecCancel(const char *p) {(void)p;++cancels;return 0;}
static int jbdSpawnPatchChild(int p,bool r) {assert(p>0);++patches;resumes+=r;return patch_error;}
static int test_kill(pid_t p,int s) {assert(p>0);(void)s;++kills;return 0;}
#define kill test_kill
static int __posix_spawn_orig(pid_t *p,const char *path,struct _posix_spawn_args_desc *d,char *const a[],char *const e[]) {
    (void)path;(void)a;(void)e;++spawns;seen_flags=((TestAttr *)d->attrp)->flags;
    if (!spawn_error) *p=42;
    return spawn_error;
}
#define __posix_spawn_orig_wrapper __posix_spawn_orig
static bool trust_insert_libraries(char **e) {(void)e;return !set_fail;}
static char **envbuf_mutcopy(const char **e) {if (!e || copy_fail) return NULL; return calloc(1,sizeof(char *));}
static const char *envbuf_getenv(const char **e,const char *k) {(void)e;(void)k;return has_insert_libraries ? "/test.dylib" : NULL;}
static bool envbuf_setenv(char ***e,const char *k,const char *v) {(void)e;(void)k;(void)v;return !set_fail;}
static void envbuf_free(char **e) {free(e);}
#define JBLogError(...) ((void)0)
static void reset_spawn(void) {
    starts=cancels=patches=resumes=kills=spawns=spawn_error=start_error=patch_error=trusts=0;
    copy_fail=set_fail=has_insert_libraries=false;dyld_enabled=true;seen_flags=0;
}
static int sysctl_calls;
static int syscall__sysctlbyname(const char *name,size_t namelen,void *oldp,size_t *oldlenp,void *newp,size_t newlen) {
    (void)name;(void)namelen;(void)oldp;(void)oldlenp;(void)newp;(void)newlen;
    ++sysctl_calls;return ENOENT;
}
'''

NATIVE_MAIN = r'''
int main(void) {
    whitelist=true;safe_mode=true;
    assert(zqbb_wantsInject("Demo", "/inject.plist"));
    assert(!roothide_isTweakInjectionEnabled());
    safe_mode=false;value.enabled=false;
    assert(zqbb_wantsInject("Demo", "/inject.plist"));
    assert(!roothide_isTweakInjectionEnabled());
    whitelist=false;assert(!zqbb_wantsInject("Demo", "/inject.plist"));
    value.enabled=true;assert(roothide_isTweakInjectionEnabled());
    missing_value=true;assert(roothide_isTweakInjectionEnabled());missing_value=false;
    value.type=XPC_TYPE_INT64;assert(roothide_isTweakInjectionEnabled());value.type=XPC_TYPE_BOOL;
    missing_dict=true;assert(roothide_isTweakInjectionEnabled());
    assert(!zqbb_wantsInject("Demo", "/inject.plist"));missing_dict=false;
    assert(!zqbb_wantsInject(NULL, "/inject.plist"));
    assert(!zqbb_wantsInject("Demo", NULL));
    for (int i=0;i<1000;i++) {
        root=i%2 ? "/root-two" : "/root-one";
        assert(roothide_isTweakInjectionEnabled());
        assert(strncmp(last_config,root,strlen(root))==0);
    }
    assert(releases==copies-2); // two missing-dictionary lookups
    for (policy=0;policy<4;policy++) for(int driver=0;driver<2;driver++)
    for(int suspended=0;suspended<2;suspended++) for(int exec=0;exec<2;exec++) {
        reset_spawn();
        short flags=(suspended ? POSIX_SPAWN_START_SUSPENDED : 0) | (exec ? POSIX_SPAWN_SETEXEC : 0);
        TestAttr attr={flags,driver ? POSIX_SPAWN_PROC_TYPE_DRIVER : 0};
        struct _posix_spawn_args_desc desc={&attr};pid_t pid=777;
        bool patch=(policy & kSpawnConfigInject) && !driver;
        spawn_error=exec ? ENOENT : 0; // successful SETEXEC cannot return
        int result=roothide_systemhook___posix_spawn_posthook(&pid,"/bin/demo",&desc,NULL,NULL);
        assert(result==spawn_error && attr.flags==flags);
        assert(pid==(exec ? 777 : 42));
        assert(seen_flags==(short)(flags | (patch ? POSIX_SPAWN_START_SUSPENDED : 0)));
        assert(starts==(patch && exec) && cancels==starts);
        assert(patches==(patch && !exec));
        assert(resumes==(patch && !exec && !suspended));
    }
    reset_spawn();policy=kSpawnConfigInject;copy_fail=true;
    TestAttr attr={POSIX_SPAWN_SETEXEC,0};struct _posix_spawn_args_desc desc={&attr};
    pid_t pid=777;char *env[]={"TEST=1",NULL};
    assert(roothide_systemhook___posix_spawn_posthook(&pid,"/bin/demo",&desc,NULL,env)==ENOMEM);
    assert(pid==777 && spawns==0 && starts==1 && cancels==1 && attr.flags==POSIX_SPAWN_SETEXEC);
    reset_spawn();start_error=1;
    assert(roothide_systemhook___posix_spawn_posthook(&pid,"/bin/demo",&desc,NULL,NULL)==201);
    assert(pid==777 && spawns==0 && attr.flags==POSIX_SPAWN_SETEXEC);
    reset_spawn();patch_error=1;attr.flags=0;
    assert(roothide_systemhook___posix_spawn_posthook(&pid,"/bin/demo",&desc,NULL,NULL)==202);
    assert(pid==777 && kills==2 && patches==1 && attr.flags==0);
    reset_spawn();set_fail=has_insert_libraries=true;attr.flags=POSIX_SPAWN_SETEXEC;
    assert(roothide_systemhook___posix_spawn_posthook(&pid,"/bin/demo",&desc,NULL,env)==ENOMEM);
    assert(pid==777 && spawns==0 && starts==1 && cancels==1 && attr.flags==POSIX_SPAWN_SETEXEC);
    reset_spawn();set_fail=true;dyld_enabled=false;attr.flags=0;
    assert(roothide_systemhook___posix_spawn_posthook(&pid,"/bin/demo",&desc,NULL,env)==ENOMEM);
    assert(pid==777 && spawns==0 && patches==0 && attr.flags==0);
    reset_spawn();policy=kSpawnConfigTrust;dyld_enabled=false;
    assert(roothide_systemhook___posix_spawn_posthook(NULL,"/apt/methods/http",&desc,NULL,NULL)==0);
    assert(trusts==1 && patches==0 && seen_flags==0);
    const char *paths[]={"/jb/usr/lib/apt/methods/http","/jb/usr/bin/apt-get"};
    for(int method=0;method<2;method++) for(int driver=0;driver<2;driver++) for(int suspended=0;suspended<2;suspended++) {
        reset_spawn();attr.flags=suspended ? POSIX_SPAWN_START_SUSPENDED : 0;
        short flags=attr.flags;attr.proctype=driver ? POSIX_SPAWN_PROC_TYPE_DRIVER : 0;
        bool patch=method && !driver;
        assert(roothide_launchd___posix_spawn_posthook(&pid,paths[method],&desc,NULL,NULL)==0);
        assert(patches==patch && resumes==(patch && !suspended) && attr.flags==flags);
        assert(seen_flags==(short)(flags | (patch ? POSIX_SPAWN_START_SUSPENDED : 0)));
    }
    for(int method=0;method<2;method++) for(int suspended=0;suspended<2;suspended++) {
        for(int failure=0;failure<3;failure++) {
            reset_spawn();pid=777;attr.proctype=0;
            short flags=suspended ? POSIX_SPAWN_START_SUSPENDED : 0;attr.flags=flags;
            copy_fail=failure==0;
            set_fail=has_insert_libraries=failure==1;
            spawn_error=failure==2 ? ENOENT : 0;
            int expected=failure==2 ? ENOENT : ENOMEM;
            assert(roothide_launchd___posix_spawn_posthook(&pid,paths[method],&desc,NULL,env)==expected);
            assert(pid==777 && patches==0 && kills==0 && attr.flags==flags);
            assert(spawns==(failure==2));
        }
    }
    reset_spawn();pid=777;patch_error=1;attr.flags=0;attr.proctype=0;
    assert(roothide_launchd___posix_spawn_posthook(&pid,paths[1],&desc,NULL,NULL)==202);
    assert(pid==777 && kills==2 && patches==1 && attr.flags==0);
    const char target[]="security.mac.amfi.developer_mode_status";
    int status=0;size_t size=sizeof(status);
    assert(__sysctlbyname_hook(target,strlen(target),&status,&size,NULL,0)==0);
    assert(status==1 && sysctl_calls==0);
    for(size_t len=0;len<strlen(target);len++) {
        status=77;size=sizeof(status);int before=sysctl_calls;
        assert(__sysctlbyname_hook(target,len,&status,&size,NULL,0)==ENOENT);
        assert(status==77 && sysctl_calls==before+1);
    }
    const char suffix[]="security.mac.amfi.developer_mode_status.extra";
    assert(__sysctlbyname_hook(suffix,strlen(suffix),&status,&size,NULL,0)==ENOENT);
    assert(__sysctlbyname_hook(NULL,0,&status,&size,NULL,0)==ENOENT);
    char bounded[sizeof(target)-1];memcpy(bounded,target,sizeof(bounded));
    assert(__sysctlbyname_hook(bounded,sizeof(bounded),&status,&size,NULL,0)==0);
    size=sizeof(status)-1;
    assert(__sysctlbyname_hook(target,strlen(target),&status,&size,NULL,0)==ENOENT);
    puts("PASS: actual C policy/spawn functions with mocked OS/XPC boundaries");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    functions = [
        ("BaseBin/systemhook/src/_zqbb.c", "roothide_isTweakInjectionEnabled"),
        ("BaseBin/libjailbreak/src/roothider/_wantsInject.c", "zqbb_wantsInject"),
        ("BaseBin/systemhook/src/common.c", "is_apt_transport_path"),
        ("BaseBin/systemhook/src/roothider_main.c", "roothide_systemhook___posix_spawn_posthook"),
        ("BaseBin/launchdhook/src/roothider.m", "roothide_launchd___posix_spawn_posthook"),
        ("BaseBin/systemhook/src/roothider_common.c", "__sysctlbyname_hook"),
    ]
    with tempfile.TemporaryDirectory(prefix="rc9-policy-") as tmp:
        file = Path(tmp) / "policy.c"
        binary = Path(tmp) / "policy-test"
        file.write_text(NATIVE_PREFIX + '\n'.join(function(*f) for f in functions) + NATIVE_MAIN, encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-Wno-unused-function", "-U__arm64e__", "-O1", "-g",
                        "-fsanitize=address,undefined", str(file), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SourceContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on a clang host for executable regression tests.")
