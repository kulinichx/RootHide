//
//  DOCustomGlassThemeSync.h
//  Dopamine
//
//  RC9: keep Custom Glass theme settings identical before and after jailbreak.
//
//  Dopamine is an unsandboxed TrollStore app, so its NSUserDefaults live in
//  /var/mobile/Library/Preferences when not jailbroken, but RootHide redirects
//  preferences of jailbroken processes into jbroot. The two stores diverge,
//  which made the wallpaper (filename kept in NSUserDefaults) disappear after
//  jailbreaking. Mirror every "DOCustomGlassTheme." key into one plist on the
//  real filesystem that both states read and write. Media files themselves
//  already live in the app data container and need no change.
//

#pragma once

#import <Foundation/Foundation.h>

static NSString * const DOCustomGlassThemeSyncPrefix = @"DOCustomGlassTheme.";
static NSString * const DOCustomGlassThemeSyncDirectory =
    @"/var/mobile/Library/Application Support/DopamineRH";
static NSString * const DOCustomGlassThemeSyncFilename = @"glass-theme.plist";
// Present once the external file has become the single source of truth.
static NSString * const DOCustomGlassThemeSyncVersionKey = @"DOCustomGlassThemeSync.Version";

static inline NSString *DOCustomGlassThemeSyncPath(void)
{
    return [DOCustomGlassThemeSyncDirectory
        stringByAppendingPathComponent:DOCustomGlassThemeSyncFilename];
}

static inline NSDictionary<NSString *, id> *DOCustomGlassThemeSyncLocalSnapshot(void)
{
    NSDictionary<NSString *, id> *all =
        [NSUserDefaults.standardUserDefaults dictionaryRepresentation];
    NSMutableDictionary<NSString *, id> *snapshot = [NSMutableDictionary dictionary];
    [all enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [key hasPrefix:DOCustomGlassThemeSyncPrefix])
            snapshot[key] = value;
    }];
    return snapshot;
}

static inline BOOL DOCustomGlassThemeSyncWrite(NSDictionary<NSString *, id> *state)
{
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:DOCustomGlassThemeSyncDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSMutableDictionary *payload = [state mutableCopy];
        payload[DOCustomGlassThemeSyncVersionKey] = @1;
        BOOL ok = [payload writeToFile:DOCustomGlassThemeSyncPath() atomically:YES];
        if (!ok)
            NSLog(@"[CustomGlass][ThemeSync] write failed");
        return ok;
    } @catch (NSException *e) {
        NSLog(@"[CustomGlass][ThemeSync] write exception: %@", e);
        return NO;
    }
}

static BOOL gDOCustomGlassThemeSyncApplying = NO;
static BOOL gDOCustomGlassThemeSyncPending = NO;

static inline void DOCustomGlassThemeSyncFlush(void)
{
    gDOCustomGlassThemeSyncPending = NO;
    NSDictionary *snapshot = DOCustomGlassThemeSyncLocalSnapshot();
    NSDictionary *external = [NSDictionary dictionaryWithContentsOfFile:DOCustomGlassThemeSyncPath()];
    if ([external isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *themeOnly = [external mutableCopy];
        [themeOnly removeObjectForKey:DOCustomGlassThemeSyncVersionKey];
        if (external[DOCustomGlassThemeSyncVersionKey] && [themeOnly isEqualToDictionary:snapshot])
            return;
    }
    DOCustomGlassThemeSyncWrite(snapshot);
}

// Call once from main() before UIApplicationMain.
static inline void DOCustomGlassThemeSyncBootstrap(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            NSDictionary<NSString *, id> *local = DOCustomGlassThemeSyncLocalSnapshot();
            NSDictionary *external =
                [NSDictionary dictionaryWithContentsOfFile:DOCustomGlassThemeSyncPath()];

            BOOL authoritative = [external isKindOfClass:NSDictionary.class] &&
                                 external[DOCustomGlassThemeSyncVersionKey] != nil;
            NSMutableDictionary<NSString *, id> *merged = [NSMutableDictionary dictionary];
            if (!authoritative) {
                // One-time migration: start from this store's keys.
                [merged addEntriesFromDictionary:local];
            }
            if ([external isKindOfClass:NSDictionary.class]) {
                [external enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                    if ([key isKindOfClass:NSString.class] && [key hasPrefix:DOCustomGlassThemeSyncPrefix])
                        merged[key] = value;
                }];
            }

            gDOCustomGlassThemeSyncApplying = YES;
            [merged enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                if (![local[key] isEqual:value])
                    [defaults setObject:value forKey:key];
            }];
            if (authoritative) {
                // Keys cleared in the other state must be cleared here too.
                for (NSString *key in local) {
                    if (!merged[key])
                        [defaults removeObjectForKey:key];
                }
            }
            [defaults synchronize];
            gDOCustomGlassThemeSyncApplying = NO;

            if (!authoritative)
                DOCustomGlassThemeSyncWrite(merged);
        } @catch (NSException *e) {
            gDOCustomGlassThemeSyncApplying = NO;
            NSLog(@"[CustomGlass][ThemeSync] bootstrap exception: %@", e);
        }

        // Every later theme change (any write site) is mirrored, coalesced.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSUserDefaultsDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            if (gDOCustomGlassThemeSyncApplying || gDOCustomGlassThemeSyncPending)
                return;
            gDOCustomGlassThemeSyncPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { DOCustomGlassThemeSyncFlush(); }
                @catch (NSException *e) { gDOCustomGlassThemeSyncPending = NO; }
            });
        }];
    });
}
