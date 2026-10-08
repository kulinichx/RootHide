#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include "jbclient_xpc.h"
#include "jbserver.h"

#include "roothide_stage.h"
#include "roothider/log.h"
#include "roothider/xpc_private.h"

#ifdef ENABLE_LOGS
void (*XPCLogDebugFunction)(const char *format, ...);
void (*XPCLogErrorFunction)(const char *format, ...);

#define JBLogDebug(...) do { if(XPCLogDebugFunction)XPCLogDebugFunction(__VA_ARGS__); } while(0)
#define JBLogError(...) do { if(XPCLogErrorFunction)XPCLogErrorFunction(__VA_ARGS__); } while(0)

void enableXPCLog(void* debugLog, void* errorLog)
{
	XPCLogDebugFunction = debugLog;
	XPCLogErrorFunction = errorLog;
}
#endif

mach_port_t jbclient_jailbreakd_lookup()
{
	mach_port_t port = MACH_PORT_NULL;
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_JAILBREAKD_LOOKUP, NULL);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		if(result == 0) {
			xpc_object_t portobj = xpc_dictionary_get_value(xreply, "port");
			if (portobj) {
				port = xpc_mach_send_copy_right(portobj);
			}
		}
		xpc_release(xreply);
	}
	return port;
}

mach_port_t jbclient_jailbreakd_checkin()
{
	mach_port_t port = MACH_PORT_NULL;
	xpc_object_t xargs = xpc_dictionary_create_empty();
	if (!xargs) return port;
	const char *checkinToken = getenv("JAILBREAKD_CHECKIN_TOKEN");
	if (checkinToken) xpc_dictionary_set_string(xargs, "checkin-token", checkinToken);
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_JAILBREAKD_CHECKIN, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		xpc_object_t portobj = xpc_dictionary_get_value(xreply, "port");
		roothide_stage_log("jailbreakd.checkin.reply result=%lld has_port=%d type=%s",
		                   (long long)result, portobj != NULL,
		                   portobj ? xpc_type_get_name(xpc_get_type(portobj)) : "none");
		if(result == 0) {
			if (portobj) {
				port = xpc_mach_recv_extract_right(portobj);
			}
		}
		xpc_release(xreply);
	} else {
		roothide_stage_log("jailbreakd.checkin.reply missing");
	}
	roothide_stage_log("jailbreakd.checkin.port value=%x valid=%d", port, MACH_PORT_VALID(port));
	return port;
}

static int jbclient_jailbreakd_report_readiness(bool ready)
{
    const char *checkinToken = getenv("JAILBREAKD_CHECKIN_TOKEN");
    if (!checkinToken) return -1;

    int result = -1;
    /* READY is idempotent for the same PID, generation and check-in token on
     * launchd. A successful commit can lose its reply; allow the next request
     * to confirm it. This is bounded recovery, not a delivery guarantee. */
    for (unsigned int attempt = 0; attempt < 3; attempt++) {
        xpc_object_t xargs = xpc_dictionary_create_empty();
        if (!xargs) break;
        xpc_dictionary_set_string(xargs, "checkin-token", checkinToken);
        xpc_dictionary_set_bool(xargs, "ready", ready);
        xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_JAILBREAKD_READY, xargs);
        xpc_release(xargs);
        if (!xreply) continue;

        /* A non-dictionary reply, or a dictionary without a typed result,
         * must not end the retry loop as though launchd rejected readiness. */
        if (xpc_get_type(xreply) == XPC_TYPE_DICTIONARY) {
            xpc_object_t resultObject = xpc_dictionary_get_value(xreply, "result");
            if (resultObject && xpc_get_type(resultObject) == XPC_TYPE_INT64) {
                result = (int)xpc_dictionary_get_int64(xreply, "result");
                xpc_release(xreply);
                break; /* Authoritative success or explicit server rejection. */
            }
        }
        xpc_release(xreply);
    }
    if (ready && result == 0) unsetenv("JAILBREAKD_CHECKIN_TOKEN");
    return result;
}

int jbclient_jailbreakd_ready(void)
{
    return jbclient_jailbreakd_report_readiness(true);
}

int jbclient_jailbreakd_checkin_failed(void)
{
    return jbclient_jailbreakd_report_readiness(false);
}

bool jbclient_roothide_jailbroken()
{
	bool jailbroken = false;

    xpc_object_t xargs = xpc_dictionary_create_empty();
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_JAILBROKEN_CHECK, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		if(result == 0) {
			jailbroken = xpc_dictionary_get_bool(xreply, "jailbroken");
		}
		xpc_release(xreply);
	}

	return jailbroken;
}

bool jbclient_blacklist_check_pid(pid_t pid)
{
	bool blacklisted = false;

    xpc_object_t xargs = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(xargs, "checktype", "pid");
    xpc_dictionary_set_uint64(xargs, "checkvalue", pid);
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_BLACKLIST_CHECK, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		if(result == 0) {
			blacklisted = xpc_dictionary_get_bool(xreply, "blacklisted");
		}
		xpc_release(xreply);
	}

	return blacklisted;
}

bool jbclient_blacklist_check_path(const char* path)
{
	bool blacklisted = false;

    xpc_object_t xargs = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(xargs, "checktype", "path");
    xpc_dictionary_set_string(xargs, "checkvalue", path);
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_BLACKLIST_CHECK, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		if(result == 0) {
			blacklisted = xpc_dictionary_get_bool(xreply, "blacklisted");
		}
		xpc_release(xreply);
	}

	return blacklisted;
}

bool jbclient_blacklist_check_bundle(const char* bundle)
{
	bool blacklisted = false;

    xpc_object_t xargs = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(xargs, "checktype", "bundle");
    xpc_dictionary_set_string(xargs, "checkvalue", bundle);
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_BLACKLIST_CHECK, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		if(result == 0) {
			blacklisted = xpc_dictionary_get_bool(xreply, "blacklisted");
		}
		xpc_release(xreply);
	}

	return blacklisted;
}

int jbclient_trust_executable_recurse(const char *executablePath, xpc_object_t preferredArchsArray)
{
	if (!executablePath) return -1;

	if(access(executablePath, F_OK) != 0) {
		return -2;
	}

	xpc_object_t xargs = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(xargs, "executable-path", executablePath);

	char* cwd = getcwd(NULL, 0);
	if(cwd) {
		xpc_dictionary_set_string(xargs, "process-working-dir", cwd);
		free((void*)cwd);
	}

	if (preferredArchsArray) {
		xpc_dictionary_set_value(xargs, "preferred-archs", preferredArchsArray);
	}

	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_TRUST_EXECUTABLE_RECURSE, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		xpc_release(xreply);
		return result;
	}
	return -1;
}

extern const char* dyld_image_path_containing_address(const void* addr);

int jbclient_trust_library_recurse(const char *libraryPath, void *addressInCaller)
{
	if (!libraryPath) return -1;

	if (_dyld_shared_cache_contains_path(libraryPath)) {
		return -1;
	}
	
	if(libraryPath[0] != '@') {
		if(access(libraryPath, F_OK) != 0) {
			return -3;
		}
	}

	xpc_object_t xargs = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(xargs, "library-path", libraryPath);

	if(addressInCaller) {
		const char* callerPath = dyld_image_path_containing_address(addressInCaller);
		if (callerPath) {
			xpc_dictionary_set_string(xargs, "caller-library-path", callerPath);
		}
	}

	char* cwd = getcwd(NULL, 0);
	if(cwd) {
		xpc_dictionary_set_string(xargs, "current-working-dir", cwd);
		free((void*)cwd);
	}


	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_TRUST_LIBRARY_RECURSE, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		xpc_release(xreply);
		return result;
	}
	return -1;
}

bool jbclient_dyld_patch_enabled()
{
	static bool enabled = false;

	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		xpc_object_t xargs = xpc_dictionary_create_empty();
		xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_DYLD_PATCH_ENABLED_GET, xargs);
		xpc_release(xargs);
		if (xreply) {
			int64_t result = xpc_dictionary_get_int64(xreply, "result");
			if(result == 0) {
				enabled = xpc_dictionary_get_bool(xreply, "enabled");
			}
			xpc_release(xreply);
		}
	});

	return enabled;
}

int jbclient_set_dyld_patch(bool enabled)
{
    xpc_object_t xargs = xpc_dictionary_create_empty();
	xpc_dictionary_set_bool(xargs, "enabled", enabled);
	xpc_object_t xreply = jbserver_xpc_send(JBS_DOMAIN_ROOTHIDE, JBS_ROOTHIDE_DYLD_PATCH_ENABLED_SET, xargs);
	xpc_release(xargs);
	if (xreply) {
		int64_t result = xpc_dictionary_get_int64(xreply, "result");
		xpc_release(xreply);
		return result;
	}
	return -1;
}
