#!/usr/bin/env python3
"""Host-only mock of the production READY liveness check; no Apple SDK."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'BaseBin/libjailbreak/src/roothider/jailbreakd.c').read_text()

def extract(signature):
    start = source.index(signature)
    left = source.index('{', start)
    depth = 0
    for pos in range(left, len(source)):
        if source[pos] == '{':
            depth += 1
        elif source[pos] == '}':
            depth -= 1
            if not depth:
                return source[start:pos + 1]
    raise AssertionError(signature)

production = '\n\n'.join(extract(name) for name in (
    'static int destroyLocalJailbreakdServerPortLocked(void)',
    'static void advanceJailbreakdPortGenerationLocked(void)',
    'static void jailbreakdReadyLivenessTick(uint64_t generation)',
))

mock = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sys/types.h>
typedef unsigned int mach_port_t;
typedef unsigned int mach_port_type_t;
typedef int kern_return_t;
#define MACH_PORT_NULL 0
#define MACH_PORT_VALID(p) ((p) != 0)
#define MACH_PORT_TYPE_SEND 0x10000U
#define MACH_PORT_TYPE_DEAD_NAME 0x100000U
#define KERN_SUCCESS 0
#define KERN_INVALID_NAME 15
#define HOST_LAUNCHCTL_PORT 9
#define JAILBREAKD_CLIENT_PORT_FAST_GET
#define getpid() (1)
#define JBLogError(...) do {} while(0)
#define roothide_stage_log(...) do {} while(0)
static bool __jailbreakd_initialized = true;
static bool __jailbreakd_port_ready = true;
static bool __jailbreakd_port_published = true;
static pthread_mutex_t __jailbreakd_port_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t __jailbreakd_port_generation = 40;
static pid_t __jailbreakd_expected_pid = 0;
static bool __jailbreakd_candidate_pending = false;
static bool __jailbreakd_checkin_in_progress = false;
static char __jailbreakd_checkin_token[33] = {0};
static pid_t __jailbreakd_ready_pid = 123;
static uint64_t __jailbreakd_ready_generation = 40;
static char __jailbreakd_ready_token[33] = "0123456789abcdef0123456789abcdef";
static mach_port_t gJailbreakdPort = 500;
static kern_return_t simulated_error = 0;
static mach_port_type_t simulated_type = MACH_PORT_TYPE_SEND;
static unsigned probes, revokes, destroys, kills, reschedules;
static pid_t killed_pid;
static mach_port_t mach_host_self(void) { return 66; }
static mach_port_t mach_task_self(void) { return 22; }
static kern_return_t mach_port_deallocate(mach_port_t task, mach_port_t port)
{ (void)task; (void)port; return KERN_SUCCESS; }
static kern_return_t host_set_special_port(mach_port_t host, int slot, mach_port_t port)
{ assert(host == 66 && slot == HOST_LAUNCHCTL_PORT && port == 0); ++revokes; return KERN_SUCCESS; }
static kern_return_t mach_port_destroy(mach_port_t task, mach_port_t port)
{ assert(task == 22 && port == gJailbreakdPort); ++destroys; return KERN_SUCCESS; }
static kern_return_t mach_port_type(mach_port_t task, mach_port_t port, mach_port_type_t *type)
{ assert(task == 22 && port == gJailbreakdPort); ++probes; *type = simulated_type; return simulated_error; }
static const char *mach_error_string(kern_return_t kr)
{ (void)kr; return "mock"; }
static void terminateJailbreakdChild(pid_t pid)
{ if (pid > 1) { ++kills; killed_pid = pid; } }
static void scheduleJailbreakdReadyLivenessWatchdog(uint64_t generation)
{ assert(generation == __jailbreakd_port_generation); ++reschedules; }

/* PRODUCTION */

int main(void)
{
    jailbreakdReadyLivenessTick(39);
    assert(probes == 0 && reschedules == 0);
    jailbreakdReadyLivenessTick(40);
    assert(probes == 1 && reschedules == 1 && __jailbreakd_port_ready);
    puts("LIVE_RIGHT=PASS");

    simulated_error = 999;
    jailbreakdReadyLivenessTick(40);
    assert(probes == 2 && reschedules == 2 && destroys == 0);
    puts("TRANSIENT_MACH_ERROR=PASS");

    simulated_error = 0;
    simulated_type = MACH_PORT_TYPE_DEAD_NAME;
    jailbreakdReadyLivenessTick(40);
    assert(probes == 3 && reschedules == 2);
    assert(destroys == 1 && revokes == 1 && kills == 1 && killed_pid == 123);
    assert(!__jailbreakd_port_ready && !__jailbreakd_port_published);
    assert(__jailbreakd_ready_pid == 0 && __jailbreakd_ready_generation == 0);
    assert(__jailbreakd_ready_token[0] == 0 && gJailbreakdPort == 0);
    assert(__jailbreakd_port_generation == 41);
    puts("DEAD_RIGHT_REVOKED=PASS");

    jailbreakdReadyLivenessTick(40);
    assert(probes == 3 && destroys == 1 && kills == 1);
    puts("STALE_GENERATION_NOOP=PASS");

    __jailbreakd_port_ready = true;
    __jailbreakd_port_published = true;
    __jailbreakd_ready_pid = 124;
    __jailbreakd_ready_generation = 41;
    strcpy(__jailbreakd_ready_token, "0123456789abcdef0123456789abcdef");
    gJailbreakdPort = 600;
    simulated_error = KERN_INVALID_NAME;
    jailbreakdReadyLivenessTick(41);
    assert(destroys == 2 && revokes == 2 && kills == 2 && killed_pid == 124);
    assert(__jailbreakd_port_generation == 42);
    puts("INVALID_NAME_REVOKED=PASS");

    __jailbreakd_candidate_pending = true;
    gJailbreakdPort = 700;
    jailbreakdReadyLivenessTick(42);
    assert(destroys == 2 && probes == 4);
    puts("PENDING_CANDIDATE_UNTOUCHED=PASS");
    puts("READY_LIVENESS_HOST_TESTS=PASS");
    return 0;
}
'''
code = mock.replace('/* PRODUCTION */', production)
with tempfile.TemporaryDirectory(prefix='p0_ready_liveness_') as directory:
    src = Path(directory) / 'test.c'
    exe = Path(directory) / 'test'
    src.write_text(code)
    subprocess.run(['clang', '-std=c11', '-D_DEFAULT_SOURCE', '-Wall', '-Wextra',
                    '-Werror', '-Wno-unused-function', '-Wno-unused-but-set-variable', '-fsanitize=address,undefined',
                    '-pthread', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
