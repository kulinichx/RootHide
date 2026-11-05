#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#include <errno.h>

#define RC_LOW_POWER_CHANGED "com.dopaminerh.rc9.low-power-schedule.changed"
#define RC_LOW_POWER_STATUS_CHANGED "com.dopaminerh.rc9.low-power-schedule.status"
#define RC_LOW_POWER_QUERY "com.dopaminerh.rc9.low-power-schedule.query"

static inline NSString *rcLowPowerConfigurationPath(NSString *root)
{
    if (![root isKindOfClass:NSString.class] || !root.isAbsolutePath ||
        [root isEqualToString:@"/"]) return nil;
    return [root stringByAppendingPathComponent:
        @"var/mobile/Library/Preferences/com.dopaminerh.rc9.low-power-schedule.plist"];
}

static inline NSString *rcLowPowerStatusPath(NSString *root)
{
    NSString *path = rcLowPowerConfigurationPath(root);
    return path ? [path stringByAppendingString:@".status"] : nil;
}

static inline BOOL rcLowPowerMinuteValid(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value doubleValue] >= 0 && [value doubleValue] < 1440 &&
        [value doubleValue] == [value integerValue];
}

static inline BOOL rcLowPowerConfigurationValid(id configuration)
{
    if (![configuration isKindOfClass:NSDictionary.class]) return NO;
    id version = configuration[@"Version"];
    id enabled = configuration[@"Enabled"];
    id revision = configuration[@"Revision"];
    return [version isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID() &&
        [version doubleValue] == 1 &&
        [enabled isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID() &&
        [revision isKindOfClass:NSString.class] &&
        [[NSUUID alloc] initWithUUIDString:revision] != nil &&
        rcLowPowerMinuteValid(configuration[@"StartMinute"]) &&
        rcLowPowerMinuteValid(configuration[@"EndMinute"]) &&
        ![configuration[@"StartMinute"] isEqual:configuration[@"EndMinute"]];
}

static inline NSDictionary *rcLowPowerDefaultConfiguration(void)
{
    return @{@"Version": @1, @"Enabled": @NO, @"StartMinute": @0,
             @"EndMinute": @360, @"Revision": @"00000000-0000-0000-0000-000000000000"};
}

// Use calendar matching, not 24-hour arithmetic: local days can be 23 or 25 hours.
// Missing spring-forward times run at the next valid time; repeated times use
// the first occurrence. If two events collapse onto one instant, OFF wins.
static inline NSDate *rcLowPowerDateForMinute(NSInteger minute, NSDate *now,
                                              NSCalendar *calendar, BOOL next)
{
    NSDateComponents *components = [NSDateComponents new];
    components.hour = minute / 60;
    components.minute = minute % 60;
    components.second = 0;
    NSDateComponents *day = [calendar components:NSCalendarUnitEra |
        NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
    NSDate *dayStart = [calendar dateFromComponents:day];
    if (!dayStart) return nil;
    // Starting just before local midnight makes 00:00 valid and makes
    // repeated fall-back times resolve to the first occurrence of the day.
    NSDate *candidate = [calendar nextDateAfterDate:[dayStart dateByAddingTimeInterval:-0.001]
                                matchingComponents:components
                                           options:NSCalendarMatchNextTime | NSCalendarMatchFirst];
    NSComparisonResult comparison = candidate ? [candidate compare:now] : NSOrderedAscending;
    if (next ? comparison == NSOrderedDescending : comparison != NSOrderedDescending)
        return candidate;

    NSInteger dayOffset = next ? 1 : -1;
    NSDate *adjacentDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:dayOffset
                                              toDate:dayStart options:0];
    if (!adjacentDay) return nil;
    return [calendar nextDateAfterDate:[adjacentDay dateByAddingTimeInterval:-0.001]
                    matchingComponents:components
                               options:NSCalendarMatchNextTime | NSCalendarMatchFirst];
}

static inline NSDictionary *rcLowPowerEvent(NSDictionary *configuration,
                                            NSDate *now, NSCalendar *calendar,
                                            BOOL next)
{
    if (!rcLowPowerConfigurationValid(configuration) ||
        ![now isKindOfClass:NSDate.class] || !calendar) return nil;
    NSDate *dates[2] = {nil, nil};
    NSString *keys[2] = {@"StartMinute", @"EndMinute"};
    for (NSUInteger index = 0; index < 2; index++) {
        NSInteger minute = [configuration[keys[index]] integerValue];
        dates[index] = rcLowPowerDateForMinute(minute, now, calendar, next);
    }
    if (!dates[0] || !dates[1]) return nil;
    NSComparisonResult order = [dates[0] compare:dates[1]];
    BOOL on = next ? order == NSOrderedAscending : order == NSOrderedDescending;
    return @{@"Date": dates[on ? 0 : 1], @"PowerMode": @(on)};
}

static inline NSCalendar *rcLowPowerLocalCalendar(void)
{
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = NSTimeZone.localTimeZone;
    return calendar;
}

static inline NSDictionary *rcLowPowerReadDictionary(NSString *path)
{
    if (!path) return nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] ||
        [attributes[NSFileSize] unsignedLongLongValue] > 16384) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    id value = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static inline BOOL rcLowPowerWriteDictionary(NSDictionary *dictionary, NSString *path,
                                             NSError **error)
{
    if (!path) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755}
           error:error]) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSDataWritingOptions options = NSDataWritingAtomic;
#if TARGET_OS_IPHONE
    options |= NSDataWritingFileProtectionNone;
#endif
    if (![data writeToFile:path options:options error:error]) return NO;
    return [manager setAttributes:@{NSFilePosixPermissions: @0600}
                     ofItemAtPath:path error:error];
}
