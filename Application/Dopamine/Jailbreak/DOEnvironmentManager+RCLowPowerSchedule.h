#import "DOEnvironmentManager.h"

NS_ASSUME_NONNULL_BEGIN

// RC9-only app storage bridge; scheduling remains in the SpringBoard runtime.
@interface DOEnvironmentManager (RCLowPowerSchedule)
- (NSDictionary *)lowPowerScheduleConfiguration;
- (NSDictionary *)lowPowerScheduleStatus;
- (BOOL)saveLowPowerScheduleEnabled:(BOOL)enabled startMinute:(NSInteger)startMinute
                         endMinute:(NSInteger)endMinute error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
