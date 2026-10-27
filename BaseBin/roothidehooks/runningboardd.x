#import <Foundation/Foundation.h>
#import <substrate.h>
#include <stdlib.h>
#include "common.h"

// Port of zqbb's iOS 16 RunningBoard locked-file path fix.
@interface RBProcess : NSObject
-(int)rbs_pid;
@end

static NSSet<NSString*>* fixAllowedPaths(pid_t pid, NSSet<NSString*>* paths)
{
    if (!paths || pid <= 0) return paths;
    char procpath[PATH_MAX] = {0};
    if (!proc_get_path(pid, procpath)) return paths;
    NSString* executable = rcRootfsPath(@(procpath));
    if (!executable || [executable isEqualToString:@"/rootfs"] ||
        [executable hasPrefix:@"/rootfs/"]) return paths;

    NSMutableSet* result = [NSMutableSet new];
    for (NSString* path in paths) {
        if (![path isKindOfClass:[NSString class]]) return paths;
        NSString* relative = rcRootfsPath(path);
        if (!relative) return paths;
        NSString* newPath = path;
        if ([relative isEqualToString:@"/rootfs"] || [relative hasPrefix:@"/rootfs/"]) {
            newPath = rcJbrootPath(path);
            if (!newPath) return paths;
        }
        char resolved[PATH_MAX] = {0};
        if (realpath(newPath.fileSystemRepresentation, resolved)) {
            NSString* canonical = [NSString stringWithUTF8String:resolved];
            [result addObject:canonical ? canonical.stringByStandardizingPath : path];
        } else {
            // A missing/unreadable path must not remove an existing allowance.
            [result addObject:path];
        }
    }
    return result;
}

%group ios16RunningBoard
%hookf(NSSet<NSString*>*, __RBProcess__allowedLockedFilePaths_, RBProcess* process, SEL selector)
{
    NSSet<NSString*>* result = %orig;
    if (!result || ![process respondsToSelector:@selector(rbs_pid)]) return result;
    return fixAllowedPaths([process rbs_pid], result);
}
%end

void rbdInit(void)
{
    if (@available(iOS 16.0, *)) {
        MSImageRef image = MSGetImageByName("/System/Library/PrivateFrameworks/RunningBoard.framework/RunningBoard");
        if (!image) return;
        void* target = MSFindSymbol(image, "-[RBProcess _allowedLockedFilePaths]");
        if (!target) return;
        %init(ios16RunningBoard, __RBProcess__allowedLockedFilePaths_ = target);
    }
}
