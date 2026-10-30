"""RC9 service regressions; --native uses macOS Foundation with mocked OS/XPC.
The tested functions are extracted from production sources, not rewritten models.
"""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(path):
    return (ROOT / path).read_text(encoding="utf-8")

def extract(text, anchor):
    start = text.index(anchor)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

class ServiceContracts(unittest.TestCase):
    def test_setid_checkin_updates_task_audit_token(self):
        systemwide = source('BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c')
        checkin_start = systemwide.index('int systemwide_process_checkin')
        checkin_end = systemwide.index('int systemwide_fork_fix', checkin_start)
        checkin = systemwide[checkin_start:checkin_end]
        self.assertIn('uid_t uid = kread32(ucred + koffsetof(ucred, uid));', checkin)
        self.assertIn('gid_t gid = kread32(ucred + koffsetof(ucred, groups));', checkin)
        self.assertIn('uid = sb.st_uid;', checkin)
        self.assertIn('gid = sb.st_gid;', checkin)
        self.assertIn('if (gSystemInfo.kernelStruct.proc_ro.exists && koffsetof(proc_ro, task_tokens))', checkin)
        self.assertIn('koffsetof(task_token_ro_data, audit_token)', checkin)
        for offset, field in ((4, 'uid'), (8, 'gid'), (12, 'ruid'), (16, 'rgid')):
            self.assertIn(f'kwrite32(auditToken + {offset}, {field});', checkin)

    def test_uttype_is_enabled_as_guarded_group(self):
        text = source('BaseBin/roothidehooks/lsd.x')
        group = text.split('%group UTTypeHooks', 1)[1].split('%end // %group UTTypeHooks', 1)[0]
        self.assertNotIn('#if 0', group)
        self.assertEqual(group.count('%hookf('), 6)
        self.assertEqual(group.count('BOOL previousHide = g_utrHide;'), 9)
        self.assertEqual(group.count('g_utrHide = previousHide;'), 9)
        self.assertEqual(group.count('@finally'), 11)
        init = extract(text, 'void lsdInit(void)')
        condition = re.search(r'if\(utrRecordAPIAvailable\(\)([^\n]+)\)', init).group(1)
        for name in ('_LSSchemaCacheRead', '_LSSchemaCacheWrite', '_UTEnumerateTypesForTag',
                     '_UTEnumerateTypesForIdentifier', '_UTTypeSearchConformingTypesWithBlock',
                     '_UTTypeSearchConformsToTypesWithBlock'):
            self.assertIn(name, condition)
        self.assertIn('if (coreServicesImage)', init)

    def test_runningboard_dispatch_and_signature(self):
        self.assertIn('/usr/libexec/runningboardd', source('BaseBin/systemhook/src/roothider_main.c'))
        self.assertIn('rbdInit();', source('BaseBin/roothidehooks/main.x'))
        text = source('BaseBin/roothidehooks/runningboardd.x')
        self.assertIn('RBProcess* process, SEL selector)', text)
        self.assertIn('if (!target) return;', text)
        self.assertIn('if (!image) return;', text)
        self.assertNotIn('ios15', text)
        self.assertNotIn('rootfs(', text)

    def test_path_conversion_uses_official_optional_api(self):
        text = source('BaseBin/roothidehooks/common.m')
        self.assertIn('"rootfs_alloc"', text)
        self.assertIn('"jbroot_alloc"', text)
        self.assertIn('free((void*)converted)', text)
        self.assertIn('if (!rootfsAlloc || !jbrootAlloc) return nil;', text)
        self.assertNotIn('rootfs(path)', source('BaseBin/roothidehooks/pathhook.x'))
        self.assertNotIn('-lroothide', source('BaseBin/roothidehooks/Makefile'))

    def test_xpc_validation_precedes_dictionary_access(self):
        text = source('BaseBin/jailbreakd/src/server.m')
        check = text.index('if (!message || xpc_get_type(message) != XPC_TYPE_DICTIONARY)')
        self.assertLess(check, text.index('xpc_dictionary_get_value(message'))
        self.assertLess(check, text.index('xpc_dictionary_create_reply(message'))
        self.assertIn('if (!reply) return;', text)
        self.assertIn('rawMessageID > UINT32_MAX', text)
        self.assertEqual(text.count('requestedPid <= 0 || requestedPid > INT_MAX'), 2)
        log_case = text.split('case JBD_MSG_SYSTEMWIDE_LOG:', 1)[1].split('case JBD_MSG_TEST_CALL:', 1)[0]
        self.assertNotIn('abort()', log_case)
        self.assertIn('-ENOTSUP', text)

    def test_blacklisted_xpc_is_filtered_before_jbserver_dispatch(self):
        hook = source('BaseBin/libjailbreak/src/roothider/xpc_hook.m')
        handler = extract(hook, 'bool roothide_handle_xpc_msg')
        self.assertLess(handler.index('check_usreboot_msg(xmsg);'),
                        handler.index('if (isBlacklistedToken(&clientToken))'))
        self.assertIn('return true;', handler)
        self.assertIn('return false;', handler)

        dispatch = extract(source('BaseBin/libjailbreak/src/jbserver.c'),
                           'int jbserver_received_xpc_message')
        early_return = dispatch.index('if (roothide_handle_xpc_msg(xmsg)) return -2;')
        domain_lookup = dispatch.index('xpc_dictionary_get_value(xmsg, "jb-domain")')
        self.assertLess(early_return, domain_lookup)

    def test_staged_update_reports_environment_failure(self):
        handler = extract(
            source('BaseBin/launchdhook/src/jbserver/jbdomain_platform.c'),
            'static int platform_stage_jailbreak_update',
        )
        access_check = handler.index('if (!access(updateTar, F_OK))')
        env_check = handler.index(
            'if (setenv("STAGED_JAILBREAK_UPDATE", updateTar, 1) != 0) return 2;'
        )
        self.assertLess(access_check, env_check)
        self.assertLess(env_check, handler.index('return 0;'))

    def test_basebin_trustcache_does_not_silently_skip_macho_failures(self):
        body = extract(
            source('BaseBin/libjailbreak/src/roothider/common.m'),
            'int randomizeAndLoadBasebinTrustcache',
        )
        self.assertLess(
            body.index('Fat *fat = fat_init_from_path('),
            body.index('ensure_randomized_cdhash('),
        )
        self.assertIn('if (!fat) continue;', body)
        self.assertIn('if (randomizeResult != 0)', body)
        self.assertIn('free(basebins_cdhashes);', body)
        self.assertIn('return -5;', body)
        self.assertIn('if (enumerationFailed)', body)
        self.assertIn('if (!basebinPath || !basebinPath[0])', body)
        self.assertIn('if (!isFile)', body)
        self.assertIn('resourceError.localizedDescription.UTF8String ?: "(unknown error)"', body)

    def test_roothide_xpf_offsets_are_appended_after_base_sets(self):
        wrapper = source('BaseBin/libjailbreak/src/roothider/xpf.c')
        header = source('BaseBin/libjailbreak/src/roothider/common.h')
        find_namecache = extract(wrapper, 'uint64_t xpf_find_namecache')
        append = extract(wrapper, 'int roothide_xpf_append_roothide_offsets')
        construct = extract(wrapper, 'xpc_object_t roothide_xpf_construct_offset_dictionary_wrapper')
        self.assertIn('XPC_RETURNS_RETAINED xpc_object_t roothide_xpf_construct_offset_dictionary_wrapper(const char *sets[]);', header)
        mismatch = find_namecache.split('if (nchashtbl != nchashmask - 8)', 1)[1].split('}', 1)[0]
        self.assertIn('nchashtbl = 0;', mismatch)
        self.assertIn('nchashmask = 0;', mismatch)
        self.assertNotIn('= -1;', mismatch)
        self.assertIn('xpf_item_register("kernelSymbol.nchashtbl"', append)
        self.assertIn('xpf_item_register("kernelSymbol.launch_env_logging"', append)
        self.assertIn('xpf_offset_dictionary_add_set(xdict, &gNameCacheSet)', append)
        self.assertIn('xpf_offset_dictionary_add_set(xdict, &gAMFIOidsSet)', append)
        self.assertLess(
            construct.index('xpf_construct_offset_dictionary(sets)'),
            construct.index('roothide_xpf_append_roothide_offsets(xdict)'),
        )
        failure = construct.index('if (roothide_xpf_append_roothide_offsets(xdict) != 0)')
        self.assertLess(
            construct.index('xpc_release(xdict);', failure),
            construct.index('return NULL;', failure),
        )

        for path, assignment in (
            ('Application/Dopamine/Jailbreak/DOJailbreaker.m', '_systemInfoXdict ='),
            ('BaseBin/launchdhook/src/update.m', 'newSystemInfoXdict ='),
        ):
            caller = source(path)
            self.assertIn(
                assignment + ' roothide_xpf_construct_offset_dictionary_wrapper((const char **)sets);',
                caller,
            )
            self.assertNotIn('sets[idx++] = "namecache";', caller)
            self.assertNotIn('sets[idx++] = "amfi_oids";', caller)

    def test_xpf_dictionaries_are_released_after_deserialization(self):
        guard = '#if !OS_OBJECT_USE_OBJC || !__has_feature(objc_arc)'
        self.assertIn('XPC_RETURNS_RETAINED xpc_object_t jbinfo_get_serialized(void);',
                      source('BaseBin/libjailbreak/src/info.h'))
        initial = source('Application/Dopamine/Jailbreak/DOJailbreaker.m')
        initial_body = extract(initial, '- (NSError *)gatherSystemInformation')
        self.assertLess(
            initial_body.index('jbinfo_initialize_dynamic_offsets(_systemInfoXdict);'),
            initial_body.index('xpc_release(_systemInfoXdict);'),
        )
        self.assertLess(
            initial_body.index('xpc_release(_systemInfoXdict);'),
            initial_body.index('_systemInfoXdict = jbinfo_get_serialized();'),
        )
        self.assertEqual(initial_body.count(guard), 2)
        self.assertIn(guard + '\n    xpc_release(_systemInfoXdict);\n#endif\n    _systemInfoXdict = NULL;',
                      initial_body)

        update = source('BaseBin/launchdhook/src/update.m')
        update_body = extract(update, 'void jbupdate_update_system_info')
        release_new = update_body.index('xpc_release(newSystemInfoXdict);')
        release_merged = update_body.index('xpc_release(systemInfoXdict);')
        self.assertGreater(release_new, update_body.index('jbinfo_initialize_dynamic_offsets(systemInfoXdict);'))
        self.assertGreater(release_merged, update_body.index('jbinfo_initialize_dynamic_offsets(systemInfoXdict);'))
        self.assertIn(guard + '\n\t\txpc_release(newSystemInfoXdict);\n\t\txpc_release(systemInfoXdict);\n#endif',
                      update_body)

    def test_bootstrap_daemon_plist_patch_propagates_failures(self):
        bootstrapper = source('Application/Dopamine/Jailbreak/DOBootstrapper.m')
        patch_one = extract(bootstrapper, '- (NSError *)patchBasebinDaemonPlist:')
        self.assertIn('if (!plistDict)', patch_one)
        self.assertIn('if (![plistDict writeToFile:plistPath atomically:YES])', patch_one)

        patch_all = extract(bootstrapper, '- (NSError *)patchBasebinDaemonPlistsAtPath:')
        self.assertIn('error:&error', patch_all)
        self.assertIn('if (error) return error;', patch_all)

        active_bootstrap = bootstrapper.rsplit('- (void)prepareBootstrapWithCompletion:', 1)[1]
        self.assertIn('error = [self replaceBasebinFromBundledArchive];', active_bootstrap)
        self.assertIn('completion(error);', active_bootstrap)

        plist_paths = sorted((ROOT / 'BaseBin/_external/basebin/LaunchDaemons').glob('*.plist'))
        self.assertTrue(plist_paths)
        for plist_path in plist_paths:
            with plist_path.open('rb') as plist_file:
                plist = plistlib.load(plist_file)
            arguments = plist.get('ProgramArguments')
            self.assertIsInstance(arguments, list, plist_path.name)
            self.assertTrue(arguments, plist_path.name)
            self.assertTrue(all(isinstance(value, str) for value in arguments), plist_path.name)
            self.assertTrue(any('@JBROOT@' in value for value in arguments), plist_path.name)

    def test_bootstrap_basebin_publication_is_recoverable(self):
        bootstrapper = source('Application/Dopamine/Jailbreak/DOBootstrapper.m')
        self.assertLess(bootstrapper.index('NSString *jbrootPrefix(NSString *path);'),
                        bootstrapper.index('@implementation DOBootstrapper'))
        recovery = extract(bootstrapper, '- (NSError *)recoverBasebinPublication')
        self.assertIn('if (hasBackup && !hasBasebin)', recovery)
        self.assertIn('if (hasBackup && isPublishedGeneration)', recovery)
        self.assertIn('Ambiguous basebin recovery state', recovery)
        self.assertIn('stageRootPath', recovery)

        publish = extract(bootstrapper, '- (NSError *)replaceBasebinFromBundledArchive')
        self.assertIn('extractTar:archivePath toPath:stageRootPath', publish)
        self.assertIn('patchBasebinDaemonPlistsAtPath:stageBasebinPath', publish)
        self.assertIn('writeToFile:readyPath', publish)
        self.assertLess(publish.index('writeToFile:readyPath'), publish.index('moveItemAtPath:basebinPath toPath:backupPath'))
        self.assertLess(publish.index('moveItemAtPath:basebinPath toPath:backupPath'), publish.index('moveItemAtPath:stageBasebinPath toPath:basebinPath'))
        self.assertIn('restoreError', publish)

        active_bootstrap = bootstrapper.rsplit('- (void)prepareBootstrapWithCompletion:', 1)[1]
        self.assertIn('replaceBasebinFromBundledArchive', active_bootstrap)
        self.assertIn('--transform "s/^.build/basebin/"', source('BaseBin/Makefile'))

    def test_injection_whitelist_uses_the_author_wantsblacklist_gate(self):
        text = source('BaseBin/libjailbreak/src/roothider/blacklist.m')
        wants_blacklist = extract(text, 'static BOOL zqbb_wantsBlacklist')
        self.assertIn('#if !OS_OBJECT_USE_OBJC || !__has_feature(objc_arc)\n    xpc_release(xplist);\n#endif',
                      wants_blacklist)

        helper = extract(text, 'static bool zqbb_isBlacklistedExec')
        gate = helper.index('if(zqbb_wantsBlacklist(')
        app_blacklist = helper.index('if(isBlacklistedPath_orig(path)) return true;')
        whitelist = helper.index('if(zqbb_wantsInject(exec, injectPath))')
        self.assertLess(gate, app_blacklist)
        self.assertLess(app_blacklist, whitelist)

        policy = extract(text, 'bool isBlacklistedPath(const char* path)')
        system_whitelist = policy.index('if(zqbb_isWhiteListForSystem(path, injectSystemPlistPath)) return false;')
        exec_whitelist = policy.index('return zqbb_isBlacklistedExec(path, injectPlistPath);')
        self.assertLess(system_whitelist, exec_whitelist)
        self.assertNotIn(
            'if(isBlacklistedPath_orig(path)) return true;',
            policy,
        )

    def test_safe_mode_trollstore_allowlist_matches_official(self):
        policy = extract(source('BaseBin/systemhook/src/roothider_common.c'),
                         'bool allowInjectWithSafeMode')
        self.assertIn('if(isRemovableBundlePath(path))', policy)
        self.assertIn('if(hasTrollstoreMarker(path))', policy)
        self.assertIn('return true;', policy)
        self.assertIn('return false;', policy)

NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <sys/types.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#define JBLogDebug(...)
#define JBLogError(...)
static void test_abort(void) { assert(!"unexpected daemon abort"); }
#define abort test_abort
'''

XPC_MOCKS = r'''
enum { XPC_TYPE_DICTIONARY=1, XPC_TYPE_UINT64, XPC_TYPE_INT64, XPC_TYPE_ARRAY };
typedef int mach_port_t;
typedef struct { pid_t pid; uid_t uid; } audit_token_t;
@interface TestXPC : NSObject
@property int kind;
@property uint64_t messageId;
@property int idKind;
@property int64_t requestedPid;
@property int64_t value;
@property int64_t result;
@property BOOL resultSet;
@property BOOL resume;
@property pid_t pid;
@property uid_t uid;
@property BOOL noReply;
@end
@implementation TestXPC
@end
typedef TestXPC* xpc_object_t;
static TestXPC *incoming, *lastReply;
static int receiveError, dictionaryCalls, patchCalls, spinCalls, replyCalls, signalCalls, traceCalls;
static int fakeParent = 50;
static int patchResult, spinResult;
static int xpc_pipe_receive(mach_port_t port, xpc_object_t* message) { *message=incoming; return receiveError; }
static int xpc_get_type(xpc_object_t object) { assert(object);return object.kind; }
static void require_dict(TestXPC* object) { assert(object && object.kind==XPC_TYPE_DICTIONARY);++dictionaryCalls; }
static xpc_object_t xpc_dictionary_get_value(xpc_object_t object,const char* key) {
    require_dict(object);assert(!strcmp(key,"id"));if(!object.idKind)return nil;
    TestXPC *value=[TestXPC new];value.kind=object.idKind;return value;
}
static xpc_object_t xpc_dictionary_create_reply(xpc_object_t object) {
    require_dict(object);if(object.noReply)return nil;
    lastReply=[TestXPC new];lastReply.kind=XPC_TYPE_DICTIONARY;return lastReply;
}
static uint64_t xpc_dictionary_get_uint64(xpc_object_t object,const char* key) {
    require_dict(object);return !strcmp(key,"id") ? object.messageId : 0;
}
static int64_t xpc_dictionary_get_int64(xpc_object_t object,const char* key) {
    require_dict(object);return !strcmp(key,"pid") ? object.requestedPid : object.value;
}
static bool xpc_dictionary_get_bool(xpc_object_t object,const char* key) { require_dict(object);return object.resume; }
static const char* xpc_dictionary_get_string(xpc_object_t object,const char* key) { require_dict(object);return "test"; }
static void xpc_dictionary_set_int64(xpc_object_t object,const char* key,int64_t value) {
    require_dict(object);assert(!strcmp(key,"result"));object.result=value;object.resultSet=YES;
}
static void xpc_dictionary_get_audit_token(xpc_object_t object,audit_token_t* token) {
    require_dict(object);token->pid=object.pid;token->uid=object.uid;
}
static uid_t audit_token_to_euid(audit_token_t token) { return token.uid; }
static pid_t audit_token_to_pid(audit_token_t token) { return token.pid; }
static int xpc_pipe_routine_reply(xpc_object_t reply) { require_dict(reply);++replyCalls;return 0; }
static pid_t proc_get_ppid(pid_t pid) { assert(pid>0);return fakeParent; }
static int proc_patch_csflags(pid_t pid) { ++patchCalls;return patchResult; }
static int proc_fix_spinlock(pid_t pid) { ++spinCalls;return spinResult; }
static int roothide_patch_proc_ex(pid_t pid,bool force) { ++patchCalls;return patchResult; }
static int test_kill(pid_t pid,int sig) { assert(pid>0 && sig==SIGCONT);++signalCalls;return 0; }
#define kill test_kill
static int spawnExecPatchAdd(pid_t pid,bool resume) { return 0; }
static int spawnExecPatchDel(pid_t pid) { return 0; }
static int execTraceProcess(pid_t pid,uint64_t ptr) { ++traceCalls;return 0; }
static int execTraceCancel(pid_t pid,uint64_t ptr) { return 0; }
static void test_dispatch_async(dispatch_queue_t queue,void (^block)(void)) { block(); }
#define dispatch_async test_dispatch_async
static void reset_message(uint64_t messageId) {
    incoming=[TestXPC new];incoming.kind=XPC_TYPE_DICTIONARY;incoming.idKind=XPC_TYPE_UINT64;
    incoming.messageId=messageId;incoming.pid=50;incoming.uid=501;incoming.requestedPid=80;
    lastReply=nil;receiveError=dictionaryCalls=patchCalls=spinCalls=replyCalls=signalCalls=traceCalls=0;
    fakeParent=50;patchResult=spinResult=0;
}
'''

XPC_MAIN = r'''
int main(void) { @autoreleasepool {
    reset_message(102);incoming=nil;jailbreakd_received_message(1);assert(!dictionaryCalls && !replyCalls);
    reset_message(102);incoming.kind=XPC_TYPE_ARRAY;jailbreakd_received_message(1);assert(!dictionaryCalls);
    reset_message(102);receiveError=EIO;jailbreakd_received_message(1);assert(!dictionaryCalls);
    reset_message(102);incoming.idKind=0;jailbreakd_received_message(1);assert(!replyCalls);
    reset_message(102);incoming.idKind=XPC_TYPE_INT64;jailbreakd_received_message(1);assert(!replyCalls);
    reset_message(102);incoming.noReply=YES;jailbreakd_received_message(1);assert(!replyCalls);
    reset_message(102);jailbreakd_received_message(1);assert(replyCalls==1 && lastReply.result==0);
    reset_message(999999);jailbreakd_received_message(1);assert(lastReply.result==-ENOTSUP);
    reset_message((UINT64_C(1)<<32)|102);jailbreakd_received_message(1);assert(lastReply.result==-EINVAL);
    reset_message(102);incoming.pid=0;jailbreakd_received_message(1);assert(lastReply.result==-EINVAL);
    int64_t pids[]={INT64_MIN,-1,0,(int64_t)INT_MAX+1,INT64_MAX};
    int ids[]={JBD_MSG_SPAWN_PATCH_CHILD,JBD_MSG_SPINLOCK_FIX_ONLY};
    for(int i=0;i<2;i++)for(int j=0;j<5;j++) {
        reset_message(ids[i]);incoming.requestedPid=pids[j];jailbreakd_received_message(1);
        assert(lastReply.result==-EINVAL && !patchCalls && !spinCalls && !signalCalls);
    }
    for(int i=0;i<2;i++)for(int resume=0;resume<2;resume++) {
        reset_message(ids[i]);incoming.resume=resume;jailbreakd_received_message(1);
        assert(replyCalls==1 && lastReply.result==0 && patchCalls+spinCalls==1 && signalCalls==resume);
        reset_message(ids[i]);fakeParent=51;jailbreakd_received_message(1);
        assert(lastReply.result==-1 && !patchCalls && !spinCalls);
        reset_message(ids[i]);patchResult=spinResult=-1;incoming.resume=YES;jailbreakd_received_message(1);
        assert(lastReply.result==-1 && !signalCalls);
    }
    int64_t values[]={INT64_MIN,INT64_MIN/2,-1,0,1,INT64_MAX/2,INT64_MAX};
    for(int i=0;i<7;i++) {
        reset_message(101);incoming.value=values[i];jailbreakd_received_message(1);
        int64_t expected=values[i]>INT64_MAX/2 || values[i]<INT64_MIN/2 ? -1 : values[i]*2;
        assert(lastReply.resultSet && lastReply.result==expected);
    }
    reset_message(JBD_MSG_EXEC_TRACE_START);jailbreakd_received_message(1);
    assert(traceCalls==1 && replyCalls==1);
    puts("PASS: actual jailbreakd handler; malformed XPC, PID range, logging, reply and error paths");
} return 0; }
'''

PATH_MOCKS = r'''
static const char* executable="/jb/Applications/Test.app/Test";
static BOOL apiMissing, pathMissing;
static char* proc_get_path(pid_t pid,char* buffer) { if(!executable)return NULL;strlcpy(buffer,executable,PATH_MAX);return buffer; }
static NSString* rcRootfsPath(NSString* path) {
    if(apiMissing)return nil;
    if([path hasPrefix:@"/jb/"])return [path substringFromIndex:3];
    return [@"/rootfs" stringByAppendingString:path];
}
static NSString* rcJbrootPath(NSString* path) { return apiMissing ? nil : [@"/jb" stringByAppendingString:path]; }
static char* test_realpath(const char* path,char* out) {
    if(pathMissing){errno=ENOENT;return NULL;}strlcpy(out,path,PATH_MAX);return out;
}
#define realpath test_realpath
'''
PATH_MAIN = r'''
int main(void) { @autoreleasepool {
    NSSet* paths=[NSSet setWithArray:@[@"/var/mobile/Library",@"/jb/Applications/Test.app"]];
    assert(fixAllowedPaths(0,paths)==paths);
    assert(fixAllowedPaths(50,nil)==nil);
    executable=NULL;assert(fixAllowedPaths(50,paths)==paths);
    executable="/System/Library/Test";assert(fixAllowedPaths(50,paths)==paths);
    executable="/jb/Applications/Test.app/Test";
    apiMissing=YES;assert(fixAllowedPaths(50,paths)==paths);apiMissing=NO;
    NSSet* output=fixAllowedPaths(50,paths);
    assert(([output isEqualToSet:[NSSet setWithArray:@[@"/jb/var/mobile/Library",@"/jb/Applications/Test.app"]]]));
    pathMissing=YES;assert([fixAllowedPaths(50,paths) isEqualToSet:paths]);pathMissing=NO;
    NSSet* malformed=[NSSet setWithObject:@42];assert(fixAllowedPaths(50,malformed)==malformed);
    puts("PASS: actual RunningBoard path function; normal/JB apps, missing API, unresolved paths");
} return 0; }
'''

UT_PREFIX = r'''
static __thread BOOL g_utrHide=NO;
static __thread int g_utrBusy=0;
static BOOL blacklist=YES, raiseException, nest;
static int calls;
static BOOL utrHideClientBlacklisted(id client) { return blacklist; }
static pid_t utrClientPid(id client) { return 50; }
static BOOL utrFilterActive(void) { return g_utrHide && !g_utrBusy; }
@interface ReadClient : NSObject
-(void)getTypeRecordsWithIdentifiers:(id)identifiers completionHandler:(void(^)(id))handler;
@end
static void original_request(ReadClient* client,id ids,void(^handler)(id)) {
    ++calls;
    if(raiseException) [NSException raise:@"test" format:@"test"];
    if(nest) { nest=NO;[client getTypeRecordsWithIdentifiers:ids completionHandler:handler];assert(g_utrHide); }
    if(handler)handler(ids);
}
@implementation ReadClient
'''
UT_MAIN = r'''
@end
int main(void) { @autoreleasepool {
    ReadClient* client=[ReadClient new];
    __block int callbacks=0;
    [client getTypeRecordsWithIdentifiers:@[] completionHandler:^(id value){++callbacks;assert(utrFilterActive());}];
    assert(calls==1 && callbacks==1 && !g_utrHide);
    nest=YES;[client getTypeRecordsWithIdentifiers:@[] completionHandler:nil];assert(calls==3 && !g_utrHide);
    g_utrHide=YES;[client getTypeRecordsWithIdentifiers:@[] completionHandler:nil];assert(g_utrHide);g_utrHide=NO;
    raiseException=YES;
    @try { [client getTypeRecordsWithIdentifiers:@[] completionHandler:nil];assert(!"expected exception"); }
    @catch(NSException* e) { assert(!g_utrHide); }
    raiseException=NO;blacklist=NO;
    [client getTypeRecordsWithIdentifiers:@[] completionHandler:^(id value){assert(!utrFilterActive());}];
    g_utrHide=YES;g_utrBusy=1;assert(!utrFilterActive());g_utrBusy=0;assert(utrFilterActive());
    puts("PASS: actual UTType request wrapper; nested calls, exception cleanup, blacklist isolation");
} return 0; }
'''

def native_tests():
    clang=shutil.which('clang')
    if not clang: raise SystemExit('--native requires macOS clang/Foundation; no native tests run')
    server=source('BaseBin/jailbreakd/src/server.m')
    enum=extract(source('BaseBin/libjailbreak/src/roothider/jailbreakd.h'),'typedef enum')+' JBD_MESSAGE_ID;'
    method=extract(source('BaseBin/roothidehooks/lsd.x'),'- (void)getTypeRecordsWithIdentifiers:')
    method=method.replace('%orig;', 'original_request(self, identifiers, handler);')
    programs={
        'xpc': NATIVE_PREFIX+enum+XPC_MOCKS+extract(server,'void jailbreakd_reply_message')+extract(server,'void jailbreakd_received_message')+XPC_MAIN,
        'paths': NATIVE_PREFIX+PATH_MOCKS+extract(source('BaseBin/roothidehooks/runningboardd.x'),'static NSSet<NSString*>* fixAllowedPaths')+PATH_MAIN,
        'uttype': NATIVE_PREFIX+UT_PREFIX+method+UT_MAIN,
    }
    # Foundation imports real XPC/Mach declarations. Namespace only the fixture
    # and extracted function tokens after those imports, not the SDK headers.
    xpc_body = programs['xpc'][len(NATIVE_PREFIX):]
    xpc_body = re.sub(r'\b(?:xpc_[A-Za-z_0-9]+|XPC_TYPE_[A-Z_0-9]+|mach_port_t|audit_token_t|audit_token_to_[a-z]+)\b',
                      lambda match: 'test_' + match.group(0), xpc_body)
    programs['xpc'] = NATIVE_PREFIX + xpc_body
    with tempfile.TemporaryDirectory(prefix='rc9-services-') as temp:
        for name,program in programs.items():
            path=Path(temp)/f'{name}.m';binary=Path(temp)/name
            path.write_text(program,encoding='utf-8')
            subprocess.run([clang,'-fobjc-arc','-fblocks','-framework','Foundation','-Wall','-Wextra','-Werror',
                '-Wno-unused-parameter','-Wno-unused-function','-Wno-unused-variable','-O1','-g',
                '-fsanitize=address,undefined',str(path),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--native',action='store_true')
    args=parser.parse_args()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ServiceContracts))
    if not result.wasSuccessful():raise SystemExit(1)
    if args.native:native_tests()
    else:print('Source checks only; --native runs production functions against mocked OS/XPC on macOS.')
