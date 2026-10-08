#!/usr/bin/env python3
"""Syntax-check production jailbreakd/server.m against minimal POSIX/XPC mocks.

Not a substitute for an Apple SDK or iOS link/build; checks Objective-C Blocks
syntax and local types without depending on Foundation in the host container.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
source = (root / 'BaseBin/jailbreakd/src/server.m').read_text()
source = '\n'.join(line for line in source.splitlines() if not line.startswith('#include '))
preamble = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#define nil ((void *)0)
#define JBLogDebug(...) ((void)0)
#define JBLogError(...) ((void)0)
#define XPC_TYPE_DICTIONARY ((const void*)1)
#define XPC_TYPE_INT64 ((const void*)2)
#define XPC_TYPE_UINT64 ((const void*)3)
typedef void *xpc_object_t;
typedef unsigned int mach_port_t;
typedef uint64_t JBD_MESSAGE_ID;
typedef struct { unsigned int val[8]; } audit_token_t;
typedef void *dispatch_queue_t;
typedef long dispatch_once_t;
#define DISPATCH_QUEUE_SERIAL ((void*)0)
#define JBD_MSG_SPINLOCK_FIX_ONLY 1000
#define JBD_MSG_SPAWN_PATCH_CHILD 1001
#define JBD_MSG_SPAWN_EXEC_START 1002
#define JBD_MSG_SPAWN_EXEC_CANCEL 1003
#define JBD_MSG_EXEC_TRACE_START 1004
#define JBD_MSG_EXEC_TRACE_CANCEL 1005
#define JBD_MSG_SYSTEMWIDE_LOG 1006
#define JBD_MSG_TEST_CALL 1007
int xpc_pipe_routine_reply(xpc_object_t);
int xpc_pipe_receive(mach_port_t, xpc_object_t*);
xpc_object_t xpc_dictionary_create_reply(xpc_object_t);
xpc_object_t xpc_dictionary_get_value(xpc_object_t,const char*);
const void* xpc_get_type(xpc_object_t);
int64_t xpc_dictionary_get_int64(xpc_object_t,const char*);
uint64_t xpc_dictionary_get_uint64(xpc_object_t,const char*);
bool xpc_dictionary_get_bool(xpc_object_t,const char*);
const char* xpc_dictionary_get_string(xpc_object_t,const char*);
void xpc_dictionary_get_audit_token(xpc_object_t,audit_token_t*);
void xpc_dictionary_set_int64(xpc_object_t,const char*,int64_t);
xpc_object_t xpc_retain(xpc_object_t);
void xpc_release(xpc_object_t);
char* xpc_copy_description(xpc_object_t);
uid_t audit_token_to_euid(audit_token_t);
pid_t audit_token_to_pid(audit_token_t);
const char* proc_get_path(pid_t,void*);
pid_t proc_get_ppid(pid_t);
int proc_patch_csflags(pid_t);
int proc_fix_spinlock(pid_t);
int roothide_patch_proc_ex(pid_t,bool);
int spawnExecPatchAdd(pid_t,bool);
int spawnExecPatchDel(pid_t);
int execTraceProcess(pid_t,uint64_t);
int execTraceCancel(pid_t,uint64_t);
void roothide_stage_log(const char*,...);
dispatch_queue_t dispatch_queue_create(const char*, void*);
void dispatch_once(dispatch_once_t*, void (^)(void));
void dispatch_async(dispatch_queue_t, void (^)(void));
dispatch_queue_t dispatch_get_global_queue(long,unsigned long);
'''
subprocess.run(['clang','-x','objective-c','-fblocks','-std=gnu11',
                '-Werror','-Wno-unused-variable','-Wno-unused-function',
                '-Wno-format','-fsyntax-only','-'], input=preamble+'\n'+source,
               text=True,check=True)
print('SERVER_M_OBJC_BLOCKS_HOST_SYNTAX=PASS (mock declarations, not Apple SDK)')
