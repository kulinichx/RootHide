#import "DOEnvironmentManager+RCFakeMounts.h"
#include <errno.h>
#import <libjailbreak/jbroot.h>
#import <libjailbreak/util.h>

@interface DOEnvironmentManager (RCFakeMountsPrivate)
- (NSString *)fakeMountConfigurationPath;
@end

@implementation DOEnvironmentManager (RCFakeMounts)

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
