#include "common.h"
#include "rc9_jetsam_limit.h"
#include "../roothider.h"
#include <xpc/xpc.h>
#include <xpc_private.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sandbox.h>
#include <paths.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include "envbuf.h"
#include <errno.h>
#include <stdint.h>
#include "private.h"
#include <libjailbreak/jbclient_xpc.h>
#include <libjailbreak/jbserver_domains.h>
#include <libjailbreak/util.h>
#include <libjailbreak/jbroot.h>
#include <os/log.h>
#include <os/lock.h>
#include "../_zqbb.h"
#include "RCInjectPolicyCache.h"

#ifndef RC9_LAUNCHD
// Only systemhook queries the server. launchd applies isBlacklistedPath in
// its prehook before entering this shared policy; never send IPC to itself.
extern bool jbclient_blacklist_check_path(const char *path);
#endif

bool string_has_prefix(const char *str, const char* prefix)
{
	if (!str || !prefix) {
		return false;
	}

	size_t str_len = strlen(str);
	size_t prefix_len = strlen(prefix);

	if (str_len < prefix_len) {
		return false;
	}

	return !strncmp(str, prefix, prefix_len);
}

bool string_has_suffix(const char* str, const char* suffix)
{
	if (!str || !suffix) {
		return false;
	}

	size_t str_len = strlen(str);
	size_t suffix_len = strlen(suffix);

	if (str_len < suffix_len) {
		return false;
	}

	return !strcmp(str + str_len - suffix_len, suffix);
}

bool string_enumerate_components(const char *string, const char *separator, void (^enumBlock)(const char *pathString, bool *stop))
{
	if (!string || !separator || !enumBlock) return false;
	char *stringCopy = strdup(string);
	if (!stringCopy) return false;
	char *savePtr = NULL;
	char *curString = strtok_r(stringCopy, separator, &savePtr);
	while (curString != NULL) {
		bool stop = false;
		enumBlock(curString, &stop);
		if (stop) break;
		curString = strtok_r(NULL, separator, &savePtr);
	}
	free(stringCopy);
	return true;
}

xpc_object_t jbuserconfig_get_value(const char *key)
{
        static RCInjectPolicyCache configCache = RC_INJECT_POLICY_CACHE_INIT;

        if (!key) {
                return NULL;
        }

        const char *configPath = JBROOT_PATH("/basebin/config.plist");

        xpc_object_t configDict =
                rc_inject_policy_cache_copy_dictionary(&configCache, configPath);
        if (!configDict) {
                return NULL;
        }

        xpc_object_t value = xpc_dictionary_get_value(configDict, key);
        if (value) {
                xpc_retain(value);
        }

        xpc_release(configDict);
        return value;
}

bool is_apt_transport_path(const char *path)
{
	// Keep systemhook in apt-get so it can trust transports spawned later.
	// Only the short-lived transport itself must be injection-free.
	return path && strstr(path, "/apt/methods/") != NULL;
}

kSpawnConfig spawn_config_for_executable(const char* path, char *const argv[restrict])
{
	if (!path) return 0;

#ifndef RC9_LAUNCHD
	// RootHide dynamic blacklist is stronger than the normal Dopamine policy:
	// no trust, no systemhook injection, and no tweak propagation. Returning 0
	// also makes spawn_exec_hook_common strip any inherited jailbreak env.
	// RootHide app blacklist can only match executables inside a normal
	// removable app container. Resolve the path once so both the local bundle
	// check and the authoritative server-side blacklist check see the same path.
	char resolvedPolicyPath[PATH_MAX];
	const char *policyPath = path;
	if (path && realpath(path, resolvedPolicyPath)) {
		policyPath = resolvedPolicyPath;
	}
	if (policyPath && isRemovableBundlePath(policyPath) && jbclient_blacklist_check_path(policyPath)) {
		return 0;
	}

#endif

	if (is_apt_transport_path(path)) {
		return kSpawnConfigTrust;
	}

	// Blacklist to ensure general system stability
	// I don't like this but for some processes it seems neccessary
	const char *processBlacklist[] = {
		"/System/Library/Frameworks/GSS.framework/Helpers/GSSCred",
		"/System/Library/PrivateFrameworks/DataAccess.framework/Support/dataaccessd",
		"/System/Library/PrivateFrameworks/IDSBlastDoorSupport.framework/XPCServices/IDSBlastDoorService.xpc/IDSBlastDoorService",
		"/System/Library/PrivateFrameworks/MessagesBlastDoorSupport.framework/XPCServices/MessagesBlastDoorService.xpc/MessagesBlastDoorService",
	};
	size_t blacklistCount = sizeof(processBlacklist) / sizeof(processBlacklist[0]);
	for (size_t i = 0; i < blacklistCount; i++)
	{
		if (!strcmp(processBlacklist[i], path)) return 0;
	}

	xpc_object_t userBlacklist = jbuserconfig_get_value("ProcessBlacklist");
	if (userBlacklist) {
		bool userBlacklisted = false;

		if (xpc_get_type(userBlacklist) == XPC_TYPE_ARRAY) {
			size_t userBlacklistCount = xpc_array_get_count(userBlacklist);
			for (size_t i = 0; i < userBlacklistCount; i++) {
				const char *blacklistedPath = xpc_array_get_string(userBlacklist, i);
				if (blacklistedPath && !strcmp(blacklistedPath, path)) {
					userBlacklisted = true;
					break;
				}
			}
		}

		xpc_release(userBlacklist);

		if (userBlacklisted) {
			return kSpawnConfigTrust;
		}
	}

	// Apply the RootHide whitelist only after the blacklist decisions above.
	const char *injectPath = JBROOT_PATH("/var/mobile/Library/RootHide/cn.zqbb.inject.plist");
	if (access(injectPath, F_OK) == 0) {
		const char *exec = strrchr(path, '/');
		if (exec && zqbb_wantInject(exec + 1, injectPath)) {
			return (kSpawnConfigInject | kSpawnConfigTrust);
		}
		if (zqbb_isWhiteList(path)) {
			return (kSpawnConfigInject | kSpawnConfigTrust);
		}
		return 0;
	}

	return (kSpawnConfigInject | kSpawnConfigTrust);
}

int __posix_spawn_orig(pid_t *restrict pid, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict])
{
	return syscall(SYS_posix_spawn, pid, path, desc, argv, envp);
}

int __execve_orig(const char *path, char *const argv[], char *const envp[])
{
	return syscall(SYS_execve, path, argv, envp);
}

// 1. Ensure the binary about to be spawned and all of it's dependencies are trust cached
// 2. Insert "DYLD_INSERT_LIBRARIES=/usr/lib/systemhook.dylib" into all binaries spawned
// 3. Increase Jetsam limit to more sane value (Multipler defined as JETSAM_MULTIPLIER)

static int spawn_exec_hook_common(const char *path,
						   char *const argv[restrict],
						   char *const envp[restrict],
		struct _posix_spawn_args_desc *desc,
								 int (*trust_binary)(const char *path),
								double jetsamMultiplier,
								 int (^orig)(char *const envp[restrict]))
{
	if (!path) {
		return orig(envp);
	}

	posix_spawnattr_t attr = NULL;
	if (desc) attr = desc->attrp;

	kSpawnConfig spawnConfig = spawn_config_for_executable(path, argv);

	if (spawnConfig & kSpawnConfigTrust) {
		// Upload binary to trustcache if needed
		trust_binary(path);
	}

	const char *existingLibraryInserts = envbuf_getenv((const char **)envp, "DYLD_INSERT_LIBRARIES");
	__block bool systemHookAlreadyInserted = false;
	if (existingLibraryInserts) {
		if (!string_enumerate_components(existingLibraryInserts, ":", ^(const char *existingLibraryInsert, bool *stop) {
			if (!strcmp(existingLibraryInsert, HOOK_DYLIB_PATH)) {
				systemHookAlreadyInserted = true;
			}
		})) return ENOMEM;
	}

	int JBEnvAlreadyInsertedCount = (int)systemHookAlreadyInserted;

	// Check if we can find at least one reason to not insert jailbreak related environment variables
	// In this case we also need to remove pre existing environment variables if they are already set
	bool shouldInsertJBEnv = true;
	bool hasSafeModeVariable = false;
	do {
		if (!(spawnConfig & kSpawnConfigInject)) {
			shouldInsertJBEnv = false;
			break;
		}

		// Check if we can find a _SafeMode or _MSSafeMode variable
		// RootHide may still need its base hook; main.c separately blocks tweaks.
		const char *safeModeValue = envbuf_getenv((const char **)envp, "_SafeMode");
		const char *msSafeModeValue = envbuf_getenv((const char **)envp, "_MSSafeMode");
		if (safeModeValue) {
			if (!strcmp(safeModeValue, "1")) {
				if (!allowInjectWithSafeMode(path)) shouldInsertJBEnv = false;
				hasSafeModeVariable = true;
			}
		}
		if (msSafeModeValue) {
			if (!strcmp(msSafeModeValue, "1")) {
				if (!allowInjectWithSafeMode(path)) shouldInsertJBEnv = false;
				hasSafeModeVariable = true;
			}
		}
		if (!shouldInsertJBEnv) break;
		// Allowing RootHide in SafeMode must not bypass DriverKit or dylib existence checks.

		int proctype = 0;
		if (attr && posix_spawnattr_getprocesstype_np(&attr, &proctype) == 0) {
			if (proctype == POSIX_SPAWN_PROC_TYPE_DRIVER) {
				// Do not inject hook into DriverKit drivers
				shouldInsertJBEnv = false;
				break;
			}
		}

		if (access(HOOK_DYLIB_PATH, F_OK) != 0) {
			// If the hook dylib doesn't exist, don't try to inject it (would crash the process)
			shouldInsertJBEnv = false;
			break;
		}
	} while (0);


	uint8_t *attrStruct = (uint8_t *)attr;
	if (attrStruct) {
		// If systemhook is being injected and jetsam limits are set, increase them with the ZQBB per-process addend
		if (shouldInsertJBEnv) {
			if (jetsamMultiplier == 0 || !isfinite(jetsamMultiplier)) jetsamMultiplier = 3; // default value (3x)
			if (jetsamMultiplier > 1) {
				int jetsamAddend = rc9_zqbb_jetsam_addend(zqbb_getJetsamAddend(path), jetsamMultiplier);
				int memlimit_active = *(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_ACTIVE);
				if (memlimit_active != -1) {
					*(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_ACTIVE) = rc9_zqbb_jetsam_limit(memlimit_active, jetsamAddend);
				}
				int memlimit_inactive = *(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_INACTIVE);
				if (memlimit_inactive != -1) {
					*(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_INACTIVE) = rc9_zqbb_jetsam_limit(memlimit_inactive, jetsamAddend);
				}
			}
		}

	}

	int r = -1;
	char **envc = NULL;
	char *const *spawnEnvp = envp;

	if (!((shouldInsertJBEnv && JBEnvAlreadyInsertedCount == 1) || (!shouldInsertJBEnv && JBEnvAlreadyInsertedCount == 0 && !hasSafeModeVariable))) {
		// the state we want to be in is not the state we are in right now

		envc = envbuf_mutcopy((const char **)envp);
		if (envp && !envc) return ENOMEM;

		if (shouldInsertJBEnv) {
			if (!systemHookAlreadyInserted) {
				size_t hookLen = strlen(HOOK_DYLIB_PATH);
				size_t existingLen = existingLibraryInserts ? strlen(existingLibraryInserts) : 0;
				if (hookLen > SIZE_MAX - 2 || existingLen > SIZE_MAX - hookLen - 2) {
					envbuf_free(envc);
					return ENOMEM;
				}
				char *newLibraryInsert = malloc(hookLen + existingLen + 2);
				if (!newLibraryInsert) {
					envbuf_free(envc);
					return ENOMEM;
				}
				strcpy(newLibraryInsert, HOOK_DYLIB_PATH);
				if (existingLibraryInserts) {
					strcat(newLibraryInsert, ":");
					strcat(newLibraryInsert, existingLibraryInserts);
				}
				bool updated = envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", newLibraryInsert);
				free(newLibraryInsert);
				if (!updated) {
						envbuf_free(envc);
						return ENOMEM;
				}
			}
		}
		else {
			if (systemHookAlreadyInserted && existingLibraryInserts) {
				if (!strcmp(existingLibraryInserts, HOOK_DYLIB_PATH)) {
					envbuf_unsetenv(&envc, "DYLD_INSERT_LIBRARIES");
				}
				else {
					char *newLibraryInsert = malloc(strlen(existingLibraryInserts)+1);
					if (!newLibraryInsert) {
						envbuf_free(envc);
						return ENOMEM;
					}
					newLibraryInsert[0] = '\0';

					__block bool first = true;
					bool parsed = string_enumerate_components(existingLibraryInserts, ":", ^(const char *existingLibraryInsert, bool *stop) {
						if (strcmp(existingLibraryInsert, HOOK_DYLIB_PATH) != 0) {
							if (first) {
								strcpy(newLibraryInsert, existingLibraryInsert);
								first = false;
							}
							else {
								strcat(newLibraryInsert, ":");
								strcat(newLibraryInsert, existingLibraryInsert);
							}
						}
					});
					bool updated = parsed;
					if (updated && first) {
						envbuf_unsetenv(&envc, "DYLD_INSERT_LIBRARIES");
					}
					else if (updated) {
						updated = envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", newLibraryInsert);
					}
					free(newLibraryInsert);
					if (!updated) {
						envbuf_free(envc);
						return ENOMEM;
					}
				}
			}
			envbuf_unsetenv(&envc, "_SafeMode");
			envbuf_unsetenv(&envc, "_MSSafeMode");
		}

		spawnEnvp = envc;
	}

	r = orig(spawnEnvp);

	if (envc) envbuf_free(envc);

	return r;
}

int posix_spawn_hook_shared(pid_t *restrict pid, 
					   const char *restrict path,
			 struct _posix_spawn_args_desc *desc,
						  	    char *const argv[restrict],
					   			char *const envp[restrict],
					   				  void *orig,
					   				  int (*trust_binary)(const char *path),
					   				  int (*set_process_debugged)(uint64_t pid, bool fullyDebugged),
					   				 double jetsamMultiplier)
{
	int (*posix_spawn_orig)(pid_t *restrict, const char *restrict, struct _posix_spawn_args_desc *, char *const[restrict], char *const[restrict]) = orig;

	int r = spawn_exec_hook_common(path, argv, envp, desc, trust_binary, jetsamMultiplier, ^int(char *const envp_patched[restrict]) {
		return posix_spawn_orig(pid, path, desc, argv, envp_patched);
	});

	if (r == 0 && pid && desc) {
		posix_spawnattr_t attr = desc->attrp;
		short flags = 0;
		if (attr && posix_spawnattr_getflags(&attr, &flags) == 0) {
			if (flags & POSIX_SPAWN_START_SUSPENDED) {
				// If something spawns a process as suspended, ensure mapping invalid pages in it is possible
				// Normally it would only be possible after systemhook.dylib enables it
				// Fixes Frida issues
				set_process_debugged(*pid, false);
			}
		}
	}

	return r;
}

int execve_hook_shared(const char *path,
					   char *const argv[],
					   char *const envp[],
			 				 void *orig,
			 				 int (*trust_binary)(const char *path))
{
	int (*execve_orig)(const char *, char *const[], char *const[]) = orig;

	int r = spawn_exec_hook_common(path, argv, envp, NULL, trust_binary, 0, ^int(char *const envp_patched[restrict]){
		return execve_orig(path, argv, envp_patched);
	});

	if (r == ENOMEM) { errno = ENOMEM; return -1; }
	return r;
}
