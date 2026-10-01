#import <Foundation/Foundation.h>
#include <unistd.h>

#include "../libjailbreak.h"
#include "common.h"


#define APP_PATH_PREFIX "/private/var/containers/Bundle/Application/"
#define NULL_UUID "00000000-0000-0000-0000-000000000000"

NSString *getAppBundlePathFromSpawnPath(const char *path) {
    if (!path) return nil;

    char abspath[PATH_MAX];
    if (!realpath(path, abspath)) return nil;

    if (strncmp(abspath, APP_PATH_PREFIX, sizeof(APP_PATH_PREFIX) - 1) != 0)
        return nil;

    char *p1 = abspath + sizeof(APP_PATH_PREFIX) - 1;
    char *p2 = strchr(p1, '/');
    if (!p2) return nil;

    //is normal app or jailbroken app/daemon?
    if ((p2 - p1) != (sizeof(NULL_UUID) - 1))
        return nil;

    char *p = strstr(p2, ".app/");
    if (!p) return nil;

    p[sizeof(".app/") - 1] = '\0';

    return [NSString stringWithUTF8String:abspath];
}

// get main bundle identifier of app for (PlugIns's) executable path
NSString *getAppIdentifierFromPath(const char *path) {
    if (!path) return nil;

    NSString *bundlePath = getAppBundlePathFromSpawnPath(path);
    if (!bundlePath) return nil;

    NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];
    if (!appInfo) return nil;

    NSString *identifier = appInfo[@"CFBundleIdentifier"];
    if (!identifier) return nil;

    return identifier;
}

static bool isBuiltinAppIdentifier(const char* identifier)
{
    if(!identifier) return false;

    if(strcmp(identifier, "com.opa334.Dopamine-roothide") == 0) return true;

    const char* appIdentifier = jbinfo(appIdentifier);
    if(appIdentifier && *appIdentifier && strcmp(identifier, appIdentifier) == 0) return true;

    return false;
}

static bool roothide_isTweakInjectionEnabled(void)
{
    // Unified gate: 1) Dopamine safe_mode (.safe_mode file) 2) Relaxin plist key.
    // Either disabled => no tweak injection. Default YES if both absent.
    if (access(JBROOT_PATH("/basebin/.safe_mode"), F_OK) == 0) return false;
    // Gate lives in RootHideConfig.plist under key "tweakInjectionEnabled".
    // Missing key = enabled (default YES), explicit NO = disable tweak injection.
    NSString *configFilePath = JBROOT_PATH(@"/var/mobile/Library/RootHide/RootHideConfig.plist");
    NSDictionary *roothideConfig = [NSDictionary dictionaryWithContentsOfFile:configFilePath];
    if (!roothideConfig) return true;
    id val = roothideConfig[@"tweakInjectionEnabled"];
    if (!val) return true;
    if (![val isKindOfClass:[NSNumber class]]) return true;
    return [val boolValue];
}

bool isBlacklistedApp(const char* identifier)
{
    if(!identifier) return false;

    if(isBuiltinAppIdentifier(identifier)) return false;

    // Global gate: when explicitly disabled, treat all user apps as blacklisted
    // (no tweak injection), mirroring Relaxin 0.5.4 tweakInjectionEnabled.
    if(!roothide_isTweakInjectionEnabled()) return true;

    NSString* configFilePath = JBROOT_PATH(@"/var/mobile/Library/RootHide/RootHideConfig.plist");
    NSDictionary* roothideConfig = [NSDictionary dictionaryWithContentsOfFile:configFilePath];
    if(!roothideConfig) return false;

    NSDictionary* appconfig = roothideConfig[@"appconfig"];
    if(!appconfig) return false;

    NSNumber* blacklisted = appconfig[@(identifier)];
    if(!blacklisted) return false;

    return blacklisted.boolValue;
}

bool isBlacklistedPath(const char* path)
{
    if(!path) return false;
    NSString* identifier = getAppIdentifierFromPath(path);
    if(!identifier) return false;
    return isBlacklistedApp(identifier.UTF8String);
}
