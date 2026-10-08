#include <Foundation/Foundation.h>
#include <errno.h>
#include <kern_memorystatus.h>
#include <mach-o/dyld.h>
#include <libproc.h>
#include <spawn.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/roothider.h>
#include <libjailbreak/roothide_stage.h>

extern char **environ;

void jailbreakd_received_message(mach_port_t port);

int posix_spawnattr_setspecialport_np(posix_spawnattr_t *attr, mach_port_t new_port, int which);
int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t * __restrict attr, mach_port_t portarray[], uint32_t count);

void setJetsamLimit(uint32_t sizeInMB, bool is_fatal_limit)
{
	uint32_t cmd = is_fatal_limit ? MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT : MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK;
	int rc = memorystatus_control(cmd, getpid(), sizeInMB, NULL, 0);
	if (rc < 0) { perror ("memorystatus_control"); exit(rc);}
}

void enableXPCLog(void* debugLog, void* errorLog);

static void scheduleRespawnedJailbreakdChildReap(pid_t pid, unsigned int retriesRemaining)
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
			scheduleRespawnedJailbreakdChildReap(pid, retriesRemaining - 1);
			return;
		}
		JBLogError("deferred reap failed for respawned jailbreakd pid=%d errno=%d", pid, errno);
	});
}

static void terminateRespawnedJailbreakdChild(pid_t pid)
{
	if (pid <= 1) return;

	int signalResult;
	do {
		signalResult = kill(pid, SIGKILL);
	} while (signalResult != 0 && errno == EINTR);
	if (signalResult != 0 && errno != ESRCH) {
		JBLogError("failed to terminate suspended jailbreakd pid=%d errno=%d", pid, errno);
	}

	/* Never block the surviving daemon waiting for SIGKILL to complete. */
	int status = 0;
	pid_t result;
	do {
		result = waitpid(pid, &status, WNOHANG);
	} while (result == -1 && errno == EINTR);
	if (result == 0) {
		JBLogError("suspended jailbreakd pid=%d remains alive after nonblocking cleanup", pid);
		scheduleRespawnedJailbreakdChildReap(pid, 20);
	} else if (result == -1 && errno != ECHILD) {
		JBLogError("nonblocking reap failed for jailbreakd pid=%d errno=%d", pid, errno);
	}
}

static int initializeRespawnedJailbreakdAttributes(posix_spawnattr_t *attr, mach_port_t bootstrapPort)
{
	int attrError = posix_spawnattr_init(attr);
	if (attrError != 0) return attrError;

	attrError = posix_spawnattr_setflags(attr, POSIX_SPAWN_START_SUSPENDED);
	if (attrError != 0) {
		JBLogError("posix_spawnattr_setflags jailbreakd failed: %d, %s", attrError, strerror(attrError));
		posix_spawnattr_destroy(attr);
		return attrError;
	}

	attrError = posix_spawnattr_set_registered_ports_np(attr, (mach_port_t[]){ MACH_PORT_NULL, MACH_PORT_NULL, bootstrapPort }, 3);
	if (attrError != 0) {
		JBLogError("posix_spawnattr_set_registered_ports_np jailbreakd failed: %d, %s", attrError, strerror(attrError));
		posix_spawnattr_destroy(attr);
		return attrError;
	}
	return 0;
}

int main(int argc, char* argv[])
{
	if (@available(iOS 17.0, *)) {
		int logResult = roothide_stage_begin(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH, true);
		roothide_stage_log("jailbreakd.start log_open_result=%d uid=%d ppid=%d", logResult, getuid(), getppid());
	}
	roothide_stage_log("jailbreakd.crashreporter.begin");
	crashreporter_start();
	roothide_stage_log("jailbreakd.crashreporter.end");

	setJetsamLimit(50, false);
	roothide_stage_log("jailbreakd.jetsam.end");

#ifdef ENABLE_LOGS
	enableXPCLog(JBLogDebugFunction, JBLogErrorFunction);
	enableJBDLog(JBLogDebugFunction, JBLogErrorFunction);
#endif

	JBLogDebug("Hello from jailbrakd! uid=%d pid=%d ppid=%d", getuid(), getpid(), getppid());

	@autoreleasepool {

		mach_port_t *registeredPorts=NULL;
		mach_msg_type_number_t registeredPortsCount = 0;
		kern_return_t kr = mach_ports_lookup(mach_task_self(), &registeredPorts, &registeredPortsCount);
		roothide_stage_log("jailbreakd.registered_ports result=%d count=%u", kr, registeredPortsCount);
		if(kr != KERN_SUCCESS || registeredPortsCount < 3) {
			JBLogError("mach_ports_lookup error: %d, %x, %s", registeredPortsCount, kr, mach_error_string(kr));
			return 1;
		}
		for(int i=0; i<registeredPortsCount; i++) {
			JBLogDebug("registeredPorts[%d]: %x", i, registeredPorts[i]);
		}

		mach_port_t bootstraport = registeredPorts[2];
		roothide_stage_log("jailbreakd.bootstrap_port port=%x valid=%d", bootstraport, MACH_PORT_VALID(bootstraport));
		if(!MACH_PORT_VALID(bootstraport)) {
			JBLogError("invalid bootstraport");
			return 2;
		}
		JBLogDebug("bootstraport: %x", bootstraport);

		registeredPorts[2] = MACH_PORT_NULL;
		mach_ports_register(mach_task_self(), registeredPorts, registeredPortsCount);

		JBLogDebug("start initializing jb primitives");
		jbclient_xpc_set_custom_port(bootstraport);
		int ret = jbclient_initialize_primitives();
		roothide_stage_log("jailbreakd.primitives.end result=%d", ret);
		JBLogDebug("jbclient_initialize_primitives ret: %d", ret);
		if(ret != 0) {
			JBLogError("Failed to initialize jailbreak primitives: %d", ret);
			return 3;
		}

		if(getenv("RESPAWN_REQUIRED"))
		{
			unsetenv("RESPAWN_REQUIRED");

			char selfPath[PATH_MAX]={0};
			uint32_t selfPathSize = sizeof(selfPath);
			int pathResult = _NSGetExecutablePath(selfPath, &selfPathSize);
			if (pathResult != 0) {
				JBLogError("_NSGetExecutablePath failed for jailbreakd: %d", pathResult);
				return 4;
			}
	
			pid_t pid;
			posix_spawnattr_t attr = NULL;
			int attrError = initializeRespawnedJailbreakdAttributes(&attr, bootstraport);
			if(attrError != 0) {
				JBLogError("failed to initialize suspended jailbreakd spawn attributes: %d, %s", attrError, strerror(attrError));
				return 4;
			}
			// posix_spawnattr_setspecialport_np(&attr, bootstraport, TASK_BOOTSTRAP_PORT);
			// posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ bootstraport, MACH_PORT_NULL }, 3);
			int ret = posix_spawn(&pid, selfPath, NULL, &attr, argv, environ);
			posix_spawnattr_destroy(&attr);

			if(ret != 0) {
				JBLogError("posix_spawn jailbreakd failed: %d, %s", ret, strerror(ret));
				return 4;
			}

			JBLogDebug("jailbreakd respawned: %d", pid);
	
			int unrestrictResult = unrestrict(pid, proc_patch_dyld, false);
			if(unrestrictResult != 0) {
				JBLogError("Failed to unrestrict process %d: %d", pid, unrestrictResult);
				terminateRespawnedJailbreakdChild(pid);
				return 5;
			}

			if(dyld_patch_enabled()) {
				if (kill(pid, SIGCONT) != 0) {
					int resumeError = errno;
					JBLogError("Failed to resume respawned jailbreakd pid=%d errno=%d", pid, resumeError);
					terminateRespawnedJailbreakdChild(pid);
					return 7;
				}
				return 0;
			} else {
				terminateRespawnedJailbreakdChild(pid);
			}
		}

		JBLogDebug("check in jailbreakd port...");
		char ownPath[PATH_MAX] = {0};
		const char *actualPath = proc_get_path(getpid(), ownPath);
		roothide_stage_log("jailbreakd.checkin.identity actual=%s expected=%s", actualPath ? actualPath : "<unknown>", JBROOT_PATH("/basebin/jailbreakd"));
		roothide_stage_log("jailbreakd.checkin.begin");
		mach_port_t serverPort = jbclient_jailbreakd_checkin();
		roothide_stage_log("jailbreakd.checkin.end port=%x valid=%d", serverPort, MACH_PORT_VALID(serverPort));
		if (!MACH_PORT_VALID(serverPort)) {
			JBLogError("Failed to check in server port");
			return 6;
		}

		JBLogDebug("starting jailbreakd server, port=%x", serverPort);

		dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)serverPort, 0, dispatch_get_main_queue());
		if (!source) {
		JBLogError("failed to create jailbreakd server receive source for port=%x", serverPort);
		kern_return_t destroyResult = mach_port_destroy(mach_task_self(), serverPort);
		if (destroyResult != KERN_SUCCESS) JBLogError("failed to destroy jailbreakd receive port after source failure: %x", destroyResult);
		if (jbclient_jailbreakd_checkin_failed() != 0) JBLogError("launchd did not confirm check-in abort after server-source failure");
		return 8;
	}
	dispatch_source_set_event_handler(source, ^{
			jailbreakd_received_message(serverPort);
		});
		dispatch_resume(source);
		if (jbclient_jailbreakd_ready() != 0) {
			JBLogError("launchd rejected jailbreakd server-ready acknowledgement");
			dispatch_source_cancel(source);
			if (jbclient_jailbreakd_checkin_failed() != 0) JBLogError("launchd did not confirm check-in abort after ready failure");
			kern_return_t destroyResult = mach_port_destroy(mach_task_self(), serverPort);
			if (destroyResult != KERN_SUCCESS) JBLogError("failed to destroy port after ready acknowledgement failure: %x", destroyResult);
			return 9;
		}
		roothide_stage_log("jailbreakd.server.ready port=%x", serverPort);

		dispatch_main();
	}

	JBLogDebug("jailbreakd exit...");
	return 0;
}
