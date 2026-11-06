#import "DOEnvironmentManager.h"

NS_ASSUME_NONNULL_BEGIN

// RC9 path-mount preferences; upstream fakelib lifecycle remains in BaseBin.
@interface DOEnvironmentManager (RCFakeMounts)
- (NSArray<NSString *> *)fakeMountPaths;
- (BOOL)saveFakeMountPaths:(NSArray<NSString *> *)paths;
- (int)setFakeMountPath:(NSString *)path mounted:(BOOL)mounted deleteMirror:(BOOL)deleteMirror;
- (void)restoreFakeMounts;
@end

NS_ASSUME_NONNULL_END
