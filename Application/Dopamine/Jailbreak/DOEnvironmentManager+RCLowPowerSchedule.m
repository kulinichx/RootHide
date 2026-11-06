#import "DOEnvironmentManager+RCLowPowerSchedule.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <notify.h>
#import <libjailbreak/jbroot.h>
#import "../../../BaseBin/roothidehooks/RCLowPowerSchedule.h"

@implementation DOEnvironmentManager (RCLowPowerSchedule)

- (NSDictionary *)lowPowerScheduleConfiguration
{
    __block NSDictionary *configuration;
    [self runUnsandboxed:^{
        configuration = rcLowPowerReadDictionary(rcLowPowerConfigurationPath(JBROOT_PATH(@"/")));
    }];
    return configuration ?: rcLowPowerDefaultConfiguration();
}

- (NSDictionary *)lowPowerScheduleStatus
{
    __block NSDictionary *status;
    [self runUnsandboxed:^{
        status = rcLowPowerReadDictionary(rcLowPowerStatusPath(JBROOT_PATH(@"/")));
    }];
    return status ?: @{};
}

- (BOOL)saveLowPowerScheduleEnabled:(BOOL)enabled startMinute:(NSInteger)startMinute
                         endMinute:(NSInteger)endMinute error:(NSError **)error
{
    NSDictionary *configuration = @{@"Version": @1, @"Enabled": @(enabled),
        @"StartMinute": @(startMinute), @"EndMinute": @(endMinute),
        @"Revision": NSUUID.UUID.UUIDString};
    if (!self.isJailbroken || !rcLowPowerConfigurationValid(configuration)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:self.isJailbroken ? EINVAL : EPERM userInfo:nil];
        return NO;
    }
    __block BOOL success = NO;
    __block NSError *writeError = nil;
    [self runUnsandboxed:^{
        success = rcLowPowerWriteDictionary(configuration,
            rcLowPowerConfigurationPath(JBROOT_PATH(@"/")), &writeError);
    }];
    if (success) notify_post(RC_LOW_POWER_CHANGED);
    else if (error) *error = writeError;
    return success;
}

@end
