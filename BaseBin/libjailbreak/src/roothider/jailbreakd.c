#include <spawn.h>
#include <unistd.h>
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <xpc/xpc.h>
#include <mach/mach.h>
#include <bsm/libbsm.h>
#include <sys/param.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <string.h>

#include "../libjailbreak.h"
#include "jailbreakd.h"
#include "common.h"
#include "log.h"
#include "../jbserver.h"
#include "../roothide_stage.h"

#ifdef ENABLE_LOGS
static void (*JBDLogDebugFunction)(const char *format, ...);
static void (*JBDLogErrorFunction)(const char *format, ...);

#define JBLogDebug(...) do { if(JBDLogDebugFunction)JBDLogDebugFunction(__VA_ARGS__); } while(0)
#define JBLogError(...) do { if(JBDLogErrorFunction)JBDLogErrorFunction(__VA_ARGS__); } while(0)

void enableJBDLog(void* debugLog, void* errorLog)
{
	JBDLogDebugFunction = debugLog;
	JBDLogErrorFunction = errorLog;
}
#endif

int posix_spawnattr_setspecialport_np(posix_spawnattr_t *attr, mach_port_t new_port, int which);
int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t * __restrict attr, mach_port_t portarray[], uint32_t count);
extern char **environ;

static bool __firstLoad = false;
static bool __jailbreakd_initialized = false;
static bool __jailbreakd_port_ready = false;
static pthread_mutex_t __jailbreakd_port_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t __jailbreakd_restart_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t __jailbreakd_process_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t __jailbreakd_port_generation = 0;
static pid_t __jailbreakd_expected_pid = 0;
static pid_t __jailbreakd_child_pid = 0;
static bool __jailbreakd_candidate_pending = false;
static bool __jailbreakd_checkin_in_progress = false;
static char __jailbreakd_checkin_token[33] = {0};
static pid_t __jailbreakd_ready_pid = 0;
static uint64_t __jailbreakd_ready_generation = 0;
static char __jailbreakd_ready_token[33] = {0};
mach_port_t gJailbreakdPort = MACH_PORT_NULL;

#define JAILBREAKD_CLIENT_PORT_FAST_GET

static int destroyLocalJailbreakdServerPortLocked(void)
{
	__jailbreakd_port_ready = false;
	if (!MACH_PORT_VALID(gJailbreakdPort)) {
		gJailbreakdPort = MACH_PORT_NULL;
		return 0;
	}

	kern_return_t kr = mach_port_destroy(mach_task_self(), gJailbreakdPort);
	if (kr != KERN_SUCCESS) {
		JBLogError("mach_port_destroy failed for jailbreakd port: %x,%s", kr, mach_error_string(kr));
		return -1;
	}

	gJailbreakdPort = MACH_PORT_NULL;
	return 0;
}

static void advanceJailbreakdPortGenerationLocked(void)
{
    if (++__jailbreakd_port_generation == 0) {
        ++__jailbreakd_port_generation;
    }
}

/* Must be called with __jailbreakd_port_mutex held; never wait for a live child. */
static bool reapJailbreakdChildIfExitedLocked(void)
{
    if (__jailbreakd_child_pid <= 1) return true;

    pid_t child = __jailbreakd_child_pid;
    int status = 0;
    pid_t result = waitpid(child, &status, WNOHANG);
    bool childExited = result == child;
    if (result == -1 && errno == ECHILD) {
        /* A respawned daemon may still be parented to the bootstrap process. */
        if (kill(child, 0) == 0 || errno != ESRCH) return false;
        childExited = true;
    }
    if (childExited) {
        if (__jailbreakd_ready_pid == child) {
            __jailbreakd_ready_pid = 0;
            __jailbreakd_ready_generation = 0;
            memset(__jailbreakd_ready_token, 0, sizeof(__jailbreakd_ready_token));
        }
        __jailbreakd_child_pid = 0;
        if (__jailbreakd_expected_pid == child) {
            __jailbreakd_expected_pid = 0;
            __jailbreakd_candidate_pending = false;
            __jailbreakd_port_ready = false;
            advanceJailbreakdPortGenerationLocked();
        }
        return true;
    }
    if (result == 0 || (result == -1 && errno == EINTR)) return false;

    JBLogError("waitpid(WNOHANG) failed for jailbreakd pid=%d errno=%d", child, errno);
    return false;
}

static void terminateJailbreakdChild(pid_t pid)
{
    if (pid <= 1) return;

    pthread_mutex_lock(&__jailbreakd_port_mutex);
    if (__jailbreakd_child_pid == pid && !reapJailbreakdChildIfExitedLocked()) {
        if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
            JBLogError("failed to terminate stale jailbreakd pid=%d errno=%d", pid, errno);
        } else {
            JBLogError("sent SIGKILL to stale jailbreakd pid=%d", pid);
            /* Reap immediately if the child has already completed signal exit. */
            reapJailbreakdChildIfExitedLocked();
        }
    }
    pthread_mutex_unlock(&__jailbreakd_port_mutex);
}

int registerServerPort()
{
	if (getpid() != 1) {
		JBLogError("registerServerPort called outside launchd: pid=%d", getpid());
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (!reapJailbreakdChildIfExitedLocked()) {
		JBLogError("refusing to register a jailbreakd port while prior child pid=%d remains alive",
		           __jailbreakd_child_pid);
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		return EBUSY;
	}
	if (destroyLocalJailbreakdServerPortLocked() != 0) {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		return -1;
	}
	/* Invalidate any delayed watchdog and ticket for the previous candidate. */
	advanceJailbreakdPortGenerationLocked();
	__jailbreakd_ready_pid = 0;
	__jailbreakd_ready_generation = 0;
	memset(__jailbreakd_ready_token, 0, sizeof(__jailbreakd_ready_token));
	__jailbreakd_expected_pid = 0;
	__jailbreakd_candidate_pending = false;
	__jailbreakd_checkin_in_progress = false;
	memset(__jailbreakd_checkin_token, 0, sizeof(__jailbreakd_checkin_token));

	kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gJailbreakdPort);
	if (kr != KERN_SUCCESS) {
		JBLogError("mach_port_allocate failed: %x,%s", kr, mach_error_string(kr));
		gJailbreakdPort = MACH_PORT_NULL;
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		return -1;
	}

	kr = mach_port_insert_right(mach_task_self(), gJailbreakdPort, gJailbreakdPort, MACH_MSG_TYPE_MAKE_SEND);
	if (kr != KERN_SUCCESS) {
		JBLogError("mach_port_insert_right failed: %x,%s", kr, mach_error_string(kr));
		mach_port_destroy(mach_task_self(), gJailbreakdPort);
		gJailbreakdPort = MACH_PORT_NULL;
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		return -1;
	}

	JBLogDebug("jailbreakd server port: %x", gJailbreakdPort);
	__jailbreakd_candidate_pending = true;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return 0;
}

int jailbreakdServerPortSetCheckinToken(uint64_t generation, mach_port_t port, const char *token)
{
	if (getpid() != 1 || !token || strlen(token) != 32) return -1;
	for (size_t i = 0; i < 32; i++) {
		if (!((token[i] >= '0' && token[i] <= '9') || (token[i] >= 'a' && token[i] <= 'f'))) return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (!__jailbreakd_candidate_pending || __jailbreakd_port_ready ||
	    generation != __jailbreakd_port_generation || !MACH_PORT_VALID(port) ||
	    port != gJailbreakdPort || __jailbreakd_checkin_token[0] != '\0') {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		return -1;
	}
	memcpy(__jailbreakd_checkin_token, token, sizeof(__jailbreakd_checkin_token));
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return 0;
}

int jailbreakdServerPortCheckinBegin(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)
{
	if (getpid() != 1 || pid <= 1 || !token || !ticket) {
		JBLogError("invalid jailbreakd check-in begin: launchd_pid=%d caller_pid=%d ticket=%d",
		           getpid(), pid, ticket != NULL);
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	uint64_t generation = __jailbreakd_port_generation;
	if (!__jailbreakd_initialized || !__jailbreakd_candidate_pending ||
	    __jailbreakd_port_ready || __jailbreakd_checkin_in_progress ||
	    strlen(token) != 32 || strcmp(token, __jailbreakd_checkin_token) != 0 ||
	    !MACH_PORT_VALID(gJailbreakdPort)) {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		JBLogError("rejecting jailbreakd check-in begin pid=%d generation=%llu",
		           pid, (unsigned long long)generation);
		return -1;
	}

	ticket->pid = pid;
	ticket->generation = __jailbreakd_port_generation;
	ticket->port = gJailbreakdPort;
	__jailbreakd_expected_pid = pid;
	__jailbreakd_child_pid = pid;
	__jailbreakd_checkin_in_progress = true;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return 0;
}

int jailbreakdServerPortCheckinReady(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)
{
    if (getpid() != 1 || pid <= 1 || !token || !ticket) {
        JBLogError("invalid jailbreakd ready acknowledgement pid=%d", pid);
        return -1;
    }

    size_t tokenLength = strlen(token);
    pthread_mutex_lock(&__jailbreakd_port_mutex);
    uint64_t generation = __jailbreakd_port_generation;
    /* XPC replies can be lost after the server committed readiness. Accept an
     * exact duplicate so the daemon can retry without being torn down. */
    if (__jailbreakd_initialized && __jailbreakd_port_ready &&
        pid == __jailbreakd_ready_pid && generation == __jailbreakd_ready_generation &&
        tokenLength == 32 && strcmp(token, __jailbreakd_ready_token) == 0 &&
        MACH_PORT_VALID(gJailbreakdPort)) {
        ticket->pid = pid;
        ticket->generation = generation;
        ticket->port = gJailbreakdPort;
        pthread_mutex_unlock(&__jailbreakd_port_mutex);
        return 0;
    }

    if (!__jailbreakd_initialized || !__jailbreakd_candidate_pending ||
        __jailbreakd_port_ready || !__jailbreakd_checkin_in_progress ||
        pid != __jailbreakd_expected_pid || tokenLength != 32 ||
        strcmp(token, __jailbreakd_checkin_token) != 0 || !MACH_PORT_VALID(gJailbreakdPort)) {
        pthread_mutex_unlock(&__jailbreakd_port_mutex);
        JBLogError("rejecting jailbreakd ready acknowledgement pid=%d generation=%llu",
                   pid, (unsigned long long)generation);
        return -1;
    }

    ticket->pid = pid;
    ticket->generation = generation;
    ticket->port = gJailbreakdPort;
    pthread_mutex_unlock(&__jailbreakd_port_mutex);
    return 0;
}

static bool jailbreakdCheckinTicketMatchesLocked(const jailbreakd_checkin_ticket_t *ticket)
{
	return ticket && ticket->pid > 1 && __jailbreakd_candidate_pending &&
	       !__jailbreakd_port_ready && __jailbreakd_checkin_in_progress && ticket->pid == __jailbreakd_expected_pid &&
	       ticket->generation == __jailbreakd_port_generation &&
	       MACH_PORT_VALID(ticket->port) && ticket->port == gJailbreakdPort;
}

int jailbreakdServerPortCheckinComplete(const jailbreakd_checkin_ticket_t *ticket)
{
	if (getpid() != 1 || !ticket) {
		JBLogError("jailbreakdServerPortCheckinComplete called with invalid context");
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (!jailbreakdCheckinTicketMatchesLocked(ticket)) {
		bool alreadyComplete = __jailbreakd_initialized && __jailbreakd_port_ready &&
		                       ticket->pid == __jailbreakd_ready_pid &&
		                       ticket->generation == __jailbreakd_ready_generation &&
		                       ticket->port == gJailbreakdPort && MACH_PORT_VALID(ticket->port);
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		if (alreadyComplete) return 0;
		JBLogError("rejecting stale jailbreakd check-in completion pid=%d generation=%llu port=%x",
		           ticket->pid, (unsigned long long)ticket->generation, ticket->port);
		return -1;
	}

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
	mach_port_t self_host = mach_host_self();
	kern_return_t kr = host_set_special_port(self_host, HOST_LAUNCHCTL_PORT, ticket->port);
	mach_port_deallocate(mach_task_self(), self_host);
	if (kr != KERN_SUCCESS) {
		/* Keep the checked-in service available through the launchd lookup path. */
		JBLogError("host_set_special_port failed after jailbreakd check-in: %x,%s", kr, mach_error_string(kr));
	}
#endif

	__jailbreakd_candidate_pending = false;
	__jailbreakd_expected_pid = 0;
	__jailbreakd_child_pid = ticket->pid;
	__jailbreakd_ready_pid = ticket->pid;
	__jailbreakd_ready_generation = ticket->generation;
	memcpy(__jailbreakd_ready_token, __jailbreakd_checkin_token, sizeof(__jailbreakd_ready_token));
	__jailbreakd_checkin_in_progress = false;
	memset(__jailbreakd_checkin_token, 0, sizeof(__jailbreakd_checkin_token));
	__jailbreakd_port_ready = true;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return 0;
}

void jailbreakdServerPortCheckinFailed(const jailbreakd_checkin_ticket_t *ticket)
{
	if (getpid() != 1 || !ticket) return;

	pid_t failedPid = 0;
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (jailbreakdCheckinTicketMatchesLocked(ticket)) {
		failedPid = ticket->pid;
		__jailbreakd_candidate_pending = false;
		__jailbreakd_expected_pid = 0;
		__jailbreakd_checkin_in_progress = false;
		memset(__jailbreakd_checkin_token, 0, sizeof(__jailbreakd_checkin_token));
		if (destroyLocalJailbreakdServerPortLocked() != 0) {
			JBLogError("failed to discard failed jailbreakd candidate port=%x", ticket->port);
		}
		advanceJailbreakdPortGenerationLocked();
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	terminateJailbreakdChild(failedPid);
}

void jailbreakdServerPortAbandonCandidate(uint64_t generation, mach_port_t port)
{
	if (getpid() != 1) return;

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (__jailbreakd_candidate_pending && !__jailbreakd_port_ready &&
	    __jailbreakd_expected_pid == 0 && generation == __jailbreakd_port_generation &&
	    MACH_PORT_VALID(port) && port == gJailbreakdPort) {
		__jailbreakd_candidate_pending = false;
		__jailbreakd_checkin_in_progress = false;
		memset(__jailbreakd_checkin_token, 0, sizeof(__jailbreakd_checkin_token));
		if (destroyLocalJailbreakdServerPortLocked() != 0) {
			JBLogError("failed to discard abandoned jailbreakd candidate port=%x", port);
		}
		advanceJailbreakdPortGenerationLocked();
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
}

static void jailbreakdServerPortCheckinTimedOut(uint64_t generation)
{
	if (getpid() != 1) {
		return;
	}

	bool timedOut = false;
	mach_port_t timedOutPort = MACH_PORT_NULL;
	pid_t timedOutPid = 0;
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (generation == __jailbreakd_port_generation &&
	    __jailbreakd_candidate_pending && !__jailbreakd_port_ready && MACH_PORT_VALID(gJailbreakdPort)) {
		timedOutPort = gJailbreakdPort;
		timedOutPid = __jailbreakd_expected_pid;
		__jailbreakd_expected_pid = 0;
		__jailbreakd_candidate_pending = false;
		__jailbreakd_checkin_in_progress = false;
		memset(__jailbreakd_checkin_token, 0, sizeof(__jailbreakd_checkin_token));
		if (destroyLocalJailbreakdServerPortLocked() != 0) {
			JBLogError("failed to destroy timed-out jailbreakd port=%x", timedOutPort);
		}
		advanceJailbreakdPortGenerationLocked();
		timedOut = true;
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	if (timedOut) {
		terminateJailbreakdChild(timedOutPid);
		JBLogError("jailbreakd check-in timed out; discarded port=%x generation=%llu",
		           timedOutPort, (unsigned long long)generation);
		roothide_stage_log("jailbreakd.checkin.timeout port=%x generation=%llu",
		                   timedOutPort, (unsigned long long)generation);
	}
}

static void scheduleJailbreakdServerPortCheckinWatchdog(void)
{
	uint64_t generation = 0;
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (__jailbreakd_candidate_pending && !__jailbreakd_port_ready && MACH_PORT_VALID(gJailbreakdPort)) {
		generation = __jailbreakd_port_generation;
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	if (generation == 0) {
		return;
	}

	roothide_stage_log("jailbreakd.checkin.watchdog.start generation=%llu timeout_seconds=60",
	                   (unsigned long long)generation);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60LL * 1000000000LL),
	               dispatch_get_global_queue(0, 0), ^{
		jailbreakdServerPortCheckinTimedOut(generation);
	});
}

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
mach_port_t jailbreakdClientPortFastGet()
{
	mach_port_t port = MACH_PORT_NULL;
	mach_port_t self_host = mach_host_self();
	kern_return_t kr = host_get_special_port(self_host, HOST_LOCAL_NODE, HOST_LAUNCHCTL_PORT, &port);
	roothide_stage_log("jbd.fast_lookup.end result=%d port=%x", kr, port);
	mach_port_deallocate(mach_task_self(), self_host);
	if(kr != KERN_SUCCESS) {
		if (MACH_PORT_VALID(port)) {
			mach_port_deallocate(mach_task_self(), port);
		}
		JBLogError("jailbreakdClientPortFastGet failed: %x,%s", kr, mach_error_string(kr));
		return MACH_PORT_NULL;
	}
	if (!MACH_PORT_VALID(port)) {
		return MACH_PORT_NULL;
	}

	/* host_get_special_port can return a dead-name right; verify it before use. */
	kr = mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
	if (kr != KERN_SUCCESS) {
		JBLogError("jailbreakdClientPortFastGet returned a dead port: %x,%s", kr, mach_error_string(kr));
		mach_port_deallocate(mach_task_self(), port);
		return MACH_PORT_NULL;
	}
	mach_port_deallocate(mach_task_self(), port); // release only the temporary validation uref
	return port;
}
#endif

static void scheduleJailbreakdParentReap(pid_t pid, unsigned int retriesRemaining)
{
    if (pid <= 1) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50LL * 1000000LL),
                   dispatch_get_global_queue(0, 0), ^{
        int status = 0;
        pid_t result;
        do {
            result = waitpid(pid, &status, WNOHANG);
        } while (result == -1 && errno == EINTR);

        if (result == pid || (result == -1 && errno == ECHILD)) return;
        if (result == 0 && retriesRemaining > 0) {
            scheduleJailbreakdParentReap(pid, retriesRemaining - 1);
            return;
        }
        if (result == 0) {
            JBLogError("previous jailbreakd parent pid=%d remained alive after deferred reap retries", pid);
        } else {
            JBLogError("deferred waitpid failed for previous jailbreakd pid=%d errno=%d", pid, errno);
        }
    });
}

void setJailbreakdProcess(pid_t pid)
{
    if (pid <= 1) {
        JBLogError("refusing to record invalid jailbreakd pid=%d", pid);
        return;
    }

    /* Ready actions may be delivered concurrently when the daemon retries an
     * acknowledgement whose original XPC reply was lost. */
    pthread_mutex_lock(&__jailbreakd_process_mutex);

    /* Only wait for a strictly validated positive PID; waitpid(0) could reap
     * an unrelated child in launchd's process group. */
    const char *pidenv = getenv("JAILBREAKD_PID");
    if (pidenv) {
        errno = 0;
        char *end = NULL;
        long parsedOldPid = strtol(pidenv, &end, 10);
        if (errno != 0 || end == pidenv || *end != '\0' || parsedOldPid <= 1 ||
            (long)(pid_t)parsedOldPid != parsedOldPid) {
            JBLogError("ignoring invalid previous jailbreakd pid environment value");
        } else {
            pid_t oldpid = (pid_t)parsedOldPid;
            if (oldpid != pid) {
                pid_t result;
                do {
                    result = waitpid(oldpid, NULL, WNOHANG);
                } while (result == -1 && errno == EINTR);
                if (result == 0) {
                    JBLogError("previous jailbreakd pid=%d still alive at handoff; scheduling nonblocking reap", oldpid);
                    scheduleJailbreakdParentReap(oldpid, 50);
                } else if (result == -1 && errno != ECHILD) {
                    JBLogError("waitpid failed for previous jailbreakd pid=%d errno=%d", oldpid, errno);
                }
            }
        }
    }

    char buf[32];
    snprintf(buf, sizeof(buf), "%d", pid);
    if (setenv("JAILBREAKD_PID", buf, 1) != 0) {
        JBLogError("failed to update JAILBREAKD_PID for pid=%d errno=%d", pid, errno);
    }
    pthread_mutex_unlock(&__jailbreakd_process_mutex);
}

static kern_return_t prepareJailbreakdBootstrapPort(mach_port_t *bootstrapPort)
{
    if (!bootstrapPort) return KERN_FAILURE;

    if (MACH_PORT_VALID(*bootstrapPort)) {
        kern_return_t destroyError = mach_port_destroy(mach_task_self(), *bootstrapPort);
        if (destroyError != KERN_SUCCESS) {
            JBLogError("failed to clean partial jailbreakd bootstrap port: %x,%s", destroyError, mach_error_string(destroyError));
            return destroyError;
        }
        *bootstrapPort = MACH_PORT_NULL;
    }

    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, bootstrapPort);
    if (kr != KERN_SUCCESS) {
        *bootstrapPort = MACH_PORT_NULL;
        JBLogError("jailbreakd bootstrap mach_port_allocate failed: %x,%s", kr, mach_error_string(kr));
        return kr;
    }

    kr = mach_port_insert_right(mach_task_self(), *bootstrapPort, *bootstrapPort, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        JBLogError("jailbreakd bootstrap mach_port_insert_right failed: %x,%s", kr, mach_error_string(kr));
        kern_return_t destroyError = mach_port_destroy(mach_task_self(), *bootstrapPort);
        if (destroyError == KERN_SUCCESS) *bootstrapPort = MACH_PORT_NULL;
        else JBLogError("failed to destroy partial bootstrap port: %x", destroyError);
        return kr;
    }
    return KERN_SUCCESS;
}

int spawnJailbreakd()
{
	if (getpid() != 1) {
		JBLogError("spawnJailbreakd called outside launchd: pid=%d", getpid());
		return -1;
	}

	uint64_t candidateGeneration = 0;
	mach_port_t candidatePort = MACH_PORT_NULL;
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (__jailbreakd_candidate_pending && !__jailbreakd_port_ready &&
	    __jailbreakd_expected_pid == 0 && __jailbreakd_child_pid == 0 &&
	    MACH_PORT_VALID(gJailbreakdPort)) {
		candidateGeneration = __jailbreakd_port_generation;
		candidatePort = gJailbreakdPort;
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	if (candidateGeneration == 0) {
		JBLogError("spawnJailbreakd called without an available check-in candidate");
		return EBUSY;
	}


	static mach_port_t bootstraport = MACH_PORT_NULL;
	static dispatch_source_t source = NULL;
	static bool bootstrapReady = false;

	/* Calls are serialized by __jailbreakd_restart_mutex; keep failures retryable. */
	if (!bootstrapReady) {
		kern_return_t bootstrapError = prepareJailbreakdBootstrapPort(&bootstraport);
		if (bootstrapError != KERN_SUCCESS) {
			jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
			return bootstrapError;
		}
		JBLogDebug("jailbreakd bootstrap port: %x", bootstraport);

		source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)bootstraport, 0, dispatch_get_global_queue(0,0));
		if (!source) {
			JBLogError("failed to create jailbreakd bootstrap receive source");
			kern_return_t destroyError = mach_port_destroy(mach_task_self(), bootstraport);
			if (destroyError != KERN_SUCCESS) JBLogError("failed to destroy bootstrap port after source failure: %x", destroyError);
			else bootstraport = MACH_PORT_NULL;
			jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
			return ENOMEM;
		}
		dispatch_source_set_event_handler(source, ^{
			JBLogDebug("received message from jailbreakd");
			xpc_object_t xdict = NULL;
			int err = xpc_pipe_receive(bootstraport, &xdict);
			if(err == 0) {
				/* This raw bootstrap port receives jailbreakd requests before the
				 * normal xpc hook can see them. Process and reply to them here. */
				struct jbserver_impl *globalServer = dlsym(RTLD_DEFAULT, "gGlobalServer");
				int (*receiveMessage)(struct jbserver_impl *, xpc_object_t) =
					dlsym(RTLD_DEFAULT, "jbserver_received_xpc_message");
				bool isDictionary = xdict && xpc_get_type(xdict) == XPC_TYPE_DICTIONARY;
				roothide_stage_file_log(ROOTHIDE_BOOTSTRAP_STAGE_LOG_PATH,
					"bootstrap.dispatch.begin domain=%llu action=%llu server_found=%d handler_found=%d",
					(unsigned long long)(isDictionary ? xpc_dictionary_get_uint64(xdict, "jb-domain") : 0),
					(unsigned long long)(isDictionary ? xpc_dictionary_get_uint64(xdict, "action") : 0), globalServer != NULL, receiveMessage != NULL);
				int handled = (globalServer && receiveMessage)
					? receiveMessage(globalServer, xdict)
					: -1;
				roothide_stage_file_log(ROOTHIDE_BOOTSTRAP_STAGE_LOG_PATH, "bootstrap.dispatch.end result=%d", handled);
				if (handled != 0) {
					JBLogError("jailbreakd bootstrap request failed: %d", handled);
					if (isDictionary) {
						xpc_object_t errorReply = xpc_dictionary_create_reply(xdict);
						if (errorReply) {
							xpc_dictionary_set_int64(errorReply, "result", handled);
							roothide_stage_file_log(ROOTHIDE_BOOTSTRAP_STAGE_LOG_PATH,
								"bootstrap.dispatch.error_reply.begin result=%d", handled);
							xpc_pipe_routine_reply(errorReply);
							roothide_stage_file_log(ROOTHIDE_BOOTSTRAP_STAGE_LOG_PATH,
								"bootstrap.dispatch.error_reply.end result=%d", handled);
							xpc_release(errorReply);
						} else {
							roothide_stage_file_log(ROOTHIDE_BOOTSTRAP_STAGE_LOG_PATH,
								"bootstrap.dispatch.error_reply.create_failed result=%d", handled);
						}
					} else {
						roothide_stage_file_log(ROOTHIDE_BOOTSTRAP_STAGE_LOG_PATH,
								"bootstrap.dispatch.error_reply.skipped non_dictionary=1 result=%d", handled);
					}
				}
				xpc_release(xdict);
			}
		});
		dispatch_resume(source);
		bootstrapReady = true;
	}


	pid_t pid;
	posix_spawnattr_t attr = NULL;
	int attrResult = posix_spawnattr_init(&attr);
	if (attrResult != 0) {
		jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
		return attrResult;
	}
	attrResult = posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
	if (attrResult != 0) {
		posix_spawnattr_destroy(&attr);
		JBLogError("posix_spawnattr_setflags failed for suspended jailbreakd: %d", attrResult);
		jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
		return attrResult;
	}
	// posix_spawnattr_setspecialport_np(&attr, bootstraport, TASK_BOOTSTRAP_PORT);
	// posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ bootstraport, MACH_PORT_NULL }, 3);
	attrResult = posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ MACH_PORT_NULL, MACH_PORT_NULL, bootstraport }, 3);
	if (attrResult != 0) {
		posix_spawnattr_destroy(&attr);
		JBLogError("posix_spawnattr_set_registered_ports_np failed: %d", attrResult);
		jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
		return attrResult;
	}
	uint8_t tokenBytes[16];
	char checkinToken[33];
	char tokenEnvironment[64];
	char respawnEnvironment[] = "RESPAWN_REQUIRED=1";
	arc4random_buf(tokenBytes, sizeof(tokenBytes));
	snprintf(checkinToken, sizeof(checkinToken),
	         "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
	         tokenBytes[0], tokenBytes[1], tokenBytes[2], tokenBytes[3],
	         tokenBytes[4], tokenBytes[5], tokenBytes[6], tokenBytes[7],
	         tokenBytes[8], tokenBytes[9], tokenBytes[10], tokenBytes[11],
	         tokenBytes[12], tokenBytes[13], tokenBytes[14], tokenBytes[15]);
	snprintf(tokenEnvironment, sizeof(tokenEnvironment), "JAILBREAKD_CHECKIN_TOKEN=%s", checkinToken);
	if (jailbreakdServerPortSetCheckinToken(candidateGeneration, candidatePort, checkinToken) != 0) {
		posix_spawnattr_destroy(&attr);
		jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
		return EAGAIN;
	}

	size_t inheritedCount = 0;
	if (__firstLoad && environ) while (environ[inheritedCount]) inheritedCount++;
	char **spawnEnvironment = calloc(inheritedCount + 3, sizeof(char *));
	if (!spawnEnvironment) {
		posix_spawnattr_destroy(&attr);
		jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
		return ENOMEM;
	}
	size_t environmentIndex = 0;
	for (size_t i = 0; i < inheritedCount; i++) {
		if (strncmp(environ[i], "JAILBREAKD_CHECKIN_TOKEN=", 25) == 0 ||
		    strncmp(environ[i], "RESPAWN_REQUIRED=", 17) == 0) continue;
		spawnEnvironment[environmentIndex++] = environ[i];
	}
	spawnEnvironment[environmentIndex++] = tokenEnvironment;
	if (!__firstLoad) spawnEnvironment[environmentIndex++] = respawnEnvironment;
	spawnEnvironment[environmentIndex] = NULL;
	int ret = posix_spawn(&pid, JBROOT_PATH("/basebin/jailbreakd"), NULL, &attr,
	                      (char*[]){"jailbreakd",NULL}, spawnEnvironment);
	free(spawnEnvironment);
	posix_spawnattr_destroy(&attr);

	if (ret != 0) {
		JBLogError("posix_spawn jailbreakd failed: %d\n", ret);
		jailbreakdServerPortAbandonCandidate(candidateGeneration, candidatePort);
		return ret;
	}

	JBLogDebug("jailbreakd spawned, pid=%d\n", pid);

	/* The child is still suspended: publish its identity before it can check in. */
	bool registered = false;
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (__jailbreakd_candidate_pending && !__jailbreakd_port_ready &&
	    __jailbreakd_port_generation == candidateGeneration && gJailbreakdPort == candidatePort &&
	    __jailbreakd_expected_pid == 0 && __jailbreakd_child_pid == 0) {
		__jailbreakd_expected_pid = pid;
		__jailbreakd_child_pid = pid;
		registered = true;
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	if (!registered) {
		kill(pid, SIGKILL);
		waitpid(pid, NULL, WNOHANG);
		JBLogError("discarded suspended jailbreakd pid=%d after candidate changed", pid);
		return EAGAIN;
	}

	setJailbreakdProcess(pid);
	/* here we can't wait for jailbreakd to initialize since opainject will suspend all other threads */
	scheduleJailbreakdServerPortCheckinWatchdog();
	if (kill(pid, SIGCONT) != 0) {
		int resumeError = errno;
		jailbreakd_checkin_ticket_t ticket = {
			.pid = pid,
			.generation = candidateGeneration,
			.port = candidatePort,
		};
		jailbreakdServerPortCheckinFailed(&ticket);
		JBLogError("failed to resume suspended jailbreakd pid=%d errno=%d", pid, resumeError);
		return resumeError;
	}

	return 0;
}

int initJailbreakd(bool firstLoad)
{
	if (getpid() != 1) {
		JBLogError("initJailbreakd called outside launchd: pid=%d", getpid());
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_restart_mutex);
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	// launchdhook can be loaded more than once during injection or handoff.
	// A duplicate initialization must not abort launchd.
	if (__jailbreakd_initialized) {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		JBLogDebug("initJailbreakd: already initialized");
		return 0;
	}

	__firstLoad = firstLoad;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	if(registerServerPort() != 0) {
		JBLogError("registerServerPort failed");
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	__jailbreakd_initialized = true;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	int ret = spawnJailbreakd();
	if (ret != 0) {
		JBLogError("spawnJailbreakd failed during init: %d", ret);
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return ret;
	}

	pthread_mutex_unlock(&__jailbreakd_restart_mutex);
	return 0;
}

mach_port_t reactiveJailbreakdPort()
{
	/* A dead jailbreakd must not turn into an abort of launchd. */
	if (getpid() != 1) {
		return MACH_PORT_NULL;
	}

	mach_port_t port = MACH_PORT_NULL;
	bool wasReady = false;
	bool shouldRestart = false;
	pid_t childToStop = 0;

	pthread_mutex_lock(&__jailbreakd_restart_mutex);
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (!__jailbreakd_initialized) {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return MACH_PORT_NULL;
	}

	wasReady = __jailbreakd_port_ready;
	if (wasReady && MACH_PORT_VALID(gJailbreakdPort)) {
		kern_return_t kr = mach_port_mod_refs(mach_task_self(), gJailbreakdPort, MACH_PORT_RIGHT_SEND, 1);
		if (kr == KERN_SUCCESS) {
			port = gJailbreakdPort;
		} else {
			JBLogError("jailbreakd port is dead: %x,%s port=%x", kr, mach_error_string(kr), gJailbreakdPort);
			__jailbreakd_port_ready = false;
			__jailbreakd_candidate_pending = false;
			__jailbreakd_expected_pid = 0;
			childToStop = __jailbreakd_child_pid;
			advanceJailbreakdPortGenerationLocked();
			shouldRestart = true;
		}
	} else if (wasReady || !MACH_PORT_VALID(gJailbreakdPort) || !__jailbreakd_candidate_pending) {
		__jailbreakd_port_ready = false;
		shouldRestart = true;
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	if (MACH_PORT_VALID(port) || !shouldRestart) {
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return port;
	}
	terminateJailbreakdChild(childToStop);

	if (wasReady) {
		/* Make jailbreakd crashes perceptible, but never expose the replacement candidate. */
		sleep(5);
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	bool previousChildExited = reapJailbreakdChildIfExitedLocked();
	pid_t previousChildPid = __jailbreakd_child_pid;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	if (!previousChildExited) {
		JBLogError("deferring jailbreakd restart while prior child remains alive pid=%d", previousChildPid);
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return MACH_PORT_NULL;
	}

	if (registerServerPort() != 0) {
		JBLogError("registerServerPort failed while restarting jailbreakd");
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return MACH_PORT_NULL;
	}

	int ret = spawnJailbreakd();
	if (ret != 0) {
		JBLogError("spawnJailbreakd failed while restarting: %d", ret);
	}

	/* The candidate remains private until the daemon checks in successfully. */
	pthread_mutex_unlock(&__jailbreakd_restart_mutex);
	return MACH_PORT_NULL;
}

mach_port_t jailbreakdServerPort()
{
	if (getpid() != 1) {
		return MACH_PORT_NULL;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	mach_port_t port = gJailbreakdPort;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return port;
}

mach_port_t jailbreakdClientPort()
{
	mach_port_t port = MACH_PORT_NULL;

	if(getpid() == 1)
	{
		bool shouldRestart = false;
		pthread_mutex_lock(&__jailbreakd_port_mutex);
		if (__jailbreakd_port_ready && MACH_PORT_VALID(gJailbreakdPort)) {
			kern_return_t kr = mach_port_mod_refs(mach_task_self(), gJailbreakdPort, MACH_PORT_RIGHT_SEND, 1);
			if (kr == KERN_SUCCESS) {
				port = gJailbreakdPort;
			} else {
				JBLogError("jailbreakd port dead: %x,%s port=%x", kr, mach_error_string(kr), gJailbreakdPort);
				shouldRestart = true;
			}
		} else if (__jailbreakd_initialized &&
		           (!MACH_PORT_VALID(gJailbreakdPort) || !__jailbreakd_candidate_pending)) {
			shouldRestart = true;
		}
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		if (shouldRestart) {
			port = reactiveJailbreakdPort();
		}
	}
	else
	{

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
		port = jailbreakdClientPortFastGet();
		if(!MACH_PORT_VALID(port))
		{
#endif

			port = jbclient_jailbreakd_lookup();

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
		}
#endif

	}

	return port;
}

// xpc_object_t jailbreakdRequestViaLaunchd(xpc_object_t xdict)
// {
// 	// to do
// }

xpc_object_t jailbreakdXpcRequest(xpc_object_t xdict)
{
	uint64_t requestId = xdict && xpc_get_type(xdict) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_uint64(xdict, "id") : 0;
	roothide_stage_log("jbd.port_lookup.begin id=%llu", (unsigned long long)requestId);
	mach_port_t port = jailbreakdClientPort();
	roothide_stage_log("jbd.port_lookup.end id=%llu port=%x valid=%d", (unsigned long long)requestId, port, MACH_PORT_VALID(port));
	if (!MACH_PORT_VALID(port)) {
		JBLogError("invalid jailbreakdClientPort: %x", port);
		return NULL;
	}
	
	xpc_object_t xreply = NULL;
	roothide_stage_log("jbd.pipe_create.begin id=%llu", (unsigned long long)requestId);
	xpc_object_t pipe = xpc_pipe_create_from_port(port, 0);
	roothide_stage_log("jbd.pipe_create.end id=%llu created=%d", (unsigned long long)requestId, pipe != NULL);
	if (pipe) {
		roothide_stage_log("jbd.rpc.begin id=%llu", (unsigned long long)requestId);
		int err = xpc_pipe_routine(pipe, xdict, &xreply);
		roothide_stage_log("jbd.rpc.end id=%llu error=%d reply=%d", (unsigned long long)requestId, err, xreply != NULL);
		if (err != 0) {
			char *desc = NULL;
			JBLogError("xpc_pipe_routine error on sending message to jailbreakd: %d / %s\n%s", err, xpc_strerror(err), (desc=xpc_copy_description(xdict)));
			if(desc) free(desc);
			if(xreply) xpc_release(xreply);
			xreply = NULL;
		};
	} else {
		JBLogError("xpc_pipe_create_from_port failed");
	}

	mach_port_deallocate(mach_task_self(), port);

	if(pipe) xpc_release(pipe);
	return xreply;
}

int jbdTestCall(int value)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_TEST_CALL);
	xpc_dictionary_set_int64(message, "value", value);

	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}

int jbdSystemwideLog(const char* fmt, ...)
{
	char* log = NULL;

	va_list args;
	va_start(args, fmt);
	vasprintf(&log, fmt, args);
	va_end(args);

	__uint64_t tid = 0;
	pthread_threadid_np(pthread_self(), &tid);

	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SYSTEMWIDE_LOG);
	xpc_dictionary_set_uint64(message, "tid", tid);
	xpc_dictionary_set_string(message, "log", log);

	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	free(log);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}

int jbdSpawnPatchChildEx(int pid, bool resume, bool forceDyldPatch)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPAWN_PATCH_CHILD);
	xpc_dictionary_set_int64(message, "pid", pid);
	xpc_dictionary_set_bool(message, "resume", resume);
	xpc_dictionary_set_bool(message, "force-dyld-patch", forceDyldPatch);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdSpawnPatchChild(int pid, bool resume)
{
	return jbdSpawnPatchChildEx(pid, resume, false);
}

int jbdSpinlockFixOnly(int pid, bool resume)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPINLOCK_FIX_ONLY);
	xpc_dictionary_set_int64(message, "pid", pid);
	xpc_dictionary_set_bool(message, "resume", resume);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdSpawnExecStart(const char* execfile, bool resume)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPAWN_EXEC_START);
	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_dictionary_set_bool(message, "resume", resume);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdSpawnExecCancel(const char* execfile)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPAWN_EXEC_CANCEL);
	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdExecTraceStart(const char* execfile, bool* traced)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_EXEC_TRACE_START);

	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_dictionary_set_uint64(message, "traced", (uint64_t)(void*)traced);

	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}

int jbdExecTraceCancel(const char* execfile, bool* detached)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_EXEC_TRACE_CANCEL);

	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_dictionary_set_uint64(message, "detached", (uint64_t)(void*)detached);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}
