#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JBD_PATH = ROOT / "BaseBin/libjailbreak/src/roothider/jailbreakd.c"
DOMAIN_PATH = ROOT / "BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c"
CLIENT_PATH = ROOT / "BaseBin/libjailbreak/src/jbclient_roothide.c"
DAEMON_MAIN_PATH = ROOT / "BaseBin/jailbreakd/src/main.m"
source = JBD_PATH.read_text()
domain_source = DOMAIN_PATH.read_text()
client_source = CLIENT_PATH.read_text()
daemon_main_source = DAEMON_MAIN_PATH.read_text()


def extract_function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise RuntimeError(f"unterminated function: {signature}")


global_start = source.index("static bool __firstLoad = false;")
global_end = source.index("#define JAILBREAKD_CLIENT_PORT_FAST_GET", global_start)
globals_block = source[global_start:global_end]
function_signatures = [
    "static int destroyLocalJailbreakdServerPortLocked(void)",
    "static void advanceJailbreakdPortGenerationLocked(void)",
    "static bool reapJailbreakdChildIfExitedLocked(void)",
    "static void terminateJailbreakdChild(pid_t pid)",
    "int registerServerPort()",
    "int jailbreakdServerPortSetCheckinToken(uint64_t generation, mach_port_t port, const char *token)",
    "int jailbreakdServerPortCheckinBegin(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)",
    "int jailbreakdServerPortCheckinReady(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)",
    "int jailbreakdServerPortCheckinAbort(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)",
    "static bool jailbreakdCheckinTicketMatchesLocked(const jailbreakd_checkin_ticket_t *ticket)",
    "int jailbreakdServerPortCheckinComplete(const jailbreakd_checkin_ticket_t *ticket)",
    "void jailbreakdServerPortCheckinFailed(const jailbreakd_checkin_ticket_t *ticket)",
    "void jailbreakdServerPortAbandonCandidate(uint64_t generation, mach_port_t port)",
    "static void jailbreakdServerPortCheckinTimedOut(uint64_t generation)",
    "mach_port_t jailbreakdClientPortFastGet()",
    "int initJailbreakd(bool firstLoad)",
    "mach_port_t reactiveJailbreakdPort()",
    "mach_port_t jailbreakdServerPort()",
    "mach_port_t jailbreakdClientPort()",
    "void setJailbreakdProcess(pid_t pid)",
]
functions = "\n\n".join(extract_function(source, signature) for signature in function_signatures)
respawn_cleanup = extract_function(daemon_main_source, "static void terminateRespawnedJailbreakdChild(pid_t pid)")
respawn_delayed_reaper = extract_function(daemon_main_source, "static void scheduleRespawnedJailbreakdChildReap(pid_t pid, unsigned int retriesRemaining)")
respawn_attributes = extract_function(daemon_main_source, "static int initializeRespawnedJailbreakdAttributes(")
bootstrap_port_setup = extract_function(source, "static kern_return_t prepareJailbreakdBootstrapPort(")
deferred_parent_reaper = extract_function(source, "static void scheduleJailbreakdParentReap(")
functions += "\n\n" + respawn_cleanup + "\n\n" + respawn_attributes + "\n\n" + bootstrap_port_setup
checkin = extract_function(domain_source, "static int roothide_jailbreakd_checkin(")
lookup = extract_function(domain_source, "static int roothide_jailbreakd_lookup(")

# Check-in returns the receive right but cannot publish readiness; only the
# authenticated post-dispatch acknowledgement may complete the candidate.
begin_at = checkin.index("jailbreakdServerPortCheckinBegin(pid, checkinToken, &ticket)")
recv_create_at = checkin.index("*portOut = xpc_mach_recv_create(port);")
recv_failure_at = checkin.index("if (!*portOut)", recv_create_at)
assert begin_at < recv_create_at < recv_failure_at
assert "jailbreakdServerPortCheckinFailed(&ticket);" in checkin[recv_failure_at:]
assert "jailbreakdServerPortCheckinComplete" not in checkin
assert "setJailbreakdProcess" not in checkin
ready_handler = extract_function(domain_source, "static int roothide_jailbreakd_ready(")
abort_validate_at = ready_handler.index("jailbreakdServerPortCheckinAbort(pid, checkinToken, &ticket)")
abort_cleanup_at = ready_handler.index("jailbreakdServerPortCheckinFailed(&ticket)", abort_validate_at)
ready_validate_at = ready_handler.index("jailbreakdServerPortCheckinReady(pid, checkinToken, &ticket)")
assert abort_validate_at < abort_cleanup_at < ready_validate_at
assert "bool ready" in ready_handler
ready_complete_at = ready_handler.index("jailbreakdServerPortCheckinComplete(&ticket)")
ready_publish_at = ready_handler.index("setJailbreakdProcess(pid)")
assert ready_validate_at < ready_complete_at < ready_publish_at
assert "audit_token_to_pid(*callerToken)" in ready_handler
assert "JBS_ROOTHIDE_JAILBREAKD_READY = 10" in (ROOT / "BaseBin/libjailbreak/src/jbserver_domains.h").read_text()
domain_table = domain_source[domain_source.index("struct jbserver_domain gRootHideDomain"):]
assert domain_table.index(".handler = roothide_set_dyld_patch") < domain_table.index(".handler = roothide_jailbreakd_ready") < domain_table.rfind("\t\t{ 0 },")
assert '{ .name = "ready", .type = JBS_TYPE_BOOL, .out = false }' in domain_table
assert "MACH_PORT_VALID(port)" in lookup and "xpc_mach_send_create(port)" in lookup
ready_client = extract_function(client_source, "static int jbclient_jailbreakd_report_readiness(bool ready)")
assert "JBS_ROOTHIDE_JAILBREAKD_READY" in ready_client
assert "xpc_dictionary_set_bool(xargs, \"ready\", ready)" in ready_client
assert "unsetenv(\"JAILBREAKD_CHECKIN_TOKEN\")" in ready_client
assert "attempt < 2" in ready_client
assert "XPC_TYPE_INT64" in ready_client
assert "jbclient_jailbreakd_checkin_failed" in client_source
server_resume_at = daemon_main_source.index("dispatch_resume(source);")
server_ack_at = daemon_main_source.index("jbclient_jailbreakd_ready()", server_resume_at)
server_main_at = daemon_main_source.index("dispatch_main();", server_resume_at)
assert server_resume_at < server_ack_at < server_main_at
ready_failure_end = daemon_main_source.index("return 9;", server_ack_at)
assert "jbclient_jailbreakd_checkin_failed()" in daemon_main_source[server_ack_at:ready_failure_end]
spawn_start = source.index("int spawnJailbreakd()")
spawn_end = source.index("int initJailbreakd(bool firstLoad)", spawn_start)
spawn_source = source[spawn_start:spawn_end]
assert "scheduleJailbreakdServerPortCheckinWatchdog();" in spawn_source
assert spawn_source.index("if (ret != 0)") < spawn_source.index("scheduleJailbreakdServerPortCheckinWatchdog();")
assert "POSIX_SPAWN_START_SUSPENDED" in spawn_source
assert spawn_source.index("__jailbreakd_expected_pid = pid;") < spawn_source.index("kill(pid, SIGCONT)")
assert "JAILBREAKD_CHECKIN_TOKEN=" in spawn_source
assert "jailbreakdServerPortSetCheckinToken(candidateGeneration, candidatePort, checkinToken)" in spawn_source
assert "__firstLoad && environ" in spawn_source
assert '"checkin-token"' in domain_source
assert 'getenv("JAILBREAKD_CHECKIN_TOKEN")' in client_source
assert 'xpc_dictionary_set_string(xargs, "checkin-token", checkinToken)' in client_source
assert 'posix_spawn(&pid, selfPath, NULL, &attr, argv, environ)' in daemon_main_source
assert 'unsetenv("RESPAWN_REQUIRED")' in daemon_main_source
assert 'unsetenv("JAILBREAKD_CHECKIN_TOKEN")' not in daemon_main_source
respawn_start = daemon_main_source.index('if(getenv("RESPAWN_REQUIRED"))')
checkin_start = daemon_main_source.index('JBLogDebug("check in jailbreakd port...")', respawn_start)
respawn_source = daemon_main_source[respawn_start:checkin_start]
assert "initializeRespawnedJailbreakdAttributes(&attr, bootstraport)" in respawn_source
assert "posix_spawnattr_init(attr)" in respawn_attributes
assert "posix_spawnattr_setflags" in respawn_attributes
assert "posix_spawnattr_set_registered_ports_np" in respawn_attributes
assert respawn_attributes.index("posix_spawnattr_setflags") < respawn_attributes.index("posix_spawnattr_set_registered_ports_np")
assert respawn_attributes.count("posix_spawnattr_destroy(attr)") == 2
assert respawn_source.index("initializeRespawnedJailbreakdAttributes") < respawn_source.index("posix_spawn(&pid")
assert "if(unrestrictResult != 0)" in respawn_source
assert "if (kill(pid, SIGCONT) != 0)" in respawn_source
assert respawn_source.count("terminateRespawnedJailbreakdChild(pid);") == 3
assert "waitpid(pid, &status, WNOHANG)" in respawn_cleanup
assert "waitpid(pid, &status, 0)" not in respawn_cleanup
assert "scheduleRespawnedJailbreakdChildReap(pid, 20)" in respawn_cleanup
assert "dispatch_after" in respawn_delayed_reaper
assert "waitpid(pid, &status, WNOHANG)" in respawn_delayed_reaper
assert "retriesRemaining > 0" in respawn_delayed_reaper
assert "errno != ESRCH" in respawn_cleanup
bootstrap_start = source.index("int spawnJailbreakd()")
bootstrap_end = source.index("	pid_t pid;", bootstrap_start)
bootstrap_setup_source = source[bootstrap_start:bootstrap_end]
assert "if (!bootstrapReady)" in bootstrap_setup_source
assert "dispatch_once" not in bootstrap_setup_source
assert "prepareJailbreakdBootstrapPort(&bootstraport)" in bootstrap_setup_source and "bootstrapError != KERN_SUCCESS" in bootstrap_setup_source
assert "if (!source)" in bootstrap_setup_source
assert "mach_port_destroy(mach_task_self(), bootstraport)" in bootstrap_setup_source
assert bootstrap_setup_source.count("jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);") == 2
assert "MACH_PORT_VALID(*bootstrapPort)" in bootstrap_port_setup
assert "mach_port_allocate" in bootstrap_port_setup and "mach_port_insert_right" in bootstrap_port_setup
assert "waitpid(oldpid, NULL, 0)" not in source
assert "waitpid(child, &status, WNOHANG)" in source
assert "kill(child, 0)" in source
assert "waitpid(oldpid, NULL, WNOHANG)" in source
server_source_start = daemon_main_source.index("dispatch_source_t source = dispatch_source_create(")
server_source_end = daemon_main_source.index("dispatch_source_set_event_handler(source", server_source_start)
server_source_setup = daemon_main_source[server_source_start:server_source_end]
assert "if (!source)" in server_source_setup
assert "mach_port_destroy(mach_task_self(), serverPort)" in server_source_setup
assert "jbclient_jailbreakd_checkin_failed()" in server_source_setup
assert server_source_setup.index("jbclient_jailbreakd_checkin_failed()") < server_source_setup.index("return 8;")
assert "return 8;" in server_source_setup
assert "waitpid(pid, NULL, WNOHANG)" in source
set_process_source = extract_function(source, "void setJailbreakdProcess(pid_t pid)")
assert "strtol(pidenv, &end, 10)" in set_process_source
assert "parsedOldPid <= 1" in set_process_source
assert "waitpid(oldpid, NULL, WNOHANG)" in set_process_source
assert "while (result == -1 && errno == EINTR)" in set_process_source
assert "atoi(pidenv)" not in set_process_source
assert "scheduleJailbreakdParentReap(oldpid, 50)" in set_process_source
assert "dispatch_after" in deferred_parent_reaper
assert "pthread_mutex_lock(&__jailbreakd_process_mutex)" in set_process_source
assert "pthread_mutex_unlock(&__jailbreakd_process_mutex)" in set_process_source
assert "waitpid(pid, &status, WNOHANG)" in deferred_parent_reaper
assert "retriesRemaining > 0" in deferred_parent_reaper
assert "waitpid(pid, &status, 0)" not in deferred_parent_reaper

if "--static-only" in sys.argv[1:]:
    print("PASS: jailbreakd check-in, watchdog, bootstrap, and respawn source contracts")
    raise SystemExit(0)

harness = r'''#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <pthread.h>

typedef uint32_t mach_port_t;
typedef struct fake_spawn_attributes { int flags; } *posix_spawnattr_t;
#define POSIX_SPAWN_START_SUSPENDED 0x0080
typedef struct {
    pid_t pid;
    uint64_t generation;
    mach_port_t port;
} jailbreakd_checkin_ticket_t;
typedef int kern_return_t;
enum {
    KERN_SUCCESS = 0,
    KERN_FAILURE = 5,
    KERN_INVALID_RIGHT = 17,
    MACH_PORT_RIGHT_RECEIVE = 1,
    MACH_PORT_RIGHT_SEND = 2,
    MACH_MSG_TYPE_MAKE_SEND = 20,
    HOST_LOCAL_NODE = 0,
    HOST_LAUNCHCTL_PORT = 4,
};
#define MACH_PORT_NULL ((mach_port_t)0)
#define MACH_PORT_VALID(port) ((port) != MACH_PORT_NULL)
#define JAILBREAKD_CLIENT_PORT_FAST_GET
static void fake_log(const char *format, ...) { (void)format; }
#define JBLogDebug(...) fake_log(__VA_ARGS__)
#define JBLogError(...) fake_log(__VA_ARGS__)
#define roothide_stage_log(...) fake_log(__VA_ARGS__)

/* INJECT_REAL_GLOBALS */

typedef struct {
    bool allocated;
    bool receive;
    bool send;
    bool dead;
    int send_refs;
    int destroy_count;
} fake_port_t;

enum { MAX_FAKE_PORTS = 512 };
static fake_port_t fake_ports[MAX_FAKE_PORTS];
static mach_port_t next_port = 100;
static mach_port_t host_special_port = MACH_PORT_NULL;
static bool fail_allocate;
static bool fail_insert_right;
static bool fail_host_set;
static int launchd_pid = 1;
static int spawn_result;
static int spawn_calls;
static int lookup_calls;
static mach_port_t lookup_result = 700;
static pid_t next_fake_pid = 500;
static pid_t fake_tracked_pid;
static pid_t fake_unadopted_pid;
static char fake_checkin_token[33];
static unsigned fake_token_counter;
static bool fake_child_alive;
static bool fake_unadopted_alive;
static bool fake_hold_child_after_kill;
static bool fake_fail_kill;
static int fake_kill_calls;
static int fake_waitpid_nonblocking_calls;
static int fake_waitpid_blocking_calls;
static char fake_jailbreakd_pid_env[64];
static pid_t fake_deferred_reap_pid;
static unsigned fake_deferred_reap_calls;
static pid_t fake_respawn_reap_pid;
static unsigned fake_respawn_reap_calls;
static struct fake_spawn_attributes fake_spawn_attributes;
static int fake_attr_init_error;
static int fake_attr_flags_error;
static int fake_attr_ports_error;
static int fake_attr_destroy_calls;
static int fake_attr_flags_calls;
static int fake_attr_ports_calls;
static mach_port_t fake_expected_bootstrap_port;

static pid_t fake_getpid(void) { return (pid_t)launchd_pid; }
static char *fake_getenv(const char *name)
{
    assert(strcmp(name, "JAILBREAKD_PID") == 0);
    return fake_jailbreakd_pid_env[0] ? fake_jailbreakd_pid_env : NULL;
}
static int fake_setenv(const char *name, const char *value, int overwrite)
{
    assert(strcmp(name, "JAILBREAKD_PID") == 0 && overwrite == 1);
    int written = snprintf(fake_jailbreakd_pid_env, sizeof(fake_jailbreakd_pid_env), "%s", value);
    return written < 0 || (size_t)written >= sizeof(fake_jailbreakd_pid_env) ? -1 : 0;
}
static void scheduleJailbreakdParentReap(pid_t pid, unsigned int retriesRemaining)
{
    assert(retriesRemaining == 50);
    fake_deferred_reap_pid = pid;
    fake_deferred_reap_calls++;
}
static void scheduleRespawnedJailbreakdChildReap(pid_t pid, unsigned int retriesRemaining)
{
    assert(retriesRemaining == 20);
    fake_respawn_reap_pid = pid;
    fake_respawn_reap_calls++;
}
#define getpid fake_getpid
#define getenv fake_getenv
#define setenv fake_setenv
#define waitpid fake_waitpid
#define kill fake_kill
#define sleep(seconds) do { (void)(seconds); } while (0)

static pid_t fake_waitpid(pid_t pid, int *status, int options)
{
    if (options == WNOHANG) fake_waitpid_nonblocking_calls++;
    else {
        assert(options == 0);
        fake_waitpid_blocking_calls++;
    }
    if (pid != fake_tracked_pid) {
        errno = ECHILD;
        return -1;
    }
    if (fake_child_alive) {
        assert(options & WNOHANG); /* the mock must never block on a live child */
        return 0;
    }
    if (status) *status = 0;
    return pid;
}

static int fake_kill(pid_t pid, int signal_number)
{
    if (signal_number == 0) {
        if ((pid == fake_tracked_pid && fake_child_alive) ||
            (pid == fake_unadopted_pid && fake_unadopted_alive)) return 0;
        errno = ESRCH;
        return -1;
    }
    assert(signal_number == SIGKILL);
    fake_kill_calls++;
    if (fake_fail_kill) {
        errno = EPERM;
        return -1;
    }
    if (pid == fake_tracked_pid && !fake_hold_child_after_kill)
        fake_child_alive = false;
    return 0;
}

static int posix_spawnattr_init(posix_spawnattr_t *attr)
{
    if (fake_attr_init_error) return fake_attr_init_error;
    fake_spawn_attributes.flags = 0;
    *attr = &fake_spawn_attributes;
    return 0;
}
static int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags)
{
    assert(attr && *attr == &fake_spawn_attributes);
    fake_attr_flags_calls++;
    if (fake_attr_flags_error) return fake_attr_flags_error;
    (*attr)->flags = flags;
    return 0;
}
static int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t *attr, mach_port_t ports[], uint32_t count)
{
    assert(attr && *attr == &fake_spawn_attributes);
    fake_attr_ports_calls++;
    assert(count == 3 && ports[0] == MACH_PORT_NULL && ports[1] == MACH_PORT_NULL);
    assert(ports[2] == fake_expected_bootstrap_port);
    return fake_attr_ports_error;
}
static int posix_spawnattr_destroy(posix_spawnattr_t *attr)
{
    fake_attr_destroy_calls++;
    if (attr) *attr = NULL;
    return 0;
}

static mach_port_t mach_task_self(void) { return 1; }
static mach_port_t mach_host_self(void) { return 2; }
static kern_return_t mach_port_allocate(mach_port_t task, int right, mach_port_t *port)
{
    (void)task; (void)right;
    if (fail_allocate || next_port >= MAX_FAKE_PORTS) return KERN_FAILURE;
    *port = next_port++;
    fake_ports[*port] = (fake_port_t){ .allocated = true, .receive = true };
    return KERN_SUCCESS;
}
static kern_return_t mach_port_insert_right(mach_port_t task, mach_port_t name,
                                             mach_port_t poly, int disposition)
{
    (void)task; (void)poly; (void)disposition;
    if (fail_insert_right || name >= MAX_FAKE_PORTS || !fake_ports[name].allocated)
        return KERN_FAILURE;
    fake_ports[name].send = true;
    fake_ports[name].send_refs = 1;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_destroy(mach_port_t task, mach_port_t name)
{
    (void)task;
    if (name == MACH_PORT_NULL || name >= MAX_FAKE_PORTS) return KERN_INVALID_RIGHT;
    fake_ports[name].destroy_count++;
    fake_ports[name].allocated = false;
    fake_ports[name].receive = false;
    fake_ports[name].send = false;
    fake_ports[name].dead = true;
    fake_ports[name].send_refs = 0;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_mod_refs(mach_port_t task, mach_port_t name,
                                         int right, int delta)
{
    (void)task;
    if (right != MACH_PORT_RIGHT_SEND || name == MACH_PORT_NULL ||
        name >= MAX_FAKE_PORTS || !fake_ports[name].allocated ||
        !fake_ports[name].send || fake_ports[name].dead)
        return KERN_INVALID_RIGHT;
    fake_ports[name].send_refs += delta;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_deallocate(mach_port_t task, mach_port_t name)
{
    (void)task;
    if (name < MAX_FAKE_PORTS && fake_ports[name].send_refs > 0)
        fake_ports[name].send_refs--;
    return KERN_SUCCESS;
}
static kern_return_t host_set_special_port(mach_port_t host, int which, mach_port_t name)
{
    (void)host; (void)which;
    if (fail_host_set) return KERN_FAILURE;
    if (name == MACH_PORT_NULL || name >= MAX_FAKE_PORTS ||
        !fake_ports[name].allocated || !fake_ports[name].send || fake_ports[name].dead)
        return KERN_INVALID_RIGHT;
    host_special_port = name;
    return KERN_SUCCESS;
}
static kern_return_t host_get_special_port(mach_port_t host, int node, int which,
                                            mach_port_t *name)
{
    (void)host; (void)node; (void)which;
    *name = host_special_port;
    if (host_special_port == MACH_PORT_NULL) return KERN_FAILURE;
    if (host_special_port < MAX_FAKE_PORTS) fake_ports[host_special_port].send_refs++;
    return KERN_SUCCESS;
}
static const char *mach_error_string(kern_return_t error)
{
    (void)error;
    return "mock";
}
void jailbreakdServerPortAbandonCandidate(uint64_t generation, mach_port_t port);
int jailbreakdServerPortSetCheckinToken(uint64_t generation, mach_port_t port, const char *token);
static int spawnJailbreakd(void)
{
    spawn_calls++;
    if (spawn_result != 0) {
        jailbreakdServerPortAbandonCandidate(__jailbreakd_port_generation, gJailbreakdPort);
        return spawn_result;
    }
    snprintf(fake_checkin_token, sizeof(fake_checkin_token), "%032x", ++fake_token_counter);
    if (jailbreakdServerPortSetCheckinToken(__jailbreakd_port_generation,
                                             gJailbreakdPort, fake_checkin_token) != 0)
        return EINVAL;
    pid_t pid = next_fake_pid++;
    __jailbreakd_expected_pid = pid;
    __jailbreakd_child_pid = pid;
    fake_tracked_pid = pid;
    fake_child_alive = true;
    return spawn_result;
}
static mach_port_t jbclient_jailbreakd_lookup(void)
{
    lookup_calls++;
    return lookup_result;
}

'''

main = r'''static void reset_case(void)
{
    memset(fake_ports, 0, sizeof(fake_ports));
    next_port = 100;
    host_special_port = MACH_PORT_NULL;
    fail_allocate = false;
    fail_insert_right = false;
    fail_host_set = false;
    launchd_pid = 1;
    spawn_result = 0;
    spawn_calls = 0;
    lookup_calls = 0;
    lookup_result = 700;
    __firstLoad = false;
    __jailbreakd_initialized = false;
    __jailbreakd_port_ready = false;
    __jailbreakd_port_generation = 0;
    __jailbreakd_expected_pid = 0;
    __jailbreakd_child_pid = 0;
    __jailbreakd_candidate_pending = false;
    __jailbreakd_checkin_in_progress = false;
    memset(__jailbreakd_checkin_token, 0, sizeof(__jailbreakd_checkin_token));
    __jailbreakd_ready_pid = 0;
    __jailbreakd_ready_generation = 0;
    memset(__jailbreakd_ready_token, 0, sizeof(__jailbreakd_ready_token));
    next_fake_pid = 500;
    fake_tracked_pid = 0;
    fake_unadopted_pid = 0;
    fake_checkin_token[0] = 0;
    fake_token_counter = 0;
    fake_child_alive = false;
    fake_unadopted_alive = false;
    fake_hold_child_after_kill = false;
    fake_fail_kill = false;
    fake_kill_calls = 0;
    fake_waitpid_nonblocking_calls = 0;
    fake_waitpid_blocking_calls = 0;
    fake_jailbreakd_pid_env[0] = '\0';
    fake_deferred_reap_pid = 0;
    fake_deferred_reap_calls = 0;
    fake_respawn_reap_pid = 0;
    fake_respawn_reap_calls = 0;
    memset(&fake_spawn_attributes, 0, sizeof(fake_spawn_attributes));
    fake_attr_init_error = 0;
    fake_attr_flags_error = 0;
    fake_attr_ports_error = 0;
    fake_attr_destroy_calls = 0;
    fake_attr_flags_calls = 0;
    fake_attr_ports_calls = 0;
    fake_expected_bootstrap_port = 333;
    gJailbreakdPort = MACH_PORT_NULL;
}

static int complete_current_candidate(void)
{
    jailbreakd_checkin_ticket_t ticket = {0};
    jailbreakd_checkin_ticket_t readyTicket = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, fake_checkin_token, &ticket) == 0);
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_expected_pid, fake_checkin_token, &readyTicket) == 0);
    assert(ticket.pid == readyTicket.pid && ticket.generation == readyTicket.generation && ticket.port == readyTicket.port);
    return jailbreakdServerPortCheckinComplete(&readyTicket);
}

static void fail_current_candidate(void)
{
    jailbreakd_checkin_ticket_t ticket = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, fake_checkin_token, &ticket) == 0);
    assert(jailbreakdServerPortCheckinAbort(__jailbreakd_expected_pid, fake_checkin_token, &ticket) == 0);
    jailbreakdServerPortCheckinFailed(&ticket);
}

static void test_unready_port_is_not_returned_and_becomes_ready_after_checkin(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    assert(candidate != MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(host_special_port == MACH_PORT_NULL);
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 1);

    assert(complete_current_candidate() == 0);
    assert(__jailbreakd_port_ready);
    assert(host_special_port == candidate);
    jailbreakdServerPortCheckinTimedOut(__jailbreakd_port_generation);
    assert(gJailbreakdPort == candidate); /* an expired timer cannot revoke a checked-in port */
    assert(jailbreakdClientPort() == candidate);

    launchd_pid = 4242;
    assert(jailbreakdClientPort() == candidate);
    assert(lookup_calls == 0);
}

static void test_suspended_respawn_cleanup_never_leaves_a_blocking_wait(void)
{
    reset_case();
    fake_tracked_pid = 700;
    fake_child_alive = true;
    terminateRespawnedJailbreakdChild(fake_tracked_pid);
    assert(fake_kill_calls == 1);
    assert(!fake_child_alive);
    assert(fake_waitpid_blocking_calls == 0);
    assert(fake_waitpid_nonblocking_calls == 1);

    reset_case();
    fake_tracked_pid = 701;
    fake_child_alive = true;
    fake_fail_kill = true;
    terminateRespawnedJailbreakdChild(fake_tracked_pid);
    assert(fake_kill_calls == 1);
    assert(fake_child_alive);
    assert(fake_waitpid_blocking_calls == 0);
    assert(fake_waitpid_nonblocking_calls == 1);
    assert(fake_respawn_reap_calls == 1 && fake_respawn_reap_pid == 701);
}

static void test_previous_pid_environment_is_validated_before_waitpid(void)
{
    reset_case();
    strcpy(fake_jailbreakd_pid_env, "0");
    int waitsBefore = fake_waitpid_nonblocking_calls;
    setJailbreakdProcess(800);
    assert(fake_waitpid_nonblocking_calls == waitsBefore);
    assert(strcmp(fake_jailbreakd_pid_env, "800") == 0);

    reset_case();
    strcpy(fake_jailbreakd_pid_env, "not-a-pid");
    setJailbreakdProcess(801);
    assert(fake_waitpid_nonblocking_calls == 0);
    assert(strcmp(fake_jailbreakd_pid_env, "801") == 0);

    reset_case();
    strcpy(fake_jailbreakd_pid_env, "321");
    fake_tracked_pid = 321;
    setJailbreakdProcess(802);
    assert(fake_waitpid_nonblocking_calls == 1);
    assert(fake_waitpid_blocking_calls == 0);
    assert(strcmp(fake_jailbreakd_pid_env, "802") == 0);

    reset_case();
    strcpy(fake_jailbreakd_pid_env, "322");
    fake_tracked_pid = 322;
    fake_child_alive = true;
    setJailbreakdProcess(803);
    assert(fake_waitpid_nonblocking_calls == 1);
    assert(fake_waitpid_blocking_calls == 0);
    assert(fake_deferred_reap_calls == 1 && fake_deferred_reap_pid == 322);
    assert(strcmp(fake_jailbreakd_pid_env, "803") == 0);
}

static void *call_set_jailbreakd_process(void *argument)
{
    setJailbreakdProcess(*(pid_t *)argument);
    return NULL;
}

static void test_duplicate_ready_pid_updates_are_serialized(void)
{
    reset_case();
    strcpy(fake_jailbreakd_pid_env, "324");
    fake_tracked_pid = 324;
    fake_child_alive = true;
    pid_t readyPid = 812;
    pthread_t first;
    pthread_t second;
    assert(pthread_create(&first, NULL, call_set_jailbreakd_process, &readyPid) == 0);
    assert(pthread_create(&second, NULL, call_set_jailbreakd_process, &readyPid) == 0);
    assert(pthread_join(first, NULL) == 0);
    assert(pthread_join(second, NULL) == 0);
    assert(fake_waitpid_nonblocking_calls == 1);
    assert(fake_deferred_reap_calls == 1 && fake_deferred_reap_pid == 324);
    assert(strcmp(fake_jailbreakd_pid_env, "812") == 0);
}

static void test_bootstrap_port_setup_retries_and_cleans_partial_rights(void)
{
    reset_case();
    mach_port_t bootstrapPort = MACH_PORT_NULL;
    fail_allocate = true;
    assert(prepareJailbreakdBootstrapPort(&bootstrapPort) == KERN_FAILURE);
    assert(bootstrapPort == MACH_PORT_NULL);

    reset_case();
    bootstrapPort = MACH_PORT_NULL;
    fail_insert_right = true;
    assert(prepareJailbreakdBootstrapPort(&bootstrapPort) == KERN_FAILURE);
    assert(bootstrapPort == MACH_PORT_NULL);
    assert(fake_ports[100].destroy_count == 1 && !fake_ports[100].allocated);

    reset_case();
    bootstrapPort = MACH_PORT_NULL;
    assert(prepareJailbreakdBootstrapPort(&bootstrapPort) == KERN_SUCCESS);
    assert(bootstrapPort == 100 && fake_ports[100].receive && fake_ports[100].send);
    assert(prepareJailbreakdBootstrapPort(&bootstrapPort) == KERN_SUCCESS);
    assert(bootstrapPort == 101 && fake_ports[100].destroy_count == 1);
    assert(fake_ports[101].receive && fake_ports[101].send);
}

static void test_spawn_attribute_failures_destroy_initialized_attributes(void)
{
    reset_case();
    posix_spawnattr_t attr = NULL;
    fake_attr_init_error = 11;
    assert(initializeRespawnedJailbreakdAttributes(&attr, fake_expected_bootstrap_port) == 11);
    assert(attr == NULL && fake_attr_destroy_calls == 0);
    assert(fake_attr_flags_calls == 0 && fake_attr_ports_calls == 0);

    reset_case();
    attr = NULL;
    fake_attr_flags_error = 12;
    assert(initializeRespawnedJailbreakdAttributes(&attr, fake_expected_bootstrap_port) == 12);
    assert(attr == NULL && fake_attr_destroy_calls == 1);
    assert(fake_attr_flags_calls == 1 && fake_attr_ports_calls == 0);

    reset_case();
    attr = NULL;
    fake_attr_ports_error = 13;
    assert(initializeRespawnedJailbreakdAttributes(&attr, fake_expected_bootstrap_port) == 13);
    assert(attr == NULL && fake_attr_destroy_calls == 1);
    assert(fake_attr_flags_calls == 1 && fake_attr_ports_calls == 1);

    reset_case();
    attr = NULL;
    assert(initializeRespawnedJailbreakdAttributes(&attr, fake_expected_bootstrap_port) == 0);
    assert(attr == &fake_spawn_attributes && fake_attr_destroy_calls == 0);
    assert(attr->flags == POSIX_SPAWN_START_SUSPENDED);
    assert(fake_attr_flags_calls == 1 && fake_attr_ports_calls == 1);
}

static void test_respawned_daemon_pid_is_bound_by_generation_token(void)
{
    reset_case();
    assert(initJailbreakd(false) == 0);
    pid_t launchd_spawn_pid = __jailbreakd_expected_pid;
    jailbreakd_checkin_ticket_t rejected = {0};
    assert(jailbreakdServerPortCheckinBegin(launchd_spawn_pid + 1,
                                            "ffffffffffffffffffffffffffffffff",
                                            &rejected) != 0);
    assert(!__jailbreakd_checkin_in_progress);

    jailbreakd_checkin_ticket_t respawned = {0};
    assert(jailbreakdServerPortCheckinBegin(launchd_spawn_pid + 1, fake_checkin_token, &respawned) == 0);
    assert(respawned.pid == launchd_spawn_pid + 1);
    fake_unadopted_pid = respawned.pid;
    fake_unadopted_alive = true;
    pthread_mutex_lock(&__jailbreakd_port_mutex);
    assert(!reapJailbreakdChildIfExitedLocked()); /* ECHILD is not proof of exit before reparenting. */
    pthread_mutex_unlock(&__jailbreakd_port_mutex);
    jailbreakd_checkin_ticket_t readyTicket = {0};
    assert(jailbreakdServerPortCheckinReady(launchd_spawn_pid + 1, fake_checkin_token, &readyTicket) == 0);
    assert(jailbreakdServerPortCheckinComplete(&readyTicket) == 0);
    assert(__jailbreakd_port_ready);
    assert(__jailbreakd_child_pid == launchd_spawn_pid + 1);
}

static void test_initial_spawn_failure_rolls_back_and_retries(void)
{
    reset_case();
    spawn_result = 71;
    assert(initJailbreakd(true) == 71);
    assert(__jailbreakd_initialized);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(host_special_port == MACH_PORT_NULL);
    assert(fake_ports[100].destroy_count == 1);

    spawn_result = 0;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    mach_port_t candidate = gJailbreakdPort;
    assert(candidate != MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(spawn_calls == 2);
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 2); /* do not spawn a second daemon while check-in is pending */

    assert(complete_current_candidate() == 0);
    assert(jailbreakdClientPort() == candidate);
}

static void test_ready_ack_requires_current_pid_token_and_candidate(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    jailbreakd_checkin_ticket_t begun = {0};
    jailbreakd_checkin_ticket_t ready = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, fake_checkin_token, &begun) == 0);
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_expected_pid + 1, fake_checkin_token, &ready) != 0);
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_expected_pid, "ffffffffffffffffffffffffffffffff", &ready) != 0);
    assert(!__jailbreakd_port_ready);
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_expected_pid, fake_checkin_token, &ready) == 0);
    assert(ready.pid == begun.pid && ready.generation == begun.generation && ready.port == begun.port);
    assert(jailbreakdServerPortCheckinComplete(&ready) == 0);
    assert(__jailbreakd_port_ready);
    jailbreakd_checkin_ticket_t retry = {0};
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_ready_pid, fake_checkin_token, &retry) == 0);
    assert(retry.pid == ready.pid && retry.generation == ready.generation && retry.port == ready.port);
    assert(jailbreakdServerPortCheckinComplete(&retry) == 0);
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_ready_pid + 1, fake_checkin_token, &retry) != 0);
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_ready_pid,
                                            "ffffffffffffffffffffffffffffffff", &retry) != 0);
}

static void test_checkin_abort_requires_current_pid_and_token(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    jailbreakd_checkin_ticket_t ticket = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, fake_checkin_token, &ticket) == 0);
    assert(jailbreakdServerPortCheckinAbort(__jailbreakd_expected_pid + 1, fake_checkin_token, &ticket) != 0);
    assert(jailbreakdServerPortCheckinAbort(__jailbreakd_expected_pid,
                                            "ffffffffffffffffffffffffffffffff", &ticket) != 0);
    assert(__jailbreakd_candidate_pending && !__jailbreakd_port_ready);
    assert(jailbreakdServerPortCheckinAbort(__jailbreakd_expected_pid, fake_checkin_token, &ticket) == 0);
    jailbreakdServerPortCheckinFailed(&ticket);
    assert(gJailbreakdPort == MACH_PORT_NULL && !__jailbreakd_port_ready);
}

static void test_checkin_failure_discards_only_the_unready_candidate(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    fail_current_candidate();
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[candidate].destroy_count == 1);
    assert(host_special_port == MACH_PORT_NULL);
}

static void test_startup_timeout_discards_failed_candidate_and_allows_retry(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    uint64_t generation = __jailbreakd_port_generation;

    jailbreakdServerPortCheckinTimedOut(generation);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[candidate].destroy_count == 1);
    assert(host_special_port == MACH_PORT_NULL);

    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(gJailbreakdPort != MACH_PORT_NULL);
    assert(gJailbreakdPort != candidate);
    assert(spawn_calls == 2);
}

static void test_stale_timeout_cannot_discard_a_new_generation(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    uint64_t stale_generation = __jailbreakd_port_generation;
    char stale_token[sizeof(fake_checkin_token)];
    memcpy(stale_token, fake_checkin_token, sizeof(stale_token));
    jailbreakd_checkin_ticket_t stale_ticket = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, stale_token, &stale_ticket) == 0);
    jailbreakdServerPortCheckinTimedOut(stale_generation);
    assert(gJailbreakdPort == MACH_PORT_NULL);

    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    mach_port_t current_candidate = gJailbreakdPort;
    assert(current_candidate != MACH_PORT_NULL);
    assert(strcmp(stale_token, fake_checkin_token) != 0);
    jailbreakd_checkin_ticket_t stale_token_ticket = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, stale_token,
                                            &stale_token_ticket) != 0);
    jailbreakd_checkin_ticket_t current_ticket = {0};
    assert(jailbreakdServerPortCheckinBegin(__jailbreakd_expected_pid, fake_checkin_token, &current_ticket) == 0);
    assert(__jailbreakd_port_generation != stale_generation);

    assert(jailbreakdServerPortCheckinComplete(&stale_ticket) != 0);
    assert(gJailbreakdPort == current_candidate);
    assert(!__jailbreakd_port_ready);
    int kills_before_stale_failure = fake_kill_calls;
    jailbreakdServerPortCheckinFailed(&stale_ticket);
    assert(gJailbreakdPort == current_candidate);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[current_candidate].destroy_count == 0);
    assert(fake_kill_calls == kills_before_stale_failure);
    jailbreakd_checkin_ticket_t current_ready_ticket = {0};
    assert(jailbreakdServerPortCheckinReady(__jailbreakd_expected_pid, fake_checkin_token,
                                            &current_ready_ticket) == 0);
    assert(jailbreakdServerPortCheckinComplete(&current_ready_ticket) == 0);
    assert(__jailbreakd_port_ready);
}

static void test_live_timed_out_child_never_blocks_restart(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    pid_t old_pid = __jailbreakd_expected_pid;
    fake_hold_child_after_kill = true;
    mach_port_t old_port = gJailbreakdPort;
    uint64_t old_generation = __jailbreakd_port_generation;

    jailbreakdServerPortCheckinTimedOut(old_generation);
    assert(fake_kill_calls == 1);
    assert(fake_child_alive);
    assert(gJailbreakdPort == MACH_PORT_NULL);

    /* Retry uses waitpid(WNOHANG): it returns rather than waiting for the live child. */
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 1);
    assert(__jailbreakd_child_pid == old_pid);
    assert(fake_ports[old_port].destroy_count == 1);

    fake_child_alive = false;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 2);
    assert(gJailbreakdPort != MACH_PORT_NULL);
    assert(__jailbreakd_child_pid != old_pid);
}

static void test_failed_restart_rolls_back_and_retry_waits_for_checkin(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    assert(complete_current_candidate() == 0);
    mach_port_t old_port = gJailbreakdPort;
    fake_ports[old_port].send = false;
    fake_ports[old_port].receive = false;
    fake_ports[old_port].dead = true;

    spawn_result = 72;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[old_port + 1].destroy_count == 1);
    assert(host_special_port == old_port); /* no unverified special-port clearing */

    spawn_result = 0;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    mach_port_t new_port = gJailbreakdPort;
    assert(new_port == old_port + 2);
    assert(!__jailbreakd_port_ready);
    assert(host_special_port == old_port);
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 3);

    assert(complete_current_candidate() == 0);
    assert(host_special_port == new_port);
    assert(jailbreakdClientPort() == new_port);
}

static void test_dead_fast_special_port_falls_back_to_launchd_lookup(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    assert(complete_current_candidate() == 0);
    mach_port_t old_port = gJailbreakdPort;
    fake_ports[old_port].send = false;
    fake_ports[old_port].receive = false;
    fake_ports[old_port].dead = true;
    launchd_pid = 4242;
    lookup_result = 777;

    assert(jailbreakdClientPortFastGet() == MACH_PORT_NULL);
    assert(jailbreakdClientPort() == lookup_result);
    assert(lookup_calls == 1);
}

static void test_special_port_publish_failure_keeps_xpc_lookup_available(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    fail_host_set = true;
    assert(complete_current_candidate() == 0);
    assert(__jailbreakd_port_ready);
    assert(host_special_port == MACH_PORT_NULL);
    assert(jailbreakdClientPort() == candidate);

    launchd_pid = 4242;
    lookup_result = 778;
    assert(jailbreakdClientPort() == lookup_result);
    assert(lookup_calls == 1);
}

static void test_insert_right_failure_does_not_leave_a_candidate(void)
{
    reset_case();
    fail_insert_right = true;
    assert(initJailbreakd(true) == -1);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_initialized);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[100].destroy_count == 1);
    assert(spawn_calls == 0);
}

int main(void)
{
    test_previous_pid_environment_is_validated_before_waitpid();
    test_duplicate_ready_pid_updates_are_serialized();
    test_bootstrap_port_setup_retries_and_cleans_partial_rights();
    test_spawn_attribute_failures_destroy_initialized_attributes();
    test_suspended_respawn_cleanup_never_leaves_a_blocking_wait();
    test_unready_port_is_not_returned_and_becomes_ready_after_checkin();
    test_ready_ack_requires_current_pid_token_and_candidate();
    test_checkin_abort_requires_current_pid_and_token();
    test_respawned_daemon_pid_is_bound_by_generation_token();
    test_initial_spawn_failure_rolls_back_and_retries();
    test_checkin_failure_discards_only_the_unready_candidate();
    test_startup_timeout_discards_failed_candidate_and_allows_retry();
    test_stale_timeout_cannot_discard_a_new_generation();
    test_live_timed_out_child_never_blocks_restart();
    test_failed_restart_rolls_back_and_retry_waits_for_checkin();
    test_dead_fast_special_port_falls_back_to_launchd_lookup();
    test_special_port_publish_failure_keeps_xpc_lookup_available();
    test_insert_right_failure_does_not_leave_a_candidate();
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    c_file = directory / "jailbreakd_lifecycle.c"
    executable = directory / "jailbreakd_lifecycle"
    c_file.write_text(harness.replace("/* INJECT_REAL_GLOBALS */", globals_block) + "\n" + functions + "\n" + main)
    subprocess.run(
        ["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
         "-fsanitize=address,undefined", str(c_file), "-o", str(executable)],
        check=True,
    )
    subprocess.run([str(executable)], check=True)

print("PASS: jailbreakd lifecycle readiness, spawn cleanup, bootstrap-port rollback/retry, stale tickets, timeout reaping, and dead-port fallback")
