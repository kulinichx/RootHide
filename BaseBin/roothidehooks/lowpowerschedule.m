#import "RCLowPowerSchedule.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <notify.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#ifndef RC_LOW_POWER_TEST
#include <libjailbreak/jbclient_xpc.h>
#else
extern const char *jbclient_get_jbroot(void);
extern NSDate *rcLowPowerTestNow(void);
extern NSString *rcLowPowerTestBootSession(void);
#endif

@protocol RCLowPowerModeAPI <NSObject>
+ (instancetype)sharedInstance;
- (BOOL)setPowerMode:(long long)mode fromSource:(NSString *)source;
@end

@protocol RCPersistentTimerAPI <NSObject>
- (instancetype)initWithFireDate:(NSDate *)date serviceIdentifier:(NSString *)identifier
                         target:(id)target selector:(SEL)selector userInfo:(id)userInfo;
- (void)setDisableSystemWaking:(BOOL)value;
- (void)setUserVisible:(BOOL)value;
- (void)setMinimumEarlyFireProportion:(double)value;
- (void)setEarlyFireConstantInterval:(double)value;
- (void)scheduleInRunLoop:(NSRunLoop *)runLoop;
- (void)invalidate;
- (BOOL)isValid;
@end

static BOOL rcLowPowerMethodMatches(Method method, const char *returns, const char *arguments)
{
    if (!method || !method_getTypeEncoding(method)) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != strlen(arguments) + 2 ||
        !strchr(returns, signature.methodReturnType[0])) return NO;
    for (NSUInteger index = 0; index < strlen(arguments); index++) {
        char type = [signature getArgumentTypeAtIndex:index + 2][0];
        if (arguments[index] == 'b' ? !strchr("Bc", type) : type != arguments[index]) return NO;
    }
    return YES;
}

static BOOL rcLowPowerAPIsAvailable(void)
{
    Class power = NSClassFromString(@"_PMLowPowerMode");
    Class timer = NSClassFromString(@"PCPersistentTimer");
    return power && timer &&
        rcLowPowerMethodMatches(class_getClassMethod(power, @selector(sharedInstance)), "@", "") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(power, @selector(setPowerMode:fromSource:)), "Bc", "q@") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer,
            @selector(initWithFireDate:serviceIdentifier:target:selector:userInfo:)), "@", "@@@:@") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(setDisableSystemWaking:)), "v", "b") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(setUserVisible:)), "v", "b") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(setMinimumEarlyFireProportion:)), "v", "d") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(setEarlyFireConstantInterval:)), "v", "d") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(scheduleInRunLoop:)), "v", "@") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(invalidate)), "v", "") &&
        rcLowPowerMethodMatches(class_getInstanceMethod(timer, @selector(isValid)), "Bc", "");
}

static NSString *rcLowPowerRoot(void)
{
    const char *root = jbclient_get_jbroot();
    return root && root[0] == '/' ? [NSString stringWithUTF8String:root] : nil;
}

static NSDate *rcLowPowerNow(void)
{
#ifdef RC_LOW_POWER_TEST
    return rcLowPowerTestNow();
#else
    return NSDate.date;
#endif
}

static NSString *rcLowPowerBootSession(void)
{
#ifdef RC_LOW_POWER_TEST
    return rcLowPowerTestBootSession();
#else
    static NSString *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct timeval bootTime = {0};
        size_t length = sizeof(bootTime);
        if (sysctlbyname("kern.boottime", &bootTime, &length, NULL, 0) == 0 &&
            length == sizeof(bootTime) && bootTime.tv_sec > 0)
            session = [NSString stringWithFormat:@"%lld.%d",
                (long long)bootTime.tv_sec, (int)bootTime.tv_usec];
    });
    return session;
#endif
}

@interface RCLowPowerScheduler : NSObject
@property(nonatomic, strong) id<RCPersistentTimerAPI> timer;
@property(nonatomic, copy) NSDictionary *lastHandled;
@property(nonatomic, copy) NSString *retryKey;
@property(nonatomic) NSUInteger retryCount;
@property(nonatomic, strong) NSDate *retryAfter;
- (void)refresh;
- (void)timerFired:(id)timer;
@end

@implementation RCLowPowerScheduler

- (void)publishStatus:(NSString *)state configuration:(NSDictionary *)configuration
                root:(NSString *)root next:(NSDictionary *)next
{
    NSMutableDictionary *status = [@{@"State": state, @"Updated": rcLowPowerNow()} mutableCopy];
    if (configuration[@"Revision"]) status[@"Revision"] = configuration[@"Revision"];
    if (next) status[@"Next"] = next;
    if (self.lastHandled) status[@"LastHandled"] = self.lastHandled;
    NSString *bootSession = rcLowPowerBootSession();
    if (bootSession) status[@"BootSession"] = bootSession;
    if (rcLowPowerWriteDictionary(status, rcLowPowerStatusPath(root), nil))
        notify_post(RC_LOW_POWER_STATUS_CHANGED);
}

- (BOOL)armForDate:(NSDate *)date
{
    id<RCPersistentTimerAPI> timer = [(id<RCPersistentTimerAPI>)[NSClassFromString(@"PCPersistentTimer") alloc]
        initWithFireDate:date serviceIdentifier:@"com.dopaminerh.rc9.low-power-schedule"
        target:self selector:@selector(timerFired:) userInfo:nil];
    if (!timer) return NO;
    [timer setDisableSystemWaking:NO];
    [timer setUserVisible:YES];
    [timer setMinimumEarlyFireProportion:0.0];
    [timer setEarlyFireConstantInterval:0.0];
    [timer scheduleInRunLoop:NSRunLoop.mainRunLoop];
    if ([timer isValid]) {
        [self.timer invalidate];
        self.timer = timer;
        return YES;
    }
    [timer invalidate];
    return NO;
}

- (void)timerFired:(id)timer
{
    if (timer == self.timer) [self refresh];
}

- (void)refresh
{
    // All entry points run on SpringBoard's main queue; disabling cannot race an
    // already queued callback into applying a stale configuration.
    [self.timer invalidate];
    self.timer = nil;
    NSString *root = rcLowPowerRoot();
    if (!root) return;
    NSDictionary *configuration = rcLowPowerReadDictionary(rcLowPowerConfigurationPath(root));
    if (!configuration) {
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:rcLowPowerConfigurationPath(root)];
        [self publishStatus:exists ? @"invalidConfiguration" : @"disabled"
              configuration:nil root:root next:nil];
        return;
    }
    if (!rcLowPowerConfigurationValid(configuration)) {
        [self publishStatus:@"invalidConfiguration" configuration:nil root:root next:nil];
        return;
    }
    if (![configuration[@"Enabled"] boolValue]) {
        self.retryKey = nil;
        self.retryCount = 0;
        self.retryAfter = nil;
        [self publishStatus:@"disabled" configuration:configuration root:root next:nil];
        return;
    }
    @try {
        static dispatch_once_t frameworksOnce;
        dispatch_once(&frameworksOnce, ^{
            // Disabled plans never load either optional system framework.
            // Keep handles alive while cached Objective-C classes are in use.
            dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode", RTLD_LAZY | RTLD_LOCAL);
            dlopen("/System/Library/PrivateFrameworks/PersistentConnection.framework/PersistentConnection", RTLD_LAZY | RTLD_LOCAL);
        });
        if (!rcLowPowerAPIsAvailable()) {
            [self publishStatus:@"unsupported" configuration:configuration root:root next:nil];
            return;
        }
        NSDate *now = rcLowPowerNow();
        NSCalendar *calendar = rcLowPowerLocalCalendar();
        NSDictionary *previous = rcLowPowerEvent(configuration, now, calendar, NO);
        NSDictionary *next = rcLowPowerEvent(configuration, now, calendar, YES);
        if (!previous || !next) {
            [self publishStatus:@"calendarFailed" configuration:configuration root:root next:nil];
            return;
        }
        NSDictionary *event = @{@"Revision": configuration[@"Revision"],
            @"Date": previous[@"Date"], @"PowerMode": previous[@"PowerMode"]};
        // Do not enable a mode if its corresponding OFF event cannot be armed.
        if (![self armForDate:next[@"Date"]]) {
            [self publishStatus:@"timerFailed" configuration:configuration root:root next:next];
            return;
        }
        if (!self.lastHandled) {
            NSDictionary *saved = rcLowPowerReadDictionary(rcLowPowerStatusPath(root));
            // Preserve manual overrides across a respring, but catch up after
            // a full reboot that may have reset the system's power-mode state.
            NSString *bootSession = rcLowPowerBootSession();
            if (bootSession && [saved[@"BootSession"] isEqual:bootSession] &&
                [saved[@"LastHandled"] isKindOfClass:NSDictionary.class])
                self.lastHandled = saved[@"LastHandled"];
        }
        BOOL applied = YES;
        if (![self.lastHandled isEqual:event]) {
            NSString *key = [NSString stringWithFormat:@"%@:%@", event[@"Revision"], event[@"Date"]];
            if (![self.retryKey isEqual:key]) {
                self.retryKey = key;
                self.retryCount = 0;
                self.retryAfter = nil;
            }
            // Idempotent set, never toggle. Manual changes survive until the
            // next event, including a respring within the same daily interval.
            applied = NO;
            if (self.retryCount < 4 && (!self.retryAfter ||
                [now compare:self.retryAfter] != NSOrderedAscending)) {
                self.retryCount++;
                id<RCLowPowerModeAPI> power = [(Class<RCLowPowerModeAPI>)NSClassFromString(@"_PMLowPowerMode") sharedInstance];
                applied = [power setPowerMode:[previous[@"PowerMode"] longLongValue]
                                  fromSource:@"com.dopaminerh.rc9.low-power-schedule"];
                if (applied) self.lastHandled = event;
                else self.retryAfter = [now dateByAddingTimeInterval:60.0 * self.retryCount];
            }
        }
        if (!applied) {
            // At most three retries per event, not a background polling loop.
            if (self.retryCount < 4 && [self.retryAfter compare:next[@"Date"]] == NSOrderedAscending)
                [self armForDate:self.retryAfter];
        } else {
            self.retryKey = nil;
            self.retryCount = 0;
            self.retryAfter = nil;
        }
        [self publishStatus:applied ? @"scheduled" : @"applyFailed"
              configuration:configuration root:root next:next];
    }
    @catch (__unused NSException *exception) {
        [self.timer invalidate];
        self.timer = nil;
        [self publishStatus:@"runtimeFailed" configuration:configuration root:root next:nil];
    }
}
@end

void rcLowPowerScheduleStart(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static RCLowPowerScheduler *scheduler;
        scheduler = [RCLowPowerScheduler new];
        int changeToken, queryToken;
        notify_register_dispatch(RC_LOW_POWER_CHANGED, &changeToken, dispatch_get_main_queue(),
            ^(__unused int token) { [scheduler refresh]; });
        notify_register_dispatch(RC_LOW_POWER_QUERY, &queryToken, dispatch_get_main_queue(),
            ^(__unused int token) { [scheduler refresh]; });
        for (NSString *name in @[NSSystemClockDidChangeNotification, NSSystemTimeZoneDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                    [scheduler refresh];
                }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [scheduler refresh]; });
    });
}
