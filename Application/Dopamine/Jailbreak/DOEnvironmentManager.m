//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"
#import "UIImage+JPEG2000.h"

#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <errno.h>
#import <unistd.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <libgrabkernel2/libgrabkernel2.h>
#import <libjailbreak/info.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/util.h>
#import <libjailbreak/display.h>
#import <libjailbreak/machine_info.h>
#import <libjailbreak/carboncopy.h>

#import <IOKit/IOKitLib.h>
#import "DOUIManager.h"
#import "DOExploitManager.h"
#import "DOPreferenceManager.h"
#import "NSData+Hex.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <CoreServices/LSApplicationProxy.h>

int reboot3(uint64_t flags, ...);
CFPropertyListRef MGCopyAnswer(CFStringRef);
extern char **environ;

@implementation DOEnvironmentManager

@synthesize bootManifestHash = _bootManifestHash;

+ (instancetype)sharedManager
{
    static DOEnvironmentManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DOEnvironmentManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bootstrapNeedsMigration = NO;
        _bootstrapper = [[DOBootstrapper alloc] init];
        if ([self isJailbroken]) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jbclient_get_jbroot() ?: "");
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
}

- (NSString *)nightlyHash
{
#ifdef NIGHTLY
    return [NSString stringWithUTF8String:COMMIT_HASH];
#else
    return nil;
#endif
}

- (NSString *)appVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString *)appVersionDisplayString
{
    NSString *nightlyHash = [self nightlyHash];
    if (nightlyHash) {
        return [NSString stringWithFormat:@"%@~%@", self.appVersion, [nightlyHash substringToIndex:6]];
    }
    else {
        return [self appVersion];
    }
}

- (NSData *)bootManifestHash
{
    if (!_bootManifestHash) {
        io_registry_entry_t registryEntry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
        if (registryEntry) {
            _bootManifestHash = (__bridge NSData *)IORegistryEntryCreateCFProperty(registryEntry, CFSTR("boot-manifest-hash"), NULL, 0);
        }
    }
    return _bootManifestHash;
}

- (NSString *)privatePrebootPath
{
    return @"/private/preboot";
}

- (NSString *)activePrebootPath
{
    return [[self privatePrebootPath] stringByAppendingPathComponent:[self bootManifestHash].hexString];
}

- (BOOL)isArm64e
{
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0) == -1) { return NO; }
    return (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

- (BOOL)isSPTM
{
    if (@available(iOS 17.0, *)) {
        io_registry_entry_t memoryMap = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen/memory-map");
        if (memoryMap == IO_OBJECT_NULL) return NO;

        CFArrayRef keys = (CFArrayRef)IORegistryEntryCreateCFProperty(memoryMap, CFSTR(kIORegistryEntryPropertyKeysKey), kCFAllocatorDefault, 0);
        IOObjectRelease(memoryMap);
        if (!keys) return NO;

        CFRange range = CFRangeMake(0, CFArrayGetCount(keys));
        BOOL isSPTM = CFArrayContainsValue(keys, range, CFSTR("SPTM")) && CFArrayContainsValue(keys, range, CFSTR("TXM"));
        CFRelease(keys);
        return isSPTM;
    }
    return NO;
}

- (NSString *)versionSupportString
{
    return @"iOS 16.0 – 16.7.16";
}

- (BOOL)isInstalledThroughTrollStore
{
    static BOOL trollstoreInstallation = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* trollStoreMarkerPath = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_TrollStore"];
        trollstoreInstallation = [[NSFileManager defaultManager] fileExistsAtPath:trollStoreMarkerPath];
    });
    return trollstoreInstallation;
}

- (BOOL)isJailbroken
{
/************** roothide specific ***********/
    if (_isJailbroken)
        return YES;

    if(!jbclient_roothide_jailbroken())
        return NO;
/************** roothide specific ********/

    uint32_t csFlags = 0;
    csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
    _isJailbroken = (csFlags & CS_PLATFORM_BINARY) != 0;
    return _isJailbroken;
}

- (void)setJailbroken:(BOOL)jailbroken withVersion:(NSString *)version
{
    _isJailbroken = jailbroken;
}

- (BOOL)isJailbrokenWithOtherJailbreak
{
    if (![self isJailbroken]) {
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
        
        // Palera1n
        if (csFlags & CS_PLATFORM_BINARY) return YES;
        
        // Older Dopamine build
        if (!access("/usr/lib/systemhook.dylib", F_OK)) return YES;
    }
    return NO;
}

- (NSString *)jailbrokenVersion
{
    if (!self.isJailbroken) return nil;

    __block NSString *version;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            version = [NSString stringWithContentsOfFile:JBROOT_PATH(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil];
        }];
    }];
    return [[version componentsSeparatedByString:@"."] lastObject];
}

- (NSString *)systemVersion
{
    return (__bridge NSString *)MGCopyAnswer(CFSTR("ProductVersion"));
}

- (BOOL)isBootstrapped
{
    return (BOOL)jbinfo(rootPath);
}

- (void)runUnsandboxed:(void (^)(void))unsandboxBlock
{
    if ([self isInstalledThroughTrollStore]) {
        unsandboxBlock();
    }
    else if([self isJailbroken]) {
        uint64_t labelBackup = 0;
        jbclient_root_set_mac_label(1, -1, &labelBackup);
        unsandboxBlock();
        jbclient_root_set_mac_label(1, labelBackup, NULL);
    }
    else {
        // Hope that we are already unsandboxed
        unsandboxBlock();
    }
}

- (void)runAsRoot:(void (^)(void))rootBlock
{
    uint32_t orgUser = getuid();
    uint32_t orgGroup = getgid();
    if (geteuid() == 0 && orgGroup == 0) {
        rootBlock();
        return;
    }

    int ur = 0, gr = 0;
    if (orgUser != 0) ur = setuid(0);
    if (orgGroup != 0) gr = setgid(0);
    if (ur == 0 && gr == 0) {
        rootBlock();
    }
    
    if (gr == 0 && orgGroup != 0) setgid(orgGroup);
    if (ur == 0 && orgUser != 0) seteuid(orgUser);
}

- (int)spawnJbctlAsRootWithArgs:(NSArray *)args
{
    // --waitfor was introduced in Dopamine 3.0.5. Keep the suspended-spawn
    // fallback only for an already-installed older jailbreak.
    bool needsLegacySolution = false;
    if (self.jailbrokenVersion) {
        needsLegacySolution = ([self.jailbrokenVersion compare:@"3.0.5" options:NSNumericSearch] == NSOrderedAscending);
    }

    size_t argCapacity = args.count + 4;
    char **argBuf = calloc(argCapacity, sizeof(char *));
    if (!argBuf) return ENOMEM;

    int i = 0;
    argBuf[i++] = strdup(JBROOT_PATH("/basebin/jbctl"));
    for (NSString *arg in args) {
        argBuf[i++] = strdup(arg.UTF8String);
    }
    if (!needsLegacySolution) {
        argBuf[i++] = strdup("--waitfor");
        argBuf[i++] = strdup("3");
    }
    argBuf[i] = NULL;

    for (int n = 0; n < i; n++) {
        if (!argBuf[n]) {
            for (int y = 0; y < i; y++) free(argBuf[y]);
            free(argBuf);
            return ENOMEM;
        }
    }

    __block pid_t pid = -1;
    __block int spawnResult = -1;

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;

    int r = posix_spawn_file_actions_init(&actions);
    if (r != 0) {
        for (int y = 0; y < i; y++) free(argBuf[y]);
        free(argBuf);
        return r;
    }

    r = posix_spawnattr_init(&attr);
    if (r != 0) {
        posix_spawn_file_actions_destroy(&actions);
        for (int y = 0; y < i; y++) free(argBuf[y]);
        free(argBuf);
        return r;
    }

    int waitPipe[2] = {-1, -1};

    if (!needsLegacySolution) {
        if (pipe(waitPipe) != 0) {
            r = errno;
            posix_spawnattr_destroy(&attr);
            posix_spawn_file_actions_destroy(&actions);
            for (int y = 0; y < i; y++) free(argBuf[y]);
            free(argBuf);
            return r;
        }

        r = posix_spawn_file_actions_adddup2(&actions, waitPipe[0], 3);
        if (r != 0) {
            close(waitPipe[0]);
            close(waitPipe[1]);
            posix_spawnattr_destroy(&attr);
            posix_spawn_file_actions_destroy(&actions);
            for (int y = 0; y < i; y++) free(argBuf[y]);
            free(argBuf);
            return r;
        }
    }
    else {
        r = posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
        if (r != 0) {
            posix_spawnattr_destroy(&attr);
            posix_spawn_file_actions_destroy(&actions);
            for (int y = 0; y < i; y++) free(argBuf[y]);
            free(argBuf);
            return r;
        }
    }

    [self runAsRoot:^{
        [self runUnsandboxed:^{
            spawnResult = posix_spawn(&pid, argBuf[0], &actions, &attr, argBuf, environ);
            if (needsLegacySolution && spawnResult == 0) {
                // Compatibility only: Dopamine <3.0.5 jbctl has no --waitfor support.
                kill(pid, SIGCONT);
            }
        }];
        // For the normal 3.0.7 path, the child remains blocked on fd 3 until
        // both the temporary sandbox and credential changes have been restored.
    }];

    if (!needsLegacySolution && spawnResult == 0) {
        char token = 'w';
        (void)write(waitPipe[1], &token, sizeof(token));
    }

    r = (spawnResult == 0) ? cmd_wait_for_exit(pid) : spawnResult;

    if (waitPipe[0] >= 0) close(waitPipe[0]);
    if (waitPipe[1] >= 0) close(waitPipe[1]);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);

    for (int y = 0; y < i; y++) free(argBuf[y]);
    free(argBuf);

    return r;
}

- (int)runTrollStoreAction:(NSString *)action
{
    if (![self isInstalledThroughTrollStore]) return -1;
    
    uint32_t selfPathSize = PATH_MAX;
    char selfPath[selfPathSize];
    _NSGetExecutablePath(selfPath, &selfPathSize);
    return exec_cmd_root(selfPath, "trollstore", action.UTF8String, NULL);
}

- (void)respring
{
    // D1 sequencing: let jbctl wait until the app has left the temporary
    // root/unsandboxed critical sections before it performs the respring.
    [self spawnJbctlAsRootWithArgs:@[@"respring"]];
}

- (void)rebootUserspace
{
    // Same sequencing rule as respring. The --waitfor pipe is handled by
    // spawnJbctlAsRootWithArgs:, while older installed jbctl versions keep
    // using the compatibility path inside that helper.
    [self spawnJbctlAsRootWithArgs:@[@"reboot_userspace"]];
}

- (void)refreshJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-a", NULL);
        }];
    }];
}

static NSString *DOCanonicalApplicationPath(NSString *path)
{
    if (!path.length) return nil;
    return [[path stringByResolvingSymlinksInPath] stringByStandardizingPath];
}

static NSString *DORegisteredApplicationPath(NSString *bundleIdentifier)
{
    if (!bundleIdentifier.length) return nil;

    LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleIdentifier];
    if (!appProxy.installed || !appProxy.bundleURL.path.length) return nil;
    return DOCanonicalApplicationPath(appProxy.bundleURL.path);
}

typedef NS_ENUM(NSUInteger, DOJailbreakAppRegistrationState) {
    DOJailbreakAppRegistrationStateMissing,
    DOJailbreakAppRegistrationStateMatches,
    DOJailbreakAppRegistrationStateStale,
    DOJailbreakAppRegistrationStateConflict,
};

static DOJailbreakAppRegistrationState DOJailbreakAppRegistrationStateForPath(NSString *bundleIdentifier, NSString *expectedPath, NSString **registeredPathOut)
{
    NSString *registeredPath = DORegisteredApplicationPath(bundleIdentifier);
    if (registeredPathOut) *registeredPathOut = registeredPath;

    if (!registeredPath) return DOJailbreakAppRegistrationStateMissing;
    if ([registeredPath isEqualToString:DOCanonicalApplicationPath(expectedPath)]) return DOJailbreakAppRegistrationStateMatches;
    if (![[NSFileManager defaultManager] fileExistsAtPath:registeredPath]) return DOJailbreakAppRegistrationStateStale;
    return DOJailbreakAppRegistrationStateConflict;
}

static NSError *DOJailbreakAppRegistrationConflictError(NSString *bundleIdentifier, NSString *expectedPath, NSString *registeredPath)
{
    return [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                               code:EEXIST
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Refusing to replace an existing app registration for %@. Expected %@, but LaunchServices is registered to %@.", bundleIdentifier, expectedPath, registeredPath]}];
}

static NSError *DOJailbreakAppUserConflictError(NSString *bundleIdentifier, NSString *expectedPath, NSString *userAppPath)
{
    return [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                               code:EEXIST
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Refusing to repair %@ at %@ because a user application with the same bundle identifier exists at %@.", bundleIdentifier, expectedPath, userAppPath]}];
}

static NSString *DOUserApplicationPathForBundleIdentifier(NSString *bundleIdentifier)
{
    if (!bundleIdentifier.length) return nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *userAppsPath = @"/var/containers/Bundle/Application";
    for (NSString *appUUID in [fileManager contentsOfDirectoryAtPath:userAppsPath error:nil]) {
        NSString *UUIDPath = [userAppsPath stringByAppendingPathComponent:appUUID];
        for (NSString *appCandidate in [fileManager contentsOfDirectoryAtPath:UUIDPath error:nil]) {
            if (![appCandidate.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *userAppPath = [UUIDPath stringByAppendingPathComponent:appCandidate];
            NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[userAppPath stringByAppendingPathComponent:@"Info.plist"]];
            if ([infoDictionary[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) {
                return DOCanonicalApplicationPath(userAppPath);
            }
        }
    }
    return nil;
}

- (NSError *)repairJailbreakApps
{
    __block NSError *repairError = nil;
    __block BOOL repairAttempted = NO;

    [self runAsRoot:^{
        repairAttempted = YES;
        [self runUnsandboxed:^{
            const char *uicachePath = JBROOT_PATH("/usr/bin/uicache");
            if (access(uicachePath, X_OK) != 0) {
                int errorCode = errno ? errno : ENOENT;
                repairError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errorCode userInfo:nil];
                return;
            }

            NSString *applicationsPath = JBROOT_PATH(@"/Applications");
            NSError *directoryError = nil;
            NSArray<NSString *> *applicationNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:applicationsPath error:&directoryError];
            if (!applicationNames) {
                repairError = directoryError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
                return;
            }

            // Build and validate the complete jailbreak-app set before changing LaunchServices.
            NSMutableDictionary<NSString *, NSString *> *applicationsByIdentifier = [NSMutableDictionary dictionary];
            for (NSString *applicationName in applicationNames) {
                if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

                NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
                NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
                if (!bundleIdentifier.length) {
                    repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                       code:EINVAL
                                                   userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Jailbreak app is missing CFBundleIdentifier: %@", applicationPath]}];
                    return;
                }

                if (applicationsByIdentifier[bundleIdentifier]) {
                    repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                       code:EEXIST
                                                   userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Duplicate jailbreak app bundle identifier: %@", bundleIdentifier]}];
                    return;
                }
                applicationsByIdentifier[bundleIdentifier] = applicationPath;
            }

            // Mirror DOJailbreaker's physical duplicate-app protection. LaunchServices can
            // itself be stale, so checking only LSApplicationProxy is not sufficient here.
            NSString *userAppsPath = @"/var/containers/Bundle/Application";
            for (NSString *appUUID in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:userAppsPath error:nil]) {
                NSString *UUIDPath = [userAppsPath stringByAppendingPathComponent:appUUID];
                for (NSString *appCandidate in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:UUIDPath error:nil]) {
                    if (![appCandidate.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

                    NSString *userAppPath = [UUIDPath stringByAppendingPathComponent:appCandidate];
                    NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[userAppPath stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
                    if (!bundleIdentifier.length) continue;
                    NSString *jailbreakAppPath = applicationsByIdentifier[bundleIdentifier];
                    if (jailbreakAppPath) {
                        repairError = DOJailbreakAppUserConflictError(bundleIdentifier, jailbreakAppPath, userAppPath);
                        return;
                    }
                }
            }

            // Preflight every registration before mutating any of them. A mismatched path
            // that still exists is a real conflict; a missing old path is a repairable stale
            // registration (for example after a jbroot rerandomization).
            for (NSString *bundleIdentifier in applicationsByIdentifier) {
                NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                NSString *registeredPath = nil;
                DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }
            }

            BOOL needsFullRefresh = NO;
            for (NSString *bundleIdentifier in applicationsByIdentifier) {
                NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                NSString *registeredPath = nil;
                DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateMatches) continue;
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }

                // Missing and stale registrations are both safe to repair in place. uicache
                // registration replaces the stale LS record without touching a live app path.
                exec_cmd(uicachePath, "-p", applicationPath.fileSystemRepresentation, NULL);

                state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }
                if (state != DOJailbreakAppRegistrationStateMatches) {
                    needsFullRefresh = YES;
                }
            }

            if (needsFullRefresh) {
                // Re-check before the broad fallback so a registration that appeared
                // concurrently is never overwritten by a full refresh.
                needsFullRefresh = NO;
                for (NSString *bundleIdentifier in applicationsByIdentifier) {
                    NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                    NSString *registeredPath = nil;
                    DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                    if (state == DOJailbreakAppRegistrationStateMatches) continue;
                    if (state == DOJailbreakAppRegistrationStateConflict) {
                        repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                        return;
                    }
                    needsFullRefresh = YES;
                }
            }

            if (needsFullRefresh) {
                int result = exec_cmd(uicachePath, "-a", NULL);
                if (result != 0) {
                    repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                       code:result
                                                   userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to refresh jailbreak app registrations (uicache exit %d).", result]}];
                    return;
                }
            }

            NSMutableArray<NSString *> *remainingIssues = [NSMutableArray array];
            for (NSString *bundleIdentifier in applicationsByIdentifier) {
                NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                NSString *registeredPath = nil;
                DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }
                if (state != DOJailbreakAppRegistrationStateMatches) {
                    [remainingIssues addObject:bundleIdentifier];
                }
            }

            if (remainingIssues.count) {
                repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                   code:EIO
                                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Jailbreak app registration is still inconsistent for: %@", [remainingIssues componentsJoinedByString:@", "]]}];
            }
        }];
    }];

    if (!repairAttempted && !repairError) {
        repairError = [NSError errorWithDomain:NSPOSIXErrorDomain
                                           code:EPERM
                                       userInfo:@{NSLocalizedDescriptionKey : @"Failed to enter the root context required to repair jailbreak app registrations."}];
    }

    return repairError;
}

static NSString *DOPackageManagerHealthStateName(DOPackageManagerHealthState state)
{
    switch (state) {
        case DOPackageManagerHealthStateNotSelected: return @"Not Selected";
        case DOPackageManagerHealthStateHealthy: return @"Healthy";
        case DOPackageManagerHealthStateAppMissing: return @"App Missing";
        case DOPackageManagerHealthStateBundleInvalid: return @"Bundle Invalid";
        case DOPackageManagerHealthStateRegistrationMissing: return @"Registration Missing";
        case DOPackageManagerHealthStateRegistrationStale: return @"Registration Stale";
        case DOPackageManagerHealthStateRegistrationConflict: return @"Registration Conflict";
        case DOPackageManagerHealthStateInspectionFailed: return @"Inspection Failed";
    }
    return @"Unknown";
}

- (NSArray<NSDictionary<NSString *, id> *> *)packageManagerHealthReport
{
    NSArray<NSDictionary *> *packageManagers = [[DOUIManager sharedInstance] availablePackageManagers];
    NSSet<NSString *> *enabledPackageManagerKeys = [NSSet setWithArray:[[DOUIManager sharedInstance] enabledPackageManagerKeys]];
    __block NSMutableArray<NSDictionary<NSString *, id> *> *healthReport = [NSMutableArray arrayWithCapacity:packageManagers.count];

    [self runUnsandboxed:^{
        NSString *applicationsPath = JBROOT_PATH(@"/Applications");
        NSError *directoryError = nil;
        NSArray<NSString *> *applicationNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:applicationsPath error:&directoryError];

        NSMutableDictionary<NSString *, NSString *> *applicationPathsByIdentifier = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *duplicateIdentifiers = [NSMutableSet set];
        for (NSString *applicationName in applicationNames ?: @[]) {
            if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

            NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
            NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
            if (!bundleIdentifier.length) continue;

            if (applicationPathsByIdentifier[bundleIdentifier]) {
                [duplicateIdentifiers addObject:bundleIdentifier];
            }
            else {
                applicationPathsByIdentifier[bundleIdentifier] = applicationPath;
            }
        }

        for (NSDictionary *packageManager in packageManagers) {
            NSString *displayName = packageManager[@"Display Name"];
            NSString *bundleIdentifier = packageManager[@"Key"];
            BOOL selected = bundleIdentifier.length && [enabledPackageManagerKeys containsObject:bundleIdentifier];
            DOPackageManagerHealthState state = DOPackageManagerHealthStateNotSelected;
            NSString *applicationPath = nil;
            NSString *registeredPath = nil;
            NSString *detail = nil;

            if (selected) {
                NSString *userAppPath = DOUserApplicationPathForBundleIdentifier(bundleIdentifier);
                if (userAppPath) {
                    state = DOPackageManagerHealthStateRegistrationConflict;
                    detail = [NSString stringWithFormat:@"A user application with the same bundle identifier exists at %@.", userAppPath];
                }
                else if (!applicationNames) {
                    state = DOPackageManagerHealthStateInspectionFailed;
                    detail = directoryError.localizedDescription ?: @"Unable to enumerate jailbreak applications.";
                }
                else if ([duplicateIdentifiers containsObject:bundleIdentifier]) {
                    state = DOPackageManagerHealthStateBundleInvalid;
                    applicationPath = applicationPathsByIdentifier[bundleIdentifier];
                    detail = [NSString stringWithFormat:@"Multiple jailbreak applications use the bundle identifier %@.", bundleIdentifier];
                }
                else {
                    applicationPath = applicationPathsByIdentifier[bundleIdentifier];
                    if (!applicationPath) {
                        NSString *namedApplicationPath = displayName.length ? [applicationsPath stringByAppendingPathComponent:[displayName stringByAppendingPathExtension:@"app"]] : nil;
                        BOOL namedApplicationExists = namedApplicationPath.length && [[NSFileManager defaultManager] fileExistsAtPath:namedApplicationPath];
                        registeredPath = DORegisteredApplicationPath(bundleIdentifier);

                        // When the current jbroot app is missing, a live registration at some
                        // other path is a conflict and must be surfaced before any reinstall.
                        // A missing registered path is only stale metadata and is repairable.
                        BOOL registeredPathExists = registeredPath.length && [[NSFileManager defaultManager] fileExistsAtPath:registeredPath];
                        NSString *canonicalNamedPath = DOCanonicalApplicationPath(namedApplicationPath);
                        BOOL registeredToNamedPath = registeredPathExists && canonicalNamedPath.length && [registeredPath isEqualToString:canonicalNamedPath];
                        if (registeredPathExists && !registeredToNamedPath) {
                            state = DOPackageManagerHealthStateRegistrationConflict;
                            detail = [NSString stringWithFormat:@"LaunchServices is registered to a live application at %@ while the current %@ application is missing.", registeredPath, displayName ?: bundleIdentifier];
                        }
                        else if (namedApplicationExists) {
                            applicationPath = namedApplicationPath;
                            state = DOPackageManagerHealthStateBundleInvalid;
                            detail = [NSString stringWithFormat:@"%@ exists but its bundle identifier does not match %@.", namedApplicationPath.lastPathComponent, bundleIdentifier];
                        }
                        else {
                            state = DOPackageManagerHealthStateAppMissing;
                            if (registeredPath.length) {
                                detail = [NSString stringWithFormat:@"The application is missing and LaunchServices still references the stale path %@.", registeredPath];
                            }
                        }
                    }
                    else {
                        DOJailbreakAppRegistrationState registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                        switch (registrationState) {
                            case DOJailbreakAppRegistrationStateMatches:
                                state = DOPackageManagerHealthStateHealthy;
                                break;
                            case DOJailbreakAppRegistrationStateMissing:
                                state = DOPackageManagerHealthStateRegistrationMissing;
                                break;
                            case DOJailbreakAppRegistrationStateStale:
                                state = DOPackageManagerHealthStateRegistrationStale;
                                break;
                            case DOJailbreakAppRegistrationStateConflict:
                                state = DOPackageManagerHealthStateRegistrationConflict;
                                break;
                        }
                    }
                }
            }

            NSMutableDictionary<NSString *, id> *entry = [@{
                @"DisplayName" : displayName ?: bundleIdentifier ?: @"Package Manager",
                @"BundleIdentifier" : bundleIdentifier ?: @"",
                @"Selected" : @(selected),
                @"State" : @(state),
                @"StateName" : DOPackageManagerHealthStateName(state),
            } mutableCopy];
            if (applicationPath.length) entry[@"ApplicationPath"] = DOCanonicalApplicationPath(applicationPath);
            if (registeredPath.length) entry[@"RegisteredPath"] = registeredPath;
            if (detail.length) entry[@"Detail"] = detail;
            [healthReport addObject:entry];
        }
    }];

    return healthReport.copy;
}

static NSError *DOPackageManagerRepairError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:@"DOPackageManagerRepairErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description ?: @"Package manager repair failed."}];
}

static BOOL DOPackageManagerBundleInvalidIsReinstallable(NSDictionary *packageManager)
{
    NSString *displayName = packageManager[@"Display Name"];
    NSString *bundleIdentifier = packageManager[@"Key"];
    if (!displayName.length || !bundleIdentifier.length) return NO;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *applicationsPath = JBROOT_PATH(@"/Applications");
    NSUInteger matchingIdentifierCount = 0;
    for (NSString *applicationName in [fileManager contentsOfDirectoryAtPath:applicationsPath error:nil]) {
        if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
        NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
        NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
        if ([infoDictionary[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) {
            matchingIdentifierCount++;
            if (matchingIdentifierCount > 1) return NO;
        }
    }
    if (matchingIdentifierCount != 0) return NO;

    NSString *namedApplicationPath = [applicationsPath stringByAppendingPathComponent:[displayName stringByAppendingPathExtension:@"app"]];
    if (![fileManager fileExistsAtPath:namedApplicationPath]) return NO;
    NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[namedApplicationPath stringByAppendingPathComponent:@"Info.plist"]];
    return ![infoDictionary[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier];
}

- (NSError *)repairPackageManagers
{
    NSArray<NSDictionary<NSString *, id> *> *initialReport = [self packageManagerHealthReport];
    NSArray<NSDictionary *> *availablePackageManagers = [[DOUIManager sharedInstance] availablePackageManagers];
    NSMutableDictionary<NSString *, NSDictionary *> *packageManagersByIdentifier = [NSMutableDictionary dictionary];
    for (NSDictionary *packageManager in availablePackageManagers) {
        NSString *bundleIdentifier = packageManager[@"Key"];
        if (bundleIdentifier.length) packageManagersByIdentifier[bundleIdentifier] = packageManager;
    }

    NSMutableArray<NSString *> *packageManagersToInstall = [NSMutableArray array];
    BOOL needsUICache = NO;
    for (NSDictionary<NSString *, id> *entry in initialReport) {
        if (![entry[@"Selected"] boolValue]) continue;

        NSString *bundleIdentifier = entry[@"BundleIdentifier"];
        NSString *displayName = entry[@"DisplayName"] ?: bundleIdentifier ?: @"Package Manager";
        DOPackageManagerHealthState state = [entry[@"State"] unsignedIntegerValue];
        if (state == DOPackageManagerHealthStateHealthy || state == DOPackageManagerHealthStateNotSelected) continue;

        NSDictionary *packageManager = packageManagersByIdentifier[bundleIdentifier];
        if (!packageManager) {
            return DOPackageManagerRepairError(ENOENT, [NSString stringWithFormat:@"Missing package manager configuration for %@.", displayName]);
        }
        if (state == DOPackageManagerHealthStateRegistrationConflict) {
            return DOPackageManagerRepairError(EEXIST, entry[@"Detail"] ?: [NSString stringWithFormat:@"Refusing to repair conflicting registration for %@.", displayName]);
        }
        if (state == DOPackageManagerHealthStateInspectionFailed) {
            return DOPackageManagerRepairError(EIO, entry[@"Detail"] ?: [NSString stringWithFormat:@"Unable to inspect %@ safely.", displayName]);
        }
        if (state == DOPackageManagerHealthStateBundleInvalid) {
            __block BOOL reinstallable = NO;
            [self runUnsandboxed:^{
                reinstallable = DOPackageManagerBundleInvalidIsReinstallable(packageManager);
            }];
            if (!reinstallable) {
                return DOPackageManagerRepairError(EEXIST, entry[@"Detail"] ?: [NSString stringWithFormat:@"%@ has an ambiguous jailbreak application layout that cannot be repaired safely.", displayName]);
            }
        }

        if (state == DOPackageManagerHealthStateAppMissing || state == DOPackageManagerHealthStateBundleInvalid) {
            NSString *packageName = packageManager[@"Package"];
            if (!packageName.length) {
                return DOPackageManagerRepairError(EINVAL, [NSString stringWithFormat:@"Missing bundled package configuration for %@.", displayName]);
            }
            NSString *packagePath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:packageName];
            if (![[NSFileManager defaultManager] fileExistsAtPath:packagePath]) {
                return DOPackageManagerRepairError(ENOENT, [NSString stringWithFormat:@"Bundled package for %@ is missing: %@", displayName, packageName]);
            }
            [packageManagersToInstall addObject:bundleIdentifier];
        }
        needsUICache = YES;
    }

    if (needsUICache) {
        __block BOOL uicacheAvailable = NO;
        __block int uicacheErrorCode = ENOENT;
        [self runUnsandboxed:^{
            if (access(JBROOT_PATH("/usr/bin/uicache"), X_OK) == 0) {
                uicacheAvailable = YES;
            }
            else if (errno) {
                uicacheErrorCode = errno;
            }
        }];
        if (!uicacheAvailable) {
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:uicacheErrorCode userInfo:nil];
        }
    }

    if (packageManagersToInstall.count) {
        __block NSError *installError = nil;
        __block BOOL rootAttempted = NO;
        [self runAsRoot:^{
            rootAttempted = YES;
            [self runUnsandboxed:^{
                for (NSString *bundleIdentifier in packageManagersToInstall) {
                    NSString *userAppPath = DOUserApplicationPathForBundleIdentifier(bundleIdentifier);
                    if (userAppPath) {
                        installError = DOPackageManagerRepairError(EEXIST, [NSString stringWithFormat:@"Refusing to install %@ because a user application with the same bundle identifier exists at %@.", bundleIdentifier, userAppPath]);
                        return;
                    }
                    installError = [self->_bootstrapper installPackageManagerWithKey:bundleIdentifier];
                    if (installError) return;
                }
            }];
        }];
        if (!rootAttempted && !installError) {
            installError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey : @"Failed to enter the root context required to repair package managers."}];
        }
        if (installError) return installError;
    }

    NSArray<NSDictionary<NSString *, id> *> *postInstallReport = [self packageManagerHealthReport];
    NSMutableArray<NSDictionary<NSString *, id> *> *registrationsToRepair = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *entry in postInstallReport) {
        if (![entry[@"Selected"] boolValue]) continue;

        DOPackageManagerHealthState state = [entry[@"State"] unsignedIntegerValue];
        if (state == DOPackageManagerHealthStateHealthy || state == DOPackageManagerHealthStateNotSelected) continue;
        if (state == DOPackageManagerHealthStateRegistrationMissing || state == DOPackageManagerHealthStateRegistrationStale) {
            [registrationsToRepair addObject:entry];
            continue;
        }

        NSString *displayName = entry[@"DisplayName"] ?: entry[@"BundleIdentifier"] ?: @"Package Manager";
        NSString *detail = entry[@"Detail"] ?: entry[@"StateName"] ?: @"Unknown state";
        return DOPackageManagerRepairError(state == DOPackageManagerHealthStateRegistrationConflict ? EEXIST : EIO, [NSString stringWithFormat:@"%@ is not safely repairable after reinstall: %@", displayName, detail]);
    }

    if (registrationsToRepair.count) {
        __block NSError *registrationError = nil;
        __block BOOL rootAttempted = NO;
        [self runAsRoot:^{
            rootAttempted = YES;
            [self runUnsandboxed:^{
                const char *uicachePath = JBROOT_PATH("/usr/bin/uicache");
                for (NSDictionary<NSString *, id> *entry in registrationsToRepair) {
                    NSString *bundleIdentifier = entry[@"BundleIdentifier"];
                    NSString *displayName = entry[@"DisplayName"] ?: bundleIdentifier ?: @"Package Manager";
                    NSString *applicationPath = entry[@"ApplicationPath"];
                    if (!applicationPath.length) {
                        registrationError = DOPackageManagerRepairError(EIO, [NSString stringWithFormat:@"Cannot determine the application path for %@.", displayName]);
                        return;
                    }

                    NSString *userAppPath = DOUserApplicationPathForBundleIdentifier(bundleIdentifier);
                    if (userAppPath) {
                        registrationError = DOPackageManagerRepairError(EEXIST, [NSString stringWithFormat:@"Refusing to register %@ because a user application with the same bundle identifier exists at %@.", displayName, userAppPath]);
                        return;
                    }

                    NSString *registeredPath = nil;
                    DOJailbreakAppRegistrationState registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                    if (registrationState == DOJailbreakAppRegistrationStateMatches) continue;
                    if (registrationState == DOJailbreakAppRegistrationStateConflict) {
                        registrationError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                        return;
                    }

                    int result = exec_cmd(uicachePath, "-p", applicationPath.fileSystemRepresentation, NULL);
                    registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                    if (registrationState == DOJailbreakAppRegistrationStateConflict) {
                        registrationError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                        return;
                    }
                    if (registrationState != DOJailbreakAppRegistrationStateMatches) {
                        registrationError = DOPackageManagerRepairError(result != 0 ? result : EIO, [NSString stringWithFormat:@"Failed to register %@ after repair (uicache exit %d).", displayName, result]);
                        return;
                    }
                }
            }];
        }];
        if (!rootAttempted && !registrationError) {
            registrationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey : @"Failed to enter the root context required to repair package manager registrations."}];
        }
        if (registrationError) return registrationError;
    }

    for (NSDictionary<NSString *, id> *entry in [self packageManagerHealthReport]) {
        if (![entry[@"Selected"] boolValue]) continue;
        if ([entry[@"State"] unsignedIntegerValue] != DOPackageManagerHealthStateHealthy) {
            NSString *displayName = entry[@"DisplayName"] ?: entry[@"BundleIdentifier"] ?: @"Package Manager";
            NSString *detail = entry[@"Detail"] ?: entry[@"StateName"] ?: @"Unknown state";
            return DOPackageManagerRepairError(EIO, [NSString stringWithFormat:@"%@ is still unhealthy after repair: %@", displayName, detail]);
        }
    }

    return nil;
}

- (void)unregisterJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSArray *jailbreakApps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:JBROOT_PATH(@"/Applications") error:nil];
            if (jailbreakApps.count) {
                for (NSString *jailbreakApp in jailbreakApps) {
                    NSString *jailbreakAppPath = [JBROOT_PATH(@"/Applications") stringByAppendingPathComponent:jailbreakApp];
                    exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-u", jailbreakAppPath.fileSystemRepresentation, NULL);
                }
            }
        }];
    }];
}

- (void)reboot
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            reboot3(0x8000000000000000, 0);
        }];
    }];
}


- (void)changeMobilePassword:(NSString *)newPassword
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *dashCommand = [NSString stringWithFormat:@"printf \"%%s\\n\" \"%@\" | %@ usermod 501 -h 0", newPassword, JBROOT_PATH(@"/usr/sbin/pw")];
            exec_cmd(JBROOT_PATH("/usr/bin/dash"), "-c", dashCommand.UTF8String, NULL);
        }];
    }];
}

- (NSError*)updateEnvironment
{
    NSString *newBasebinTarPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"];
    int result = jbclient_platform_stage_jailbreak_update(newBasebinTarPath.fileSystemRepresentation);
    if (result == 0) {
        [self rebootUserspace];
        return nil;
    }
    return [NSError errorWithDomain:@"Dopamine" code:result userInfo:nil];
}

- (void)updateJailbreakFromTIPA:(NSString *)tipaPath
{
    [self spawnJbctlAsRootWithArgs:@[@"update", @"tipa", tipaPath]];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/basebin/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = JBROOT_PATH(@"/basebin/.safe_mode");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:safeModePath error:nil];
                }
                else {
                    [[NSData data] writeToFile:safeModePath atomically:YES];
                }
            }];
        }];
    }
}

- (BOOL)isIDownloadEnabled
{
    __block BOOL isEnabled = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *disabledDict = [NSDictionary dictionaryWithContentsOfFile:@"/var/db/com.apple.xpc.launchd/disabled.plist"];
            NSNumber *idownloaddDisabledNum = disabledDict[@"com.opa334.Dopamine.idownloadd"];
            if (idownloaddDisabledNum) {
                isEnabled = ![idownloaddDisabledNum boolValue];
            }
            else {
                isEnabled = NO;
            }
        }];
    }];
    return isEnabled;
}

- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox
{
    void (^updateBlock)(void) = ^{
        if (enabled) {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "enable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
        else {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "disable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
}

- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox
{
    if (loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
    
    void (^updateBlock)(void) = ^{
        if (loaded) {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "load", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
        else {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "unload", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
    };
    
    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
    
    if (!loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
}

/*
- (BOOL)isFakelibMounted
{
    struct statfs fsb;
    if (statfs("/usr/lib", &fsb) != 0) return NO;
    return strcmp(fsb.f_mntonname, "/usr/lib") == 0;
}

- (int)setFakelibMounted:(BOOL)mounted
{
    int r = 0;
    if (mounted != [self isFakelibMounted]) {
        NSString *arg = mounted ? @"mount" : @"unmount";
        r = [self spawnJbctlAsRootWithArgs:@[@"internal", @"fakelib", arg]];
    }
    return r;
}

- (int)setPrivatePrebootProtected:(BOOL)protected
{
    NSString *arg = protected ? @"activate" : @"deactivate";
    return [self spawnJbctlAsRootWithArgs:@[@"internal", @"protection", arg]];
}

- (BOOL)isJailbreakHidden
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

- (void)setJailbreakHidden:(BOOL)hidden
{
    if (hidden && ![self isJailbroken] && geteuid() != 0) {
        [self runTrollStoreAction:@"hide-jailbreak"];
        return;
    }
    
    void (^actionBlock)(void) = ^{
        BOOL alreadyHidden = [self isJailbreakHidden];
        if (hidden != alreadyHidden) {
            if (hidden) {
                if ([self isJailbroken]) {
                    [self unregisterJailbreakApps];
                    [self setPrivatePrebootProtected:NO];
                    [self setFakelibMounted:NO];
                    jbclient_platform_set_systemwide_domain_enabled(false);
                }
                [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
            }
            else {
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:JBROOT_PATH(@"/") error:nil];
                if ([self isJailbroken]) {
                    jbclient_platform_set_systemwide_domain_enabled(true);
                    [self setFakelibMounted:YES];
                    [self setPrivatePrebootProtected:YES];
                    [self refreshJailbreakApps];
                }
            }
        }
    };
    
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:actionBlock];
        }];
    }
    else {
        actionBlock();
    }
}
*/

- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            return kernelcachePath;
        }
        return @"/System/Library/Caches/com.apple.kernelcaches/kernelcache";
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }
        
        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grab_kernelcache(kernelcachePath) == false) return nil;
        }
        return kernelcachePath;
    }
}

- (NSString *)accessibleSPTMPath
{
    NSArray<NSString *> *localNames = @[@"sptm.img4", @"sptm.im4p"];
    for (NSString *name in localNames) {
        NSString *appPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:appPath]) return appPath;

        NSString *documentsPath = [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:name]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsPath]) return documentsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *path = [[self activePrebootPath] stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,SecurePageTableMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (NSString *)accessibleTXMPath
{
    NSArray<NSString *> *localNames = @[@"txm.img4", @"txm.im4p"];
    for (NSString *name in localNames) {
        NSString *appPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:appPath]) return appPath;

        NSString *documentsPath = [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:name]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsPath]) return documentsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *path = [[self activePrebootPath] stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (BOOL)isPACBypassRequired
{
    if (![self isArm64e]) return NO;
    
    if (@available(iOS 15.2, *)) {
        return NO;
    }
    return YES;
}

- (BOOL)isPPLBypassRequired
{
    return [self isArm64e];
}

- (BOOL)isSupported
{
    NSString *systemVersion = [self systemVersion];
    if ([systemVersion compare:@"16.0" options:NSNumericSearch] == NSOrderedAscending ||
        [systemVersion compare:@"16.7.16" options:NSNumericSearch] == NSOrderedDescending) {
        return false;
    }

    //cpu_subtype_t cpuFamily = 0;
    //size_t cpuFamilySize = sizeof(cpuFamily);
    //sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    //if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)
    
    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    if ([exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL].count) {
        if (![self isPACBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC].count) {
            if (![self isPPLBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL].count) {
                return true;
            }
        }
    }
    
    return false;
}

- (BOOL)deviceSupportsFaceID
{
    if (![LAContext class]) return NO;

    LAContext *myContext = [[LAContext alloc] init];
    NSError *authError = nil;
    if (![myContext canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&authError]) {
        NSLog(@"%@", [authError localizedDescription]);
        return NO;
    }

    return myContext.biometryType == LABiometryTypeFaceID;
}

- (BOOL)deviceSupportsLandscapeBootLogo
{
    struct utsname u;
    uname(&u);
    const char *ipadString = "iPad";

    bool isPad = strncmp(u.machine, ipadString, strlen(ipadString)) == 0;
    return isPad && [self deviceSupportsFaceID];
}

- (NSError *)prepareBootstrap
{
    __block NSError *errOut;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_bootstrapper prepareBootstrapWithCompletion:^(NSError *error) {
        errOut = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return errOut;
}

- (NSError *)finalizeBootstrap
{
    return [_bootstrapper finalizeBootstrap];
}

- (NSError *)deleteBootstrap
{
    if (![self isJailbroken] && getuid() != 0) {
        int r = [self runTrollStoreAction:@"delete-bootstrap"];
        if (r != 0) {
            // TODO: maybe handle error
        }
        return nil;
    }
    else if ([self isJailbroken]) {
        __block NSError *error;
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                error = [self->_bootstrapper deleteBootstrap];
            }];
        }];
        return error;
    }
    else {
        // Let's hope for the best
        return [_bootstrapper deleteBootstrap];
    }
}

- (NSError *)reinstallPackageManagers
{
    __block NSError *error;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            error = [self->_bootstrapper installPackageManagers];
        }];
    }];
    return error;
}

- (NSError *)updateBootLogo
{
    const char *bootLogoPath = JBROOT_PATH("/basebin/bootlogo.jp2");
    if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"bootlogoEnabled" fallback:YES]) {
        UIImage *bootLogoImage;

        if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"customBootlogoEnabled" fallback:NO]) {
            bootLogoImage = [UIImage imageWithContentsOfFile:[DOUIManager sharedInstance].bootlogoPath];
        }

        if (!bootLogoImage) {
            bootLogoImage = [[DOUIManager sharedInstance] renderBootLogo];
        }

        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
                [[bootLogoImage jp2DataWithCompressionQuality:0.9] writeToFile:[NSString stringWithUTF8String:bootLogoPath] atomically:NO];
            }];
        }];

        return nil;
    }
    else {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
            }];
        }];
        return nil;
    }
}

- (NSString *)fakeMountConfigurationPath
{
    return JBROOT_PATH(@"/mnt/newFakePath.plist");
}

- (NSArray<NSString *> *)fakeMountPaths
{
    __block NSArray<NSString *> *paths = @[];
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:self.fakeMountConfigurationPath];
            if ([configuration[@"path"] isKindOfClass:[NSArray class]]) paths = configuration[@"path"];
        }];
    }];
    return paths;
}

- (BOOL)saveFakeMountPaths:(NSArray<NSString *> *)paths
{
    __block BOOL success = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *configurationPath = self.fakeMountConfigurationPath;
            [[NSFileManager defaultManager] createDirectoryAtPath:[configurationPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            success = [@{@"path" : paths ?: @[]} writeToFile:configurationPath atomically:YES];
        }];
    }];
    return success;
}

- (int)setFakeMountPath:(NSString *)path mounted:(BOOL)mounted deleteMirror:(BOOL)deleteMirror
{
    NSString *standardPath = path.stringByStandardizingPath;
    if (![path isEqualToString:standardPath] || ![path hasPrefix:@"/"] || [path isEqualToString:@"/"]) return EINVAL;

    __block int result = EPERM;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            result = exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", mounted ? "mount" : "unmount",
                              standardPath.fileSystemRepresentation, NULL);
            if (!mounted && deleteMirror && result == 0) {
                NSString *mirrorPath = [JBROOT_PATH(@"/mnt") stringByAppendingString:standardPath];
                [[NSFileManager defaultManager] removeItemAtPath:mirrorPath error:nil];
            }
        }];
    }];
    return result;
}

- (void)restoreFakeMounts
{
    for (NSString *path in self.fakeMountPaths) {
        int result = [self setFakeMountPath:path mounted:YES deleteMirror:NO];
        if (result != 0) NSLog(@"Failed restoring fake mount %@: %d", path, result);
    }
}

@end
