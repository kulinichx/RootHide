#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sandbox.h>
#include <libjailbreak/jbclient_mach.h>

#include "dyld.h"
#include "dyld_jbinfo.h"

__attribute__((section("__DATA,__jbinfo"))) static char jbinfoSection[0x4000];
#define jbInfo ((struct dyld_jbinfo *)&jbinfoSection[0])

bool gDyldhookInitDone = false;

static bool dyldhook_is_hex(char c)
{
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static bool dyldhook_is_systemhook_component(const char *component, size_t length)
{
	static const char basebinHook[] = "/basebin/systemhook.dylib";
	if (length == sizeof(basebinHook) - 1 && !strncmp(component, basebinHook, length)) return true;

	static const char prefix[] = "/usr/lib/systemhook-";
	static const char suffix[] = ".dylib";
	const size_t prefixLength = sizeof(prefix) - 1;
	const size_t suffixLength = sizeof(suffix) - 1;
	if (length != prefixLength + 16 + suffixLength) return false;
	if (strncmp(component, prefix, prefixLength) != 0) return false;
	for (size_t i = 0; i < 16; i++) {
		if (!dyldhook_is_hex(component[prefixLength + i])) return false;
	}
	return strncmp(component + prefixLength + 16, suffix, suffixLength) == 0;
}

static bool dyldhook_insert_libraries_contains_systemhook(const char *insertLibraries)
{
	if (!insertLibraries || !*insertLibraries) return false;
	const char *component = insertLibraries;
	for (const char *cursor = insertLibraries;; cursor++) {
		if (*cursor == ':' || *cursor == '\0') {
			if (dyldhook_is_systemhook_component(component, (size_t)(cursor - component))) return true;
			if (*cursor == '\0') break;
			component = cursor + 1;
		}
	}
	return false;
}

bool jbinfo_is_checked_in(void)
{
	return jbInfo->state == DYLD_STATE_CHECKED_IN;
}

char *jbinfo_get_jbroot(void)
{
	return jbInfo->jbRootPath;
}

bool jbinfo_should_force_cs_adhoc(void)
{
	return jbInfo->forceCSAdhoc;
}

void consume_tokenized_sandbox_extensions(char *sandboxExtensions)
{
	if (sandboxExtensions[0] == '\0') return;

	char *it = sandboxExtensions;
	char *last = sandboxExtensions;
	while (*(++it) != '\0') {
		if (*it == '|') {
			*it = '\0';
			sandbox_extension_consume(last);
			last = &it[1];
			*it = '|';
		}
	}
	sandbox_extension_consume(last);
}

void dyldhook_perform_checkin(void)
{
	struct jbserver_mach_msg_checkin_reply *replyPtr; // Only for sizeof macro

	char *jbRootPathPtr = &jbInfo->data[0];
	char *bootUUIDPtr = &jbInfo->data[sizeof(replyPtr->jbRootPath)];
	char *sandboxExtensionsPtr = &jbInfo->data[sizeof(replyPtr->jbRootPath)+sizeof(replyPtr->bootUUID)];

	// Tell jbserver (in launchd) that this process exists
	// This will, amongst other things, disable page validation, which allows instruction hooks to be applied later
	if (jbclient_mach_process_checkin(jbRootPathPtr, bootUUIDPtr, sandboxExtensionsPtr, &jbInfo->fullyDebugged, &jbInfo->forceCSAdhoc) == 0) {
		consume_tokenized_sandbox_extensions(sandboxExtensionsPtr);
		jbInfo->jbRootPath = jbRootPathPtr;
		jbInfo->bootUUID = bootUUIDPtr;
		jbInfo->sandboxExtensions = sandboxExtensionsPtr;
		jbInfo->state = DYLD_STATE_CHECKED_IN;
	}
}

mach_port_t mach_task_self_ = MACH_PORT_NULL;

void mach_init_4real(void)
{
	extern void mach_init(void);
	mach_init();

	mach_task_self_ = task_self_trap();
	mach_port_deallocate(mach_task_self_, mach_task_self_);
}

void dyldhook_init(uintptr_t kernelParams)
{
	mach_init_4real();

	extern void dyldhook_init_roothide(uintptr_t);
	dyldhook_init_roothide(kernelParams);


	// If we are in launchd, bail out
	if (getpid() == 1) {
		return;
	}

	// Walk kernelParams to get envp
	uintptr_t argc = *(uintptr_t *)(kernelParams + sizeof(void *));
	char **envp = (char **)(kernelParams + sizeof(void *) + sizeof(argc) + (sizeof(const char *) * argc) + sizeof(void *));

	// Only perform the early check-in for processes that are actually receiving
	// the jailbreak systemhook. RootHide randomizes the /usr/lib filename, so
	// match a complete DYLD_INSERT_LIBRARIES component rather than a substring.
	const char *insertLibrariesVar = _simple_getenv(envp, "DYLD_INSERT_LIBRARIES");
	if (!dyldhook_insert_libraries_contains_systemhook(insertLibrariesVar)) return;

	// If all is well, do check-in right here before dyld_start!
	dyldhook_perform_checkin();
}
