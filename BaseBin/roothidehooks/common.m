#import <Foundation/Foundation.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <roothide.h>
#include <sys/mount.h>
#include <dlfcn.h>
#include "common.h"

static NSString* rcConvertRootHidePath(NSString* path, bool toJailbreakCoordinates)
{
	if (!path || !get_jbroot()) return nil;
	// The local roothide.h compatibility macros only prepend JBROOT_PATH.
	// Use the actual RootHide API for reverse conversion as upstream does.
	static const char* (*rootfsAlloc)(const char*);
	static const char* (*jbrootAlloc)(const char*);
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void* library = dlopen(JBROOT_PATH("/usr/lib/libroothide.dylib"), RTLD_LAZY | RTLD_LOCAL);
		if (library) {
			rootfsAlloc = dlsym(library, "rootfs_alloc");
			jbrootAlloc = dlsym(library, "jbroot_alloc");
			// Keep the handle alive while the cached functions are in use.
		}
	});
	if (!rootfsAlloc || !jbrootAlloc) return nil;
	const char* input = path.fileSystemRepresentation;
	if (!input) return nil;
	const char* converted = toJailbreakCoordinates ? rootfsAlloc(input) : jbrootAlloc(input);
	if (!converted) return nil;
	NSString* result = [NSString stringWithUTF8String:converted];
	free((void*)converted);
	return result;
}

NSString* rcRootfsPath(NSString* path) { return rcConvertRootHidePath(path, true); }
NSString* rcJbrootPath(NSString* path) { return rcConvertRootHidePath(path, false); }

bool isJailbreakBundlePath(const char* path)
{
	//no path? may be a system bundle
	if(!path) return false;

	struct statfs fs;
	if(statfs(path, &fs) != 0)
	{
		//path not exists, may be a jailbreak bundle
		return true;
	}

	if(strcmp(fs.f_mntonname, "/") == 0) {
		// anything on rootfs is not jailbreak stuffs
		return false;
	}

	if(strcmp(fs.f_mntonname, "/private/preboot") == 0) {
		// Match ZQBB: RootHide apps do not live on the preboot volume.
		return false;
	}

	if(isRemovableBundlePath(path))
	{
		if(!hasTrollstoreMarker(path)) {
			// normal app bundle
			return false;
		}
	}

	return true;
}
