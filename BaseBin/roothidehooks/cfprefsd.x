#import <Foundation/Foundation.h>
#import <substrate.h>
#include <dlfcn.h>
#include <roothide.h>
#include "common.h"

#define PROC_PIDPATHINFO_MAXSIZE        (4*MAXPATHLEN)
#define CFPREFS_PATH_BUFFER_SIZE        1024

pid_t __thread gCurrentClientPid = 0;

BOOL preferencePlistNeedsRedirection(NSString *plistPath)
{
    NSString *pattern = @"^(/private)?/var/(\\w+)/Library/Preferences/";
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult* match = [regex firstMatchInString:plistPath options:0 range:NSMakeRange(0, plistPath.length)];
	if(!match) return NO;

	NSString *plistName = plistPath.lastPathComponent;

	NSString* identifier = [plistName hasSuffix:@".plist"] ? plistName.stringByDeletingPathExtension : plistName;
	if(is_apple_internal_identifier(identifier.UTF8String))
		return YES;

	if ([plistName hasPrefix:@"com.apple."]
	  || [plistName hasPrefix:@"group.com.apple."]
	 || [plistName hasPrefix:@"systemgroup.com.apple."])
	  return NO;

	NSArray *additionalSystemPlistNames = @[
		@".GlobalPreferences.plist",
		@".GlobalPreferences_m.plist",
		@"bluetoothaudiod.plist",
		@"NetworkInterfaces.plist",
		@"OSThermalStatus.plist",
		@"preferences.plist",
		@"osanalyticshelper.plist",
		@"UserEventAgent.plist",
		@"wifid.plist",
		@"dprivacyd.plist",
		@"silhouette.plist",
		@"nfcd.plist",
		@"kNPProgressTrackerDomain.plist",
		@"siriknowledged.plist",
		@"UITextInputContextIdentifiers.plist",
		@"mobile_storage_proxy.plist",
		@"splashboardd.plist",
		@"mobile_installation_proxy.plist",
		@"languageassetd.plist",
		@"ptpcamerad.plist",
		@"com.google.gmp.measurement.monitor.plist",
		@"com.google.gmp.measurement.plist",
	];

	return ![additionalSystemPlistNames containsObject:plistName];
}

BOOL (*orig_CFPrefsGetPathForTriplet)(CFStringRef, CFStringRef, BOOL, CFStringRef, UInt8*);
BOOL new_CFPrefsGetPathForTriplet(CFStringRef identifier, CFStringRef user, BOOL byHost, CFStringRef container, UInt8 *buffer)
{
	BOOL orig = orig_CFPrefsGetPathForTriplet(identifier, user, byHost, container, buffer);

	/* byHost = (host==kCFPreferencesCurrentHost) ? 1 : 0 */
	NSLog(@"CFPrefsGetPathForTriplet identifier=%@ user=%@ byHost=%d container=%@ ret=%d : %s", identifier, user, byHost, container, orig, orig?(char*)buffer:"");
	// NSLog(@"callstack=%@", [NSThread callStackSymbols]);

	if(orig && buffer)
	{
		size_t originalPathLength = strnlen((char *)buffer, CFPREFS_PATH_BUFFER_SIZE);
		if (originalPathLength == CFPREFS_PATH_BUFFER_SIZE) {
			NSLog(@"CFPrefsGetPathForTriplet rejected unterminated path buffer");
			return orig;
		}

		NSString* origPath = [NSString stringWithUTF8String:(char*)buffer];
		if (!origPath) return orig;
		BOOL needsRedirection = preferencePlistNeedsRedirection(origPath);

		if (needsRedirection) {
			if(gCurrentClientPid>0 && jbclient_blacklist_check_pid(gCurrentClientPid)==true) {
				NSLog(@"CFPrefsGetPathForTriplet deny redirection for process (%d) %s", gCurrentClientPid, proc_get_path(gCurrentClientPid,NULL));
				needsRedirection = NO;
			}
		}
		
		if (needsRedirection) {
			NSLog(@"Plist redirected to jbroot:%@", origPath);
			const char* newpath = jbroot(origPath.UTF8String);
			// This private CoreFoundation call site currently supplies a 1024-byte buffer.
			// Keep the capacity explicit and reject malformed or oversized paths before writing.
			if(newpath && strnlen(newpath, CFPREFS_PATH_BUFFER_SIZE) < CFPREFS_PATH_BUFFER_SIZE) {
				strlcpy((char*)buffer, newpath, CFPREFS_PATH_BUFFER_SIZE);
				NSLog(@"CFPrefsGetPathForTriplet redirect to %s", buffer);
			}
			else {
				return NO;
			}
		}
	}

	return orig;
}

void* (*orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__)(id self, xpc_object_t message, xpc_connection_t connection, void* replyHandler);
void* (*LEGACY_orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__)(id self, SEL selector, xpc_object_t message, xpc_connection_t connection, void* replyHandler);
void* DISPATCH_orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(id self, xpc_object_t message, xpc_connection_t connection, void* replyHandler)
{
	if(@available(iOS 17.0, *)) {
		return orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(self, message, connection, replyHandler);
	} else {
		return LEGACY_orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(self, nil, message, connection, replyHandler);
	}
}
void* new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(id self, xpc_object_t message, xpc_connection_t connection, void* replyHandler)
{
    uid_t clientUid = xpc_connection_get_euid(connection);
    pid_t (*getConnectionPid)(xpc_connection_t) = (pid_t (*)(xpc_connection_t))dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
    pid_t clientPid = getConnectionPid ? getConnectionPid(connection) : -1;

	NSLog(@"CFPrefsDaemon: handleMessage %p/%d pid=%d uid=%d proc=%s", message, xpc_get_type(message)==XPC_TYPE_DICTIONARY, clientPid, clientUid, proc_get_path(clientPid,NULL));

	// char* desc = xpc_copy_description(message);
	// NSLog(@"CFPrefsDaemon: handleMessage Operation=%lld, msg=%s", xpc_dictionary_get_int64(message, "CFPreferencesOperation"), desc);
	// if(desc) free(desc);

	pid_t previousClientPid = gCurrentClientPid;
	gCurrentClientPid = clientPid;
	void *result = DISPATCH_orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(self, message, connection, replyHandler);
	gCurrentClientPid = previousClientPid;
	return result;
}
void* LEGACY_new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(id self, SEL selector, xpc_object_t message, xpc_connection_t connection, void* replyHandler)
{
	return new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__(self, message, connection, replyHandler);
}

void cfprefsdInit(void)
{
	NSLog(@"cfprefsdInit..");

	MSImageRef coreFoundationImage = MSGetImageByName("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");

	void* CFPrefsGetPathForTriplet_ptr = MSFindSymbol(coreFoundationImage, "__CFPrefsGetPathForTriplet");
	if(CFPrefsGetPathForTriplet_ptr)
	{
		MSHookFunction(CFPrefsGetPathForTriplet_ptr, (void *)&new_CFPrefsGetPathForTriplet, (void **)&orig_CFPrefsGetPathForTriplet);
		NSLog(@"hook __CFPrefsGetPathForTriplet %p => %p : %p", CFPrefsGetPathForTriplet_ptr, new_CFPrefsGetPathForTriplet, orig_CFPrefsGetPathForTriplet);
	}

	void* __CFPrefsDaemon_handleMessage_fromPeer_replyHandler__ = MSFindSymbol(coreFoundationImage, "-[CFPrefsDaemon handleMessage:fromPeer:replyHandler:]");
	if(__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__)
	{
		if(@available(iOS 17.0, *)) {
			MSHookFunction(__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, (void *)new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, (void **)&orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__);
			NSLog(@"hook __CFPrefsDaemon_handleMessage_fromPeer_replyHandler__ %p => %p : %p", __CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__);
		} else {
			MSHookFunction(__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, (void *)LEGACY_new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, (void **)&LEGACY_orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__);
			NSLog(@"hook __CFPrefsDaemon_handleMessage_fromPeer_replyHandler__ %p => %p : %p", __CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, LEGACY_new__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__, LEGACY_orig__CFPrefsDaemon_handleMessage_fromPeer_replyHandler__);
		}
	}

	%init();
}
