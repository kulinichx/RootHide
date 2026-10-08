#include <signal.h>
#include "jbserver_global.h"

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/roothider.h>
#include <libjailbreak/roothide_stage.h>
#include <libjailbreak/codesign.h>
#include <os/log.h>
#include <limits.h>
#include <stdlib.h>

int roothide_unsupport_request()
{
	JBLogError("**************************** Unsupported request ****************************");
	return -1;
}

bool roothide_domain_allowed(audit_token_t clientToken)
{
	//its fast enough
	if(isBlacklistedToken(&clientToken)) {
		JBLogDebug("ignore xpc message from blacklisted process (%d),%s", audit_token_to_pid(clientToken), proc_get_path(audit_token_to_pid(clientToken),NULL));
		return false;
	}

	return true;
}

static bool roothide_privileged_action_allowed(audit_token_t *callerToken, const char *action)
{
	if (!callerToken) {
		JBLogError("%s: missing caller token", action);
		return false;
	}

	pid_t pid = audit_token_to_pid(*callerToken);
	if (pid <= 1 || isBlacklistedToken(callerToken)) {
		JBLogError("%s: denying caller pid=%d", action, pid);
		return false;
	}

	const char *processPath = proc_get_path(pid, NULL);
	if (!processPath || processPath[0] != '/') {
		JBLogError("%s: unable to resolve caller pid=%d", action, pid);
		return false;
	}

	return true;
}

typedef struct {
	uint32_t Count;
	uint32_t* Types;
	uint32_t* Subtypes;
} preferredArchInfo;
#define ROOTHIDE_MAX_PREFERRED_ARCHS 8

static bool roothide_path_argument_valid(const char *path, bool required, bool absolute)
{
    if (!path) return !required;
    size_t length = strnlen(path, PATH_MAX);
    if (length == 0 || length == PATH_MAX) return false;
    return !absolute || path[0] == '/';
}
int recurse_collect_untrusted_cdhashes(const char *path, const char *callerImagePath, const char *callerExecutablePath, const char *workingDir, preferredArchInfo* preferredArch, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut);

static int trust_macho_recurse(const char *machoPath, const char *dlopenCallerImagePath, const char *dlopenCallerExecutablePath, const char *workingDir, xpc_object_t preferredArchsArray)
{
	if(!machoPath || !dlopenCallerExecutablePath) return -1;
	
	size_t preferredArchCount = 0;
	if (preferredArchsArray) preferredArchCount = xpc_array_get_count(preferredArchsArray);
	if (preferredArchCount > ROOTHIDE_MAX_PREFERRED_ARCHS) {
		JBLogError("Rejecting %zu preferred architectures (maximum %d)", preferredArchCount, ROOTHIDE_MAX_PREFERRED_ARCHS);
		return -1;
	}

	uint32_t preferredArchTypes[ROOTHIDE_MAX_PREFERRED_ARCHS] = {0};
	uint32_t preferredArchSubtypes[ROOTHIDE_MAX_PREFERRED_ARCHS] = {0};
	for (size_t i = 0; i < preferredArchCount; i++) {
		xpc_object_t arch = xpc_array_get_value(preferredArchsArray, i);
		if (!arch || xpc_get_type(arch) != XPC_TYPE_DICTIONARY) {
			JBLogError("Invalid preferred architecture entry at index %zu", i);
			return -1;
		}

		xpc_object_t typeValue = xpc_dictionary_get_value(arch, "type");
		xpc_object_t subtypeValue = xpc_dictionary_get_value(arch, "subtype");
		if (!typeValue || xpc_get_type(typeValue) != XPC_TYPE_UINT64 ||
			!subtypeValue || xpc_get_type(subtypeValue) != XPC_TYPE_UINT64) {
			JBLogError("Invalid preferred architecture fields at index %zu", i);
			return -1;
		}

		uint64_t type = xpc_uint64_get_value(typeValue);
		uint64_t subtype = xpc_uint64_get_value(subtypeValue);
		if (type > UINT32_MAX || subtype > UINT32_MAX) {
			JBLogError("Preferred architecture value out of range at index %zu", i);
			return -1;
		}

		preferredArchTypes[i] = (uint32_t)type;
		preferredArchSubtypes[i] = (uint32_t)subtype;
	}
	
	preferredArchInfo preferredArch = {(uint32_t)preferredArchCount, preferredArchTypes, preferredArchSubtypes};

	cdhash_t *cdhashes = NULL;
	uint32_t cdhashesCount = 0;
	int collectResult = recurse_collect_untrusted_cdhashes(machoPath, dlopenCallerImagePath, dlopenCallerExecutablePath, workingDir, &preferredArch, &cdhashes, &cdhashesCount);
        if(collectResult != 0) {
                free(cdhashes);
                JBLogError("Failed to collect recursive trust cdhashes for %s", machoPath);
                return collectResult;
        }

        int result = 0;
	if (cdhashes && cdhashesCount > 0) {
		result = jb_trustcache_add_cdhashes(cdhashes, cdhashesCount);
		free(cdhashes);
	}
	return result;
}

int roothide_trust_executable_recurse(audit_token_t *callerToken, const char *executablePath, const char *processWorkingDir, xpc_object_t preferredArchsArray)
{
	if (!roothide_privileged_action_allowed(callerToken, "trust executable")) return -1;
	if (!roothide_path_argument_valid(executablePath, true, false) ||
	    !roothide_path_argument_valid(processWorkingDir, false, true)) return -1;
	return trust_macho_recurse(executablePath, NULL, executablePath, processWorkingDir, preferredArchsArray);
}

static int roothide_trust_library_recurse(audit_token_t *callerToken, const char *libraryPath, const char *callerLibraryPath, const char *currentWorkingDir)
{
	if (!roothide_privileged_action_allowed(callerToken, "trust library")) return -1;
	if (!roothide_path_argument_valid(libraryPath, true, false) ||
	    !roothide_path_argument_valid(callerLibraryPath, false, true) ||
	    !roothide_path_argument_valid(currentWorkingDir, false, true)) return -1;
	pid_t callerPid = audit_token_to_pid(*callerToken);
	const char *callerExecutablePath = proc_get_path(callerPid, NULL);
	if (!callerExecutablePath || callerExecutablePath[0] != '/') {
		JBLogError("trust library: unable to bind executable path for pid=%d", callerPid);
		return -1;
	}
	// When trusting a library that's dlopened at runtime, we need to pass the caller path
	// This is to support dlopen("@executable_path/whatever", RTLD_NOW) and stuff like that
	// (Yes that is a thing >.<)
	// Also we need to pass the path of the image that called dlopen due to @loader_path, sigh...
	return trust_macho_recurse(libraryPath, callerLibraryPath, callerExecutablePath, currentWorkingDir, NULL);
}

static int roothide_jailbroken_check(audit_token_t *callerToken, bool* jailbroken)
{
	*jailbroken = true;
	return 0;
}

static int roothide_reserved_2(audit_token_t *callerToken, bool *value)
{
	(void)callerToken;

	*value = false;
	return 0;
}

static int roothide_blacklist_check(audit_token_t *callerToken, const char* checktype, xpc_object_t checkvalue, bool* blacklisted)
{
    if (!blacklisted) {
        JBLogError("Missing blacklisted output argument");
        return -1;
    }

    *blacklisted = false;

    if (!checktype) {
        JBLogError("Missing blacklist checktype");
        return -1;
    }

	if(strcmp(checktype, "pid")==0) {

        pid_t pid = 0;
        if (checkvalue) {
            pid = (pid_t)xpc_uint64_get_value(checkvalue);
        } else if (callerToken) {
            pid = audit_token_to_pid(*callerToken);
        }

		if(pid > 1) {
			*blacklisted = isBlacklistedPid(pid);
			return 0;
		}
	} else if(strcmp(checktype, "path")==0) {
		const char* path = checkvalue ? xpc_string_get_string_ptr(checkvalue) : NULL;
		if(path) {
			*blacklisted = isBlacklistedPath(path);
			return 0;
		}
	} else if(strcmp(checktype, "bundle")==0) {
		const char* bundle = checkvalue ? xpc_string_get_string_ptr(checkvalue) : NULL;
		if(bundle) {
			*blacklisted = isBlacklistedApp(bundle);
			return 0;
		}
	} else {
		JBLogError("Invalid checktype: %s", checktype);
		return -1;
	}
	JBLogError("Failed to check blacklist for %s : %s", checktype, checkvalue ? xpc_type_get_name(xpc_get_type(checkvalue)) : "(null)");
	return -1;
}
static int roothide_jailbreakd_lookup(audit_token_t *callerToken, xpc_object_t *portOut)
{
    if(!portOut || !roothide_privileged_action_allowed(callerToken, "jailbreakd lookup")) return -1;
    *portOut = NULL;
    mach_port_t port = jailbreakdClientPort();
    if(!MACH_PORT_VALID(port)) {
        JBLogError("Invalid jailbreakd client port: %x", port);
        return -1;
    }
    *portOut = xpc_mach_send_create(port);
    return 0;
}
static int roothide_jailbreakd_checkin(audit_token_t *callerToken, const char *checkinToken, xpc_object_t *portOut)
{
    if(!callerToken || !checkinToken || !portOut) {
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.reject reason=missing_argument");
        return -1;
    }
    *portOut = NULL;

    pid_t pid = audit_token_to_pid(*callerToken);
    uid_t uid = audit_token_to_euid(*callerToken);
    bool blacklisted = isBlacklistedToken(callerToken);
    roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                            "jailbreakd.checkin.handler.begin pid=%d uid=%u blacklisted=%d",
                            pid, (unsigned)uid, blacklisted);
    if(uid != 0 || pid <= 1 || blacklisted) {
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.reject reason=identity pid=%d uid=%u blacklisted=%d",
                                pid, (unsigned)uid, blacklisted);
        return -1;
    }

    const char *processPath = proc_get_path(pid, NULL);
    const char *expectedPath = JBROOT_PATH("/basebin/jailbreakd");
    char normalizedProcessPath[PATH_MAX] = {0};
    char normalizedExpectedPath[PATH_MAX] = {0};
    bool processPathResolved = processPath && realpath(processPath, normalizedProcessPath) != NULL;
    bool expectedPathResolved = expectedPath && realpath(expectedPath, normalizedExpectedPath) != NULL;
    roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                            "jailbreakd.checkin.handler.path pid=%d process_resolved=%d expected_resolved=%d process=%s expected=%s",
                            pid, processPathResolved, expectedPathResolved,
                            processPathResolved ? normalizedProcessPath : (processPath ? processPath : "<unknown>"),
                            expectedPathResolved ? normalizedExpectedPath : (expectedPath ? expectedPath : "<unknown>"));
    if(!processPathResolved || !expectedPathResolved ||
       strcmp(normalizedProcessPath, normalizedExpectedPath) != 0) {
        JBLogError("jailbreakd checkin: denying caller pid=%d path=%s normalized=%s expected=%s normalizedExpected=%s",
                   pid,
                   processPath ? processPath : "<unknown>",
                   processPathResolved ? normalizedProcessPath : "<unresolved>",
                   expectedPath ? expectedPath : "<unknown>",
                   expectedPathResolved ? normalizedExpectedPath : "<unresolved>");
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.reject reason=path pid=%d",
                                pid);
        return -1;
    }

    jailbreakd_checkin_ticket_t ticket = {0};
    if (jailbreakdServerPortCheckinBegin(pid, checkinToken, &ticket) != 0) {
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.reject reason=candidate_identity pid=%d", pid);
        return -1;
    }
    mach_port_t port = ticket.port;
    roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                            "jailbreakd.checkin.handler.server_port pid=%d port=%x generation=%llu valid=%d",
                            pid, port, (unsigned long long)ticket.generation, MACH_PORT_VALID(port));
    if(!MACH_PORT_VALID(port)) {
        JBLogError("Invalid jailbreakd server port: %x", port);
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.reject reason=server_port");
        jailbreakdServerPortCheckinFailed(&ticket);
        return -1;
    }

    *portOut = xpc_mach_recv_create(port);
    roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                            "jailbreakd.checkin.handler.reply mach_recv=%d",
                            *portOut != NULL);
    if (!*portOut) {
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.reject reason=mach_recv_create");
        jailbreakdServerPortCheckinFailed(&ticket);
        return -1;
    }

    /* Readiness is committed only after the daemon attaches its receive source
     * and returns through the explicit ready acknowledgement action. */
    roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                            "jailbreakd.checkin.handler.prepared pid=%d generation=%llu",
                            pid, (unsigned long long)ticket.generation);
    return 0;
}

static int roothide_jailbreakd_ready(audit_token_t *callerToken, const char *checkinToken, bool ready)
{
    if (!callerToken || !checkinToken) return -1;
    pid_t pid = audit_token_to_pid(*callerToken);
    uid_t uid = audit_token_to_euid(*callerToken);
    if (uid != 0 || pid <= 1 || isBlacklistedToken(callerToken)) return -1;

    const char *processPath = proc_get_path(pid, NULL);
    const char *expectedPath = JBROOT_PATH("/basebin/jailbreakd");
    char normalizedProcessPath[PATH_MAX] = {0};
    char normalizedExpectedPath[PATH_MAX] = {0};
    if (!processPath || !expectedPath ||
        !realpath(processPath, normalizedProcessPath) ||
        !realpath(expectedPath, normalizedExpectedPath) ||
        strcmp(normalizedProcessPath, normalizedExpectedPath) != 0) {
        JBLogError("jailbreakd ready: denying caller pid=%d process=%s expected=%s",
                   pid, processPath ? processPath : "<unknown>",
                   expectedPath ? expectedPath : "<unknown>");
        return -1;
    }

    jailbreakd_checkin_ticket_t ticket = {0};
    if (!ready) {
        if (jailbreakdServerPortCheckinAbort(pid, checkinToken, &ticket) != 0) return -1;
        jailbreakdServerPortCheckinFailed(&ticket);
        roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                                "jailbreakd.checkin.handler.aborted pid=%d generation=%llu",
                                pid, (unsigned long long)ticket.generation);
        return 0;
    }
    if (jailbreakdServerPortCheckinReady(pid, checkinToken, &ticket) != 0) return -1;
    if (jailbreakdServerPortCheckinComplete(&ticket) != 0) {
        jailbreakdServerPortCheckinFailed(&ticket);
        return -1;
    }
    setJailbreakdProcess(pid);
    roothide_stage_file_log(ROOTHIDE_JAILBREAKD_STAGE_LOG_PATH,
                            "jailbreakd.ready.handler.ready=1 pid=%d generation=%llu",
                            pid, (unsigned long long)ticket.generation);
    return 0;
}

static int roothide_dyld_patch_enabled(audit_token_t *callerToken, bool* enabled)
{
	*enabled = jbinfo(dyld_patch_enabled);
	return 0;
}

static int roothide_set_dyld_patch(audit_token_t *callerToken, bool enabled)
{
	pid_t pid = audit_token_to_pid(*callerToken);
	uid_t uid = audit_token_to_euid(*callerToken);

    uint32_t csFlags = 0;
    csops(pid, CS_OPS_STATUS, &csFlags, sizeof(csFlags));

	if(uid != 0 && (csFlags & CS_PLATFORM_BINARY)==0) {
		JBLogError("roothide_set_dyld_patch: denying request from %d,%d", pid, uid);
		return -1;
	}
	
#ifdef __arm64e__
	if (!__builtin_available(iOS 16.0, *))
	{
		if(roothide_config_set_spinlock_fix(enabled) != 0) {
			JBLogError("roothide_config_set_spinlock_fix failed");
			return -1;
		}
	}
#endif

	jbinfo(dyld_patch_enabled) = enabled;
	
	return 0;
}

struct jbserver_domain gRootHideDomain = {
	.permissionHandler = roothide_domain_allowed,
	.actions = {
		//JBS_ROOTHIDE_JAILBROKEN_CHECK
        {
            .handler = roothide_jailbroken_check,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "jailbroken", .type = JBS_TYPE_BOOL, .out = true },
                    { 0 },
            },
        },
		// Legacy action #2 ABI slot
        {
            .handler = roothide_reserved_2,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "palehide", .type = JBS_TYPE_BOOL, .out = true },
                    { 0 },
            },
        },
		//JBS_ROOTHIDE_BLACKLIST_CHECK
        {
            .handler = roothide_blacklist_check,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
					{ .name = "checktype", .type = JBS_TYPE_STRING, .out = false },
					{ .name = "checkvalue", .type = JBS_TYPE_XPC_GENERIC, .out = false },
                    { .name = "blacklisted", .type = JBS_TYPE_BOOL, .out = true },
                    { 0 },
            },
        },
		//JBS_ROOTHIDE_JAILBREAKD_LOOKUP
        {
            .handler = roothide_jailbreakd_lookup,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "port", .type = JBS_TYPE_XPC_GENERIC, .out = true },
                    { 0 },
            },
        },
		//JBS_ROOTHIDE_JAILBREAKD_CHECKIN
        {
            .handler = roothide_jailbreakd_checkin,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "checkin-token", .type = JBS_TYPE_STRING, .out = false },
                    { .name = "port", .type = JBS_TYPE_XPC_GENERIC, .out = true },
                    { 0 },
            },
        },
		// JBS_ROOTHIDE_TRUST_LIBRARY_RECURSE
		{
			.handler = roothide_trust_library_recurse,
			.args = (jbserver_arg[]){
				{ .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
				{ .name = "library-path", .type = JBS_TYPE_STRING, .out = false },
				{ .name = "caller-library-path", .type = JBS_TYPE_STRING, .out = false },
				{ .name = "current-working-dir", .type = JBS_TYPE_STRING, .out = false },
				{ 0 },
			},
		},
		// JBS_ROOTHIDE_TRUST_EXECUTABLE_RECURSE
		{
			.handler = roothide_trust_executable_recurse,
			.args = (jbserver_arg[]){
				{ .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
				{ .name = "executable-path", .type = JBS_TYPE_STRING, .out = false },
				{ .name = "process-working-dir", .type = JBS_TYPE_STRING, .out = false },
				{ .name = "preferred-archs", .type = JBS_TYPE_ARRAY, .out = false },
				{ 0 },
			},
		},
		//JBS_ROOTHIDE_DYLD_PATCH_ENABLED_GET
        {
            .handler = roothide_dyld_patch_enabled,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "enabled", .type = JBS_TYPE_BOOL, .out = true },
                    { 0 },
            },
        },
		//JBS_ROOTHIDE_DYLD_PATCH_ENABLED_SET
        {
            .handler = roothide_set_dyld_patch,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "enabled", .type = JBS_TYPE_BOOL, .out = false },
                    { 0 },
            },
        },
        {
            .handler = roothide_jailbreakd_ready,
            .args = (jbserver_arg[]) {
                    { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
                    { .name = "checkin-token", .type = JBS_TYPE_STRING, .out = false },
                    { .name = "ready", .type = JBS_TYPE_BOOL, .out = false },
                    { 0 },
            },
        },
		{ 0 },
	},
};
