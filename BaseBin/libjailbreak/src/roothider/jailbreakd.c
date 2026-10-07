#include <spawn.h>
#include <unistd.h>
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <xpc/xpc.h>
#include <mach/mach.h>
#include <bsm/libbsm.h>
#include <sys/param.h>

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

static bool __firstLoad = false;
static bool __jailbreakd_initialized = false;
static bool __jailbreakd_port_ready = false;
static pthread_mutex_t __jailbreakd_port_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t __jailbreakd_restart_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t __jailbreakd_port_generation = 0;
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

int registerServerPort()
{
	if (getpid() != 1) {
		JBLogError("registerServerPort called outside launchd: pid=%d", getpid());
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (destroyLocalJailbreakdServerPortLocked() != 0) {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		return -1;
	}
	/* Invalidate any delayed watchdog associated with the previous candidate. */
	if (++__jailbreakd_port_generation == 0) {
		++__jailbreakd_port_generation;
	}

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
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return 0;
}

int jailbreakdServerPortCheckinComplete(void)
{
	if (getpid() != 1) {
		JBLogError("jailbreakdServerPortCheckinComplete called outside launchd: pid=%d", getpid());
		return -1;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (!MACH_PORT_VALID(gJailbreakdPort)) {
		pthread_mutex_unlock(&__jailbreakd_port_mutex);
		JBLogError("jailbreakd check-in completed without a valid server port");
		return -1;
	}

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
	mach_port_t self_host = mach_host_self();
	kern_return_t kr = host_set_special_port(self_host, HOST_LAUNCHCTL_PORT, gJailbreakdPort);
	mach_port_deallocate(mach_task_self(), self_host);
	if (kr != KERN_SUCCESS) {
		/* Keep the checked-in service available through the launchd lookup path. */
		JBLogError("host_set_special_port failed after jailbreakd check-in: %x,%s", kr, mach_error_string(kr));
	}
#endif

	__jailbreakd_port_ready = true;
	pthread_mutex_unlock(&__jailbreakd_port_mutex);
	return 0;
}

void jailbreakdServerPortCheckinFailed(void)
{
	if (getpid() != 1) {
		return;
	}

	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (!__jailbreakd_port_ready && destroyLocalJailbreakdServerPortLocked() != 0) {
		JBLogError("failed to discard an unready jailbreakd server port");
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
	pthread_mutex_lock(&__jailbreakd_port_mutex);
	if (generation == __jailbreakd_port_generation &&
	    !__jailbreakd_port_ready && MACH_PORT_VALID(gJailbreakdPort)) {
		timedOutPort = gJailbreakdPort;
		if (destroyLocalJailbreakdServerPortLocked() == 0) {
			if (++__jailbreakd_port_generation == 0) {
				++__jailbreakd_port_generation;
			}
			timedOut = true;
		}
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	if (timedOut) {
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
	if (!__jailbreakd_port_ready && MACH_PORT_VALID(gJailbreakdPort)) {
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

void setJailbreakdProcess(pid_t pid)
{
	//Reclaim the previous jailbreakd zombie process
	const char *pidenv = getenv("JAILBREAKD_PID");
	if (pidenv) 
	{
		pid_t oldpid = atoi(pidenv);
		if(oldpid != pid)
		{
			waitpid(oldpid, NULL, 0);
			unsetenv("JAILBREAKD_PID");
		}
	}

	char buf[32];
	snprintf(buf, sizeof(buf), "%d", pid);
	setenv("JAILBREAKD_PID", buf, 1);
}

int spawnJailbreakd()
{
	if (getpid() != 1) {
		JBLogError("spawnJailbreakd called outside launchd: pid=%d", getpid());
		return -1;
	}

	static mach_port_t bootstraport = MACH_PORT_NULL;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
		mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &bootstraport);
		mach_port_insert_right(mach_task_self(), bootstraport, bootstraport, MACH_MSG_TYPE_MAKE_SEND);
		JBLogDebug("jailbreakd bootstrap port: %x", bootstraport);

		static dispatch_source_t source; //retain the dispatch source
		source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)bootstraport, 0, dispatch_get_global_queue(0,0));
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
	});

	pid_t pid;
	posix_spawnattr_t attr = NULL;
	int attrResult = posix_spawnattr_init(&attr);
	if (attrResult != 0) {
		return attrResult;
	}
	// posix_spawnattr_setspecialport_np(&attr, bootstraport, TASK_BOOTSTRAP_PORT);
	// posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ bootstraport, MACH_PORT_NULL }, 3);
	posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ MACH_PORT_NULL, MACH_PORT_NULL, bootstraport }, 3);
	int ret = posix_spawn(&pid, JBROOT_PATH("/basebin/jailbreakd"), NULL, &attr, (char*[]){"jailbreakd",NULL}, __firstLoad ? NULL :  ((char*[]){"RESPAWN_REQUIRED=1", NULL}));
	posix_spawnattr_destroy(&attr);

	if (ret != 0) {
		JBLogError("posix_spawn jailbreakd failed: %d\n", ret);
		return ret;
	}

	JBLogDebug("jailbreakd spawned, pid=%d\n", pid);

	/* here we can't wait for jailbreakd to initialize since opainject will suspend all other threads */
	scheduleJailbreakdServerPortCheckinWatchdog();

	setJailbreakdProcess(pid);

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
		jailbreakdServerPortCheckinFailed();
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
			shouldRestart = true;
		}
	} else if (wasReady || !MACH_PORT_VALID(gJailbreakdPort)) {
		__jailbreakd_port_ready = false;
		shouldRestart = true;
	}
	pthread_mutex_unlock(&__jailbreakd_port_mutex);

	if (MACH_PORT_VALID(port) || !shouldRestart) {
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return port;
	}

	if (wasReady) {
		/* Make jailbreakd crashes perceptible, but never expose the replacement candidate. */
		sleep(5);
	}

	if (registerServerPort() != 0) {
		JBLogError("registerServerPort failed while restarting jailbreakd");
		pthread_mutex_unlock(&__jailbreakd_restart_mutex);
		return MACH_PORT_NULL;
	}

	int ret = spawnJailbreakd();
	if (ret != 0) {
		JBLogError("spawnJailbreakd failed while restarting: %d", ret);
		jailbreakdServerPortCheckinFailed();
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
		} else if (__jailbreakd_initialized && !MACH_PORT_VALID(gJailbreakdPort)) {
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
