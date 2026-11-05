#import <Foundation/Foundation.h>
#include <roothide.h>
#include <libjailbreak/jbclient_xpc.h>
#import <fcntl.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <string.h>
#include "common.h"

static NSString *springboardJbrootPath(NSString *path)
{
	const char *rootPath = jbclient_get_jbroot();
	if (!rootPath || rootPath[0] != '/' || !path.fileSystemRepresentation) {
		return nil;
	}
	return [NSString stringWithFormat:@"%s%s", rootPath, path.fileSystemRepresentation];
}

%hookf(int, fcntl, int fildes, int cmd, ...) {
	if (cmd == F_SETPROTECTIONCLASS) {
		char filePath[PATH_MAX];
		if (fcntl(fildes, F_GETPATH, filePath) != -1) {
			// Skip setting protection class on jailbreak apps, this doesn't work and causes snapshots to not be saved correctly
			if (isSubPathOf(filePath, jbroot("/var/mobile/Library/SplashBoard/Snapshots/"))) {
				return 0;
			}
		}
	}

	// Preserve fcntl's ABI without walking beyond its single optional argument.
	// Passing a zero placeholder to no-argument commands is safe because the
	// original variadic wrapper and kernel ignore it for those commands.
	switch (cmd) {
		case F_GETOWN:
		case F_GETFD:
		case F_GETFL:
		case F_FULLFSYNC:
		case F_FREEZE_FS:
		case F_THAW_FS:
		case F_GETPROTECTIONCLASS:
		case F_GETNOSIGPIPE:
		case F_GETPROTECTIONLEVEL:
		case F_BARRIERFSYNC:
		case F_GETLEASE:
			return %orig(fildes, cmd, (uintptr_t)0);

		default: {
			va_list a;
			va_start(a, cmd);
			uintptr_t arg = va_arg(a, uintptr_t);
			va_end(a);
			return %orig(fildes, cmd, arg);
		}
	}
}

@interface XBSnapshotContainerIdentity : NSObject
@property NSString* bundleIdentifier;
@property (nonatomic, readonly, copy) NSString *snapshotContainerPath;
@end

@interface XBApplicationSnapshot : NSObject
- (XBSnapshotContainerIdentity *)containerIdentity;
- (NSString *)_configureDefaultPathWithinGroupForFormat:(long long)format;
@end

@interface XBApplicationSnapshotManifestImpl : NSObject
+ (long long)_outputFormatForSnapshot:(id)snapshot;
- (BOOL)_imageAccessQueue_saveData:(NSData *)data forSnapshot:(XBApplicationSnapshot *)snapshot;
@end

%hook XBSnapshotContainerIdentity

/*
-(id)_initWithBundleIdentifier:(id)arg1 bundlePath:(id)arg2 dataContainerPath:(id)arg3 bundleContainerPath:(id)arg4 
{
    NSLog(@"snapshot init, id=%@, bundlePath=%@, dataContainerPath=%@, bundleContainerPath=%@", arg1, arg2, arg3, arg4);

    return %orig;
}
*/

-(NSString *)snapshotContainerPath {
    NSString* path = %orig;
    NSString *bundleIdentifier = self.bundleIdentifier;
    if (![path isKindOfClass:NSString.class] ||
        ![bundleIdentifier isKindOfClass:NSString.class] || !bundleIdentifier.length) return path;

    if([path hasPrefix:@"/var/mobile/Library/SplashBoard/Snapshots/"] && (![bundleIdentifier hasPrefix:@"com.apple."] || is_apple_internal_identifier(bundleIdentifier.UTF8String))) {
        NSString *redirectedPath = springboardJbrootPath(path);
        if (!redirectedPath) return path;
        BOOL isDirectory = NO;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        BOOL exists = [fileManager fileExistsAtPath:redirectedPath isDirectory:&isDirectory];

		if ((!exists || !isDirectory)) {
			NSError *error = nil;
			BOOL created = [fileManager createDirectoryAtPath:redirectedPath
				withIntermediateDirectories:YES
				attributes:@{ NSFilePosixPermissions : @0755 }
				error:&error];
			if (!created) {
				NSLog(@"snapshotContainerPath fallback %@ : failed to create %@ (%@)", self.bundleIdentifier, redirectedPath, error);
				return path;
			}
		}

		NSLog(@"snapshotContainerPath redirect %@ : %@ -> %@", self.bundleIdentifier, path, redirectedPath);
		path = redirectedPath;
    }

    return path;
}

%end

static BOOL springboardSnapshotMethodMatches(Method method, const char *returnTypes, const char *argumentTypes)
{
	if (!method || !method_getTypeEncoding(method)) return NO;
	NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
	size_t argumentCount = strlen(argumentTypes);
	if (signature.numberOfArguments != argumentCount + 2 ||
		!strchr(returnTypes, signature.methodReturnType[0])) return NO;
	for (size_t index = 0; index < argumentCount; index++) {
		if ([signature getArgumentTypeAtIndex:index + 2][0] != argumentTypes[index]) return NO;
	}
	return YES;
}

static BOOL springboardSnapshotWriteAPIAvailable(void)
{
	Class manifest = NSClassFromString(@"XBApplicationSnapshotManifestImpl");
	Class snapshot = NSClassFromString(@"XBApplicationSnapshot");
	Class identity = NSClassFromString(@"XBSnapshotContainerIdentity");
	if (!manifest || !snapshot || !identity) return NO;
	return springboardSnapshotMethodMatches(class_getInstanceMethod(manifest,
			@selector(_imageAccessQueue_saveData:forSnapshot:)), "Bc", "@@") &&
		springboardSnapshotMethodMatches(class_getClassMethod(manifest,
			@selector(_outputFormatForSnapshot:)), "q", "@") &&
		springboardSnapshotMethodMatches(class_getInstanceMethod(snapshot,
			@selector(containerIdentity)), "@", "") &&
		springboardSnapshotMethodMatches(class_getInstanceMethod(snapshot,
			@selector(_configureDefaultPathWithinGroupForFormat:)), "@", "q") &&
		springboardSnapshotMethodMatches(class_getInstanceMethod(identity,
			@selector(bundleIdentifier)), "@", "") &&
		springboardSnapshotMethodMatches(class_getInstanceMethod(identity,
			@selector(snapshotContainerPath)), "@", "");
}

%group SnapshotWriteHooks
%hook XBApplicationSnapshotManifestImpl

- (BOOL)_imageAccessQueue_saveData:(NSData *)data forSnapshot:(XBApplicationSnapshot *)snapshot
{
	if (![data isKindOfClass:NSData.class] || !data.length ||
		![snapshot isKindOfClass:NSClassFromString(@"XBApplicationSnapshot")]) {
		return %orig;
	}

	XBSnapshotContainerIdentity *identity = snapshot.containerIdentity;
	if (![identity isKindOfClass:NSClassFromString(@"XBSnapshotContainerIdentity")]) return %orig;
	NSString *bundleIdentifier = identity.bundleIdentifier;
	if (![bundleIdentifier isKindOfClass:NSString.class] || !bundleIdentifier.length) return %orig;
	BOOL isStockAppleApp = [bundleIdentifier hasPrefix:@"com.apple."] &&
		!is_apple_internal_identifier(bundleIdentifier.UTF8String);
	if (isStockAppleApp) return %orig;

	// Both paths use the current randomized RootHide root, not /var/jb.
	NSString *snapshotRoot = springboardJbrootPath(@"/var/mobile/Library/SplashBoard/Snapshots");
	if (!snapshotRoot) return %orig;
	snapshotRoot = [snapshotRoot.stringByStandardizingPath stringByAppendingString:@"/"];
	NSString *containerPath = identity.snapshotContainerPath;
	if (![containerPath isKindOfClass:NSString.class] ||
		![containerPath.stringByStandardizingPath hasPrefix:snapshotRoot]) return %orig;

	NSString *path = [snapshot _configureDefaultPathWithinGroupForFormat:
		[[self class] _outputFormatForSnapshot:snapshot]];
	if (!path) return NO;
	if (![path isKindOfClass:NSString.class]) return %orig;
	path = path.stringByStandardizingPath;
	if (![path hasPrefix:snapshotRoot]) return %orig;

	NSFileManager *fileManager = NSFileManager.defaultManager;
	if (![fileManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
		withIntermediateDirectories:YES attributes:nil error:nil]) return %orig;
	// Avoid the default file-protection operation on RootHide snapshot files.
	return [data writeToFile:path options:0 error:nil];
}

%end
%end // SnapshotWriteHooks

static const void *kDenyQueryTagKey = &kDenyQueryTagKey;

%hook FBSApplicationLibrary
-(id)applicationInfoForBundleIdentifier:(NSString*)bundleIdentifier
{
	id result = %orig; //SBApplicationInfo
	NSURL* executableURL = [result performSelector:@selector(executableURL)];
	NSLog(@"FBSApplicationLibrary applicationInfoForBundleIdentifier %@ : %@, %@", bundleIdentifier, result, executableURL);

	NSNumber* tag = objc_getAssociatedObject(bundleIdentifier, kDenyQueryTagKey);

	if(tag && tag.boolValue) {

		if(is_sensitive_app_identifier(bundleIdentifier.UTF8String)) {
			NSLog(@"FBSApplicationLibrary deny query %@", bundleIdentifier);
			return nil;
		}

		if(result && executableURL && isJailbreakBundlePath(executableURL.path.fileSystemRepresentation)) {
			NSLog(@"FBSApplicationLibrary deny query %@", bundleIdentifier);
			return nil;
		}
	}

	return result;
}
%end

%hook FBSystemService
-(void*)openApplication:(NSString*)bundleIdentifier withOptions:(id)options originator:(id)originator requestID:(void*)requestID completion:(void*)completion
{
	NSLog(@"openApplication %@ withOptions:%@ originator:%@ requestID:%@ completion:%p", bundleIdentifier, options, originator, requestID, completion);

	id currentContext = [NSClassFromString(@"BSServiceConnection") performSelector:@selector(currentContext)];
	id remoteProcess = [currentContext performSelector:@selector(remoteProcess)]; //BSProcessHandle

	NSNumber* _pid = [remoteProcess valueForKey:@"_pid"];
	NSString* _bundleID = [remoteProcess valueForKey:@"_bundleID"]; //may be nil

	pid_t pid = _pid.intValue;

	NSLog(@"openApplication %@ from pid=%d bundleID=%@", bundleIdentifier, pid, _bundleID);

	BOOL taggedDenyQuery = jbclient_blacklist_check_pid(pid);
	if(taggedDenyQuery) {
		NSLog(@"openApplication deny request from %@", _bundleID);
		objc_setAssociatedObject(bundleIdentifier, kDenyQueryTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	void *result = %orig;

	// The tag is call-scoped. Leaving it attached permanently makes unrelated
	// SplashBoard queries treat jailbreak apps as missing and deny snapshots.
	if(taggedDenyQuery) {
		objc_setAssociatedObject(bundleIdentifier, kDenyQueryTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	return result;
}
%end

void sbInit(void)
{
	NSLog(@"sbInit...");
	%init();
	if (springboardSnapshotWriteAPIAvailable()) {
		%init(SnapshotWriteHooks);
	}
	extern void rcLowPowerScheduleStart(void);
	rcLowPowerScheduleStart();
}
