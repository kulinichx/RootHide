#!/usr/bin/env python3
"""Portable host checks against the *extracted production* P0 RPC patch code.

Uses mocked XPC / patch / kill, without loading Apple frameworks.  Passing
here does NOT establish timeout guarantees, READY cleanup, or A16 safety.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def extract_function(source, signature):
    offset = source.index(signature)
    opening = source.index('{', offset)
    depth = 0
    for i in range(opening, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[offset:i + 1]
    raise ValueError('unterminated function ' + signature)


def compile_run(source, tag):
    with tempfile.TemporaryDirectory(prefix='p0_rpc_') as td:
        c_file = Path(td) / (tag + '.c')
        program = Path(td) / tag
        c_file.write_text(source)
        subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', str(c_file), '-o', str(program)],
                       check=True)
        subprocess.run([str(program)], check=True)


server = (ROOT / 'BaseBin/jailbreakd/src/server.m').read_text()
pid_fn = extract_function(server, 'static bool jailbreakd_get_child_pid(')
spawn_helper = extract_function(server, 'static int64_t jailbreakd_patch_spawn_child(')
spawn_case = server[server.index('case JBD_MSG_SPAWN_PATCH_CHILD: {'):
                    server.index('case JBD_MSG_SPAWN_EXEC_START: {')]
# The production patch runs on a dedicated serial queue. Test its exact
# worker logic as C and separately check the dispatch/ownership wiring.
assert 'dispatch_async(patchQueue, ^{' in spawn_case
assert 'reply = nil;' in spawn_case
assert 'jailbreakd_reply_message(msgId, asyncReply);' in spawn_case
assert 'xpc_release(asyncReply);' in spawn_case
assert 'jailbreakd_patch_spawn_child(clientPid, pid, resume, forceDyldPatch)' in spawn_case
assert 'DISPATCH_QUEUE_SERIAL' in server

server_test = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <sys/types.h>
#include <string.h>

enum { XPC_TYPE_DICTIONARY=1, XPC_TYPE_INT64=2, XPC_TYPE_UINT64=3, XPC_TYPE_STRING=4 };
enum { JBD_MSG_SPAWN_PATCH_CHILD=1001 };
typedef struct FakeXpc {
    int type;
    int64_t int_pid;
    uint64_t uint_pid;
    bool resume;
    bool force;
    int64_t result;
    struct FakeXpc *pid_value;
} *xpc_object_t;
static xpc_object_t xpc_dictionary_get_value(xpc_object_t message, const char *key) {
    assert(strcmp(key, "pid") == 0); return message->pid_value;
}
static int xpc_get_type(xpc_object_t value) { return value->type; }
static int64_t xpc_dictionary_get_int64(xpc_object_t value, const char *key) {
    assert(strcmp(key, "pid") == 0); return value->pid_value->int_pid;
}
static uint64_t xpc_dictionary_get_uint64(xpc_object_t value, const char *key) {
    assert(strcmp(key, "pid") == 0); return value->pid_value->uint_pid;
}
static bool xpc_dictionary_get_bool(xpc_object_t value, const char *key) {
    if (strcmp(key, "resume") == 0) return value->resume;
    assert(strcmp(key, "force-dyld-patch") == 0); return value->force;
}
static pid_t parent_result=400;
static int patch_result=0;
static int csflags_result=0;
static int fail_resume=0;
static int patched=0;
static int resumed=0;
static int queried_parent=0;
static pid_t proc_get_ppid(pid_t pid) {
    assert(pid > 1); ++queried_parent; return parent_result;
}
static int roothide_patch_proc_ex(pid_t pid, bool force) {
    assert(pid > 1); (void)force; ++patched; return patch_result;
}
static int proc_patch_csflags(pid_t pid) { assert(pid > 1); return csflags_result; }
static int fake_kill(pid_t pid, int sig) {
    assert(pid > 1 && sig == SIGCONT); ++resumed;
    if (fail_resume) { errno=ESRCH; return -1; } return 0;
}
#define kill fake_kill
#define JBLogDebug(...) ((void)0)
#define JBLogError(...) ((void)0)
static void roothide_stage_log(const char *fmt, ...) { (void)fmt; }
/* INSERT_PID_FUNCTION */
/* INSERT_SPAWN_HELPER */
static int64_t call_spawn(xpc_object_t message, pid_t clientPid) {
    pid_t pid = 0;
    if (!jailbreakd_get_child_pid(message, &pid)) return -1;
    return jailbreakd_patch_spawn_child(clientPid, pid,
        xpc_dictionary_get_bool(message, "resume"),
        xpc_dictionary_get_bool(message, "force-dyld-patch"));
}
static void reset(void) {
    parent_result=400; patch_result=0; csflags_result=0;
    fail_resume=0; patched=0; resumed=0; queried_parent=0;
}
int main(void) {
    struct FakeXpc value={.type=XPC_TYPE_INT64,.int_pid=450};
    struct FakeXpc msg={.type=XPC_TYPE_DICTIONARY,.resume=true,.pid_value=&value};
    reset(); assert(call_spawn(&msg,400)==0 && patched==1 && resumed==1);
    puts("SPAWN_PATCH_AND_RESUME=PASS");
    reset(); fail_resume=1;
    assert(call_spawn(&msg,400)==-1 && patched==1 && resumed==1);
    puts("SPAWN_RESUME_FAILURE_PROPAGATED=PASS");
    reset(); patch_result=-1;
    assert(call_spawn(&msg,400)==-1 && patched==1 && resumed==0);
    puts("SPAWN_PATCH_FAILURE_PROPAGATED=PASS");
    reset(); parent_result=399;
    assert(call_spawn(&msg,400)==-1 && patched==0 && resumed==0);
    puts("SPAWN_UNRELATED_PARENT_DENIED=PASS");
    reset(); value.int_pid=-1;
    assert(call_spawn(&msg,400)==-1 && queried_parent==0 && patched==0);
    puts("SPAWN_NEGATIVE_PID_DENIED=PASS");
    reset(); value.int_pid=(int64_t)INT_MAX+1;
    assert(call_spawn(&msg,400)==-1 && queried_parent==0 && patched==0);
    puts("SPAWN_OVERFLOW_PID_DENIED=PASS");
    reset(); value.type=XPC_TYPE_STRING;
    assert(call_spawn(&msg,400)==-1 && queried_parent==0);
    puts("SPAWN_WRONG_TYPE_DENIED=PASS");
    reset(); value.type=XPC_TYPE_UINT64; value.uint_pid=450;
    assert(call_spawn(&msg,400)==0 && patched==1 && resumed==1);
    puts("SPAWN_UINT64_COMPAT=PASS");
    reset(); value.uint_pid=(uint64_t)UINT32_MAX+1;
    assert(call_spawn(&msg,400)==-1 && queried_parent==0);
    puts("SPAWN_UINT_OVERFLOW_DENIED=PASS");
    reset(); value.type=XPC_TYPE_INT64; value.int_pid=450;
    msg.resume=false; parent_result=1;
    assert(call_spawn(&msg,1)==0 && patched==0 && resumed==0);
    puts("SPAWN_LAUNCHD_NO_RESUME_COMPAT=PASS");
    return 0;
}
'''
compile_run(server_test.replace('/* INSERT_PID_FUNCTION */', pid_fn)
           .replace('/* INSERT_SPAWN_HELPER */', spawn_helper), 'server_spawn')

client = (ROOT / 'BaseBin/libjailbreak/src/jbclient_xpc.c').read_text()
send_dict_fn = extract_function(client, 'xpc_object_t jbserver_xpc_send_dict(')
send_fn = extract_function(client, 'xpc_object_t jbserver_xpc_send(')

client_test = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

typedef int mach_port_t;
#define MACH_PORT_NULL 0
#define OS_ALLOC_ONCE_KEY_LIBXPC 5
#define XPC_TYPE_DICTIONARY 1
#define XPC_TYPE_ERROR 2
typedef struct MockObject { int type, releases, retains; } *xpc_object_t;
struct xpc_global_data {
    uint64_t a,xpc_flags;
    mach_port_t task_bootstrap_port;
    xpc_object_t xpc_bootstrap_pipe;
};
static struct xpc_global_data gd;
static int fail_alloc, fail_pipe, transport_error, reply_type, give_reply, routine_count;
static int reply_release_count, pipe_release_count;
static mach_port_t gJBServerCustomPort=87;
static struct MockObject request_obj={XPC_TYPE_DICTIONARY,0,0};
static struct MockObject error_obj={XPC_TYPE_ERROR,0,0};
static struct MockObject pipe_obj={XPC_TYPE_DICTIONARY,0,0};
static struct MockObject reply_obj={XPC_TYPE_DICTIONARY,0,0};
static void roothide_stage_log(const char *format, ...) { (void)format; }
static int xpc_get_type(xpc_object_t x) { return x->type; }
static uint64_t xpc_dictionary_get_uint64(xpc_object_t obj, const char *key) {
    (void)obj; (void)key; return 0;
}
static void xpc_dictionary_set_uint64(xpc_object_t obj, const char *key, uint64_t value) {
    assert(obj->type==XPC_TYPE_DICTIONARY); (void)key; (void)value;
}
static xpc_object_t xpc_dictionary_create_empty(void) {
    return fail_alloc ? NULL : &request_obj;
}
static xpc_object_t xpc_pipe_create_from_port(mach_port_t port, int flags) {
    (void)port; (void)flags; return fail_pipe ? NULL : &pipe_obj;
}
static void *os_alloc_once(int key, int size, void *arg) {
    (void)key; (void)size; (void)arg; return &gd;
}
static mach_port_t jbclient_mach_get_launchd_port(void) { return 99; }
static xpc_object_t xpc_retain(xpc_object_t obj) { ++obj->retains; return obj; }
static void xpc_release(xpc_object_t obj) {
    assert(obj); ++obj->releases;
    if (obj==&reply_obj) ++reply_release_count;
    if (obj==&pipe_obj) ++pipe_release_count;
}
static int xpc_pipe_routine_with_flags(xpc_object_t pipe, xpc_object_t request,
                                       xpc_object_t *out, uint64_t flags) {
    assert(pipe==&pipe_obj && request && flags==0);
    ++routine_count;
    reply_obj.type=reply_type;
    *out=give_reply?&reply_obj:NULL;
    return transport_error;
}
/* INSERT_SEND_DICT */
/* INSERT_SEND */
static void reset(void) {
    transport_error=0; reply_type=XPC_TYPE_DICTIONARY;
    give_reply=1; fail_pipe=0; fail_alloc=0;
    reply_release_count=0; pipe_release_count=0; routine_count=0;
}
int main(void) {
    reset(); assert(jbserver_xpc_send_dict(&request_obj)==&reply_obj);
    assert(reply_release_count==0 && pipe_release_count==1);
    xpc_release(&reply_obj);
    puts("CLIENT_VALID_REPLY=PASS");
    reset(); transport_error=42;
    assert(jbserver_xpc_send_dict(&request_obj)==NULL);
    assert(reply_release_count==1 && pipe_release_count==1);
    puts("CLIENT_ERROR_OWNED_REPLY_RELEASED=PASS");
    reset(); reply_type=XPC_TYPE_ERROR;
    assert(jbserver_xpc_send_dict(&request_obj)==NULL);
    assert(reply_release_count==1 && pipe_release_count==1);
    puts("CLIENT_INVALID_REPLY_REJECTED=PASS");
    reset(); give_reply=0;
    assert(jbserver_xpc_send_dict(&request_obj)==NULL && pipe_release_count==1);
    puts("CLIENT_MISSING_REPLY=PASS");
    reset(); fail_pipe=1;
    assert(jbserver_xpc_send_dict(&request_obj)==NULL && routine_count==0);
    puts("CLIENT_PIPE_FAILURE=PASS");
    reset(); assert(jbserver_xpc_send_dict(&error_obj)==NULL && routine_count==0);
    puts("CLIENT_BAD_ARGUMENT_TYPE_DENIED=PASS");
    reset(); fail_alloc=1;
    assert(jbserver_xpc_send(7,10,NULL)==NULL && routine_count==0);
    puts("CLIENT_ALLOC_FAILURE=PASS");
    reset(); assert(jbserver_xpc_send(7,10,&request_obj)==&reply_obj);
    assert(routine_count==1);
    puts("CLIENT_SEND_WRAPPER=PASS");
    return 0;
}
'''
compile_run(client_test.replace('/* INSERT_SEND_DICT */', send_dict_fn)
            .replace('/* INSERT_SEND */', send_fn), 'client_xpc')
print('P0_RPC_HOST_SOURCE_EXTRACTED_TESTS=PASS (mock transport; NOT iOS or timeout proof)')
