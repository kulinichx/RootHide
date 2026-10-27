#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#include "common.h"

#ifndef DEBUG
#define NSLog(args...)	
#endif

NSString* safe_getExecutablePath()
{
	char executablePathC[PATH_MAX] = {0};
	uint32_t executablePathCSize = sizeof(executablePathC);
	if (_NSGetExecutablePath(&executablePathC[0], &executablePathCSize) != 0) return nil;
	return [NSString stringWithUTF8String:executablePathC];
}

NSString* getProcessName()
{
	return safe_getExecutablePath().lastPathComponent;
}

%ctor
{
	NSLog(@"roothidehooks coming... %@", safe_getExecutablePath());
	NSString *processName = getProcessName();
	/*if ([processName isEqualToString:@"installd"]) {
		extern void installdInit(void);
		installdInit();
	}
	else*/ if ([processName isEqualToString:@"cfprefsd"]) {
		extern void cfprefsdInit(void);
		cfprefsdInit();
	}
	else if ([processName isEqualToString:@"lsd"]) {
		extern void lsdInit(void);
		lsdInit();
	}
	else if ([processName isEqualToString:@"runningboardd"]) {
		extern void rbdInit(void);
		rbdInit();
	}
	else if ([processName isEqualToString:@"SpringBoard"]) {
		extern void sbInit(void);
		sbInit();
	}
}
