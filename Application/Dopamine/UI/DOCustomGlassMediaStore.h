//
//  DOCustomGlassMediaStore.h
//  Dopamine
//
//  R14: one storage owner for Custom Glass user media.
//
//  The Dopamine process is privileged, so Foundation user-domain search paths
//  are not used to identify its App Data Container. Resolve the installed app's
//  data container explicitly by bundle identifier, then keep only media
//  filenames in NSUserDefaults.
//

#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

static NSString * const DOCustomGlassMediaStoreAvatarFilenameKey =
    @"DOCustomGlassTheme.AvatarFilename";
static NSString * const DOCustomGlassMediaStoreWallpaperFilenameKey =
    @"DOCustomGlassTheme.WallpaperFilename";

static inline id DOCustomGlassMediaStoreCallObjectGetter(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector])
        return nil;

    IMP implementation = [object methodForSelector:selector];
    if (!implementation)
        return nil;

    typedef id (*DOCustomGlassObjectGetterIMP)(id, SEL);
    return ((DOCustomGlassObjectGetterIMP)implementation)(object, selector);
}

static inline NSURL *DOCustomGlassMediaStoreLSContainerURL(NSString *bundleIdentifier)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
               RTLD_LAZY | RTLD_LOCAL);
    });

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL factorySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:factorySelector])
        return nil;

    IMP factoryImplementation = [proxyClass methodForSelector:factorySelector];
    if (!factoryImplementation)
        return nil;

    typedef id (*DOCustomGlassLSFactoryIMP)(id, SEL, NSString *);
    id proxy = ((DOCustomGlassLSFactoryIMP)factoryImplementation)(proxyClass,
                                                                  factorySelector,
                                                                  bundleIdentifier);
    id value = DOCustomGlassMediaStoreCallObjectGetter(proxy, @"dataContainerURL");
    return [value isKindOfClass:NSURL.class] ? (NSURL *)value : nil;
}

static inline NSURL *DOCustomGlassMediaStoreMCMContainerURL(NSString *bundleIdentifier)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager",
               RTLD_LAZY | RTLD_LOCAL);
    });

    Class containerClass = NSClassFromString(@"MCMAppDataContainer");
    SEL selector = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (!containerClass || ![containerClass respondsToSelector:selector])
        return nil;

    IMP implementation = [containerClass methodForSelector:selector];
    if (!implementation)
        return nil;

    BOOL existed = NO;
    NSError *error = nil;
    typedef id (*DOCustomGlassMCMFactoryIMP)(id, SEL, NSString *, BOOL, BOOL *, NSError **);
    id container = ((DOCustomGlassMCMFactoryIMP)implementation)(containerClass,
                                                                 selector,
                                                                 bundleIdentifier,
                                                                 NO,
                                                                 &existed,
                                                                 &error);
    id value = DOCustomGlassMediaStoreCallObjectGetter(container, @"url");
    NSURL *url = [value isKindOfClass:NSURL.class] ? (NSURL *)value : nil;
    if (!url && error)
        NSLog(@"[CustomGlass][MediaStore] MCM resolve failed: %@", error);
    return url;
}

static inline NSURL *DOCustomGlassMediaStoreContainerURL(void)
{
    static NSURL *resolvedURL = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (bundleIdentifier.length == 0)
            return;

        // LaunchServices describes the installed app registration and exposes
        // its real dataContainerURL without depending on process HOME.
        resolvedURL = DOCustomGlassMediaStoreLSContainerURL(bundleIdentifier);

        // MCM is a second explicit bundle-id -> data-container resolver.
        if (!resolvedURL)
            resolvedURL = DOCustomGlassMediaStoreMCMContainerURL(bundleIdentifier);

        if (resolvedURL)
            NSLog(@"[CustomGlass][MediaStore] container=%@", resolvedURL.path);
        else
            NSLog(@"[CustomGlass][MediaStore] failed to resolve App Data Container for %@",
                  bundleIdentifier);
    });
    return resolvedURL;
}

static inline NSURL *DOCustomGlassMediaStoreDirectoryURL(void)
{
    NSURL *containerURL = DOCustomGlassMediaStoreContainerURL();
    if (!containerURL)
        return nil;

    NSURL *directoryURL = [[[[containerURL
        URLByAppendingPathComponent:@"Library" isDirectory:YES]
        URLByAppendingPathComponent:@"Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"CustomGlass" isDirectory:YES]
        URLByAppendingPathComponent:@"Media" isDirectory:YES];

    NSError *error = nil;
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&error];
    if (!created) {
        NSLog(@"[CustomGlass][MediaStore] create directory failed %@: %@",
              directoryURL.path, error);
        return nil;
    }
    return directoryURL;
}

static inline BOOL DOCustomGlassMediaStoreIsSafeFilename(NSString *filename)
{
    return filename.length > 0 &&
           [filename isEqualToString:filename.lastPathComponent] &&
           ![filename isEqualToString:@"."] &&
           ![filename isEqualToString:@".."];
}

static inline NSURL *DOCustomGlassMediaStoreFileURL(NSString *filename)
{
    if (!DOCustomGlassMediaStoreIsSafeFilename(filename))
        return nil;

    NSURL *directoryURL = DOCustomGlassMediaStoreDirectoryURL();
    return directoryURL ?
        [directoryURL URLByAppendingPathComponent:filename isDirectory:NO] : nil;
}

static inline UIImage *DOCustomGlassMediaStoreLoadImageForDefaultsKey(NSString *defaultsKey)
{
    NSString *filename = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey];
    NSURL *fileURL = DOCustomGlassMediaStoreFileURL(filename);
    if (!fileURL)
        return nil;

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:fileURL
                                        options:NSDataReadingMappedIfSafe
                                          error:&readError];
    UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
    if (!image) {
        NSLog(@"[CustomGlass][MediaStore] load failed key=%@ file=%@ bytes=%lu error=%@",
              defaultsKey,
              filename,
              (unsigned long)data.length,
              readError);
    }
    return image;
}

static inline BOOL DOCustomGlassMediaStoreSaveImage(UIImage *image,
                                                     NSString *defaultsKey,
                                                     NSString *filenamePrefix,
                                                     UIImage **persistedImage)
{
    NSData *imageData = image ? UIImageJPEGRepresentation(image, 0.92) : nil;
    if (imageData.length == 0)
        return NO;

    NSString *oldFilename = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey];
    NSString *newFilename = [NSString stringWithFormat:@"%@-%@.jpg",
                             filenamePrefix,
                             NSUUID.UUID.UUIDString];
    NSURL *newURL = DOCustomGlassMediaStoreFileURL(newFilename);
    if (!newURL)
        return NO;

    NSError *writeError = nil;
    BOOL wrote = [imageData writeToURL:newURL options:NSDataWritingAtomic error:&writeError];
    if (!wrote) {
        NSLog(@"[CustomGlass][MediaStore] write failed %@: %@", newURL.path, writeError);
        return NO;
    }

    NSError *readError = nil;
    NSData *persistedData = [NSData dataWithContentsOfURL:newURL
                                                 options:NSDataReadingMappedIfSafe
                                                   error:&readError];
    UIImage *decodedImage = persistedData.length > 0 ?
        [UIImage imageWithData:persistedData] : nil;
    if (!decodedImage) {
        NSLog(@"[CustomGlass][MediaStore] verify failed %@ bytes=%lu error=%@",
              newURL.path,
              (unsigned long)persistedData.length,
              readError);
        [[NSFileManager defaultManager] removeItemAtURL:newURL error:nil];
        return NO;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:newFilename forKey:defaultsKey];
    BOOL synchronized = [defaults synchronize];

    NSString *committedFilename = [defaults stringForKey:defaultsKey];
    if (!synchronized || ![committedFilename isEqualToString:newFilename]) {
        [[NSFileManager defaultManager] removeItemAtURL:newURL error:nil];
        return NO;
    }

    // Commit new media first. Only then remove the previous file.
    if (DOCustomGlassMediaStoreIsSafeFilename(oldFilename) &&
        ![oldFilename isEqualToString:newFilename]) {
        NSURL *oldURL = DOCustomGlassMediaStoreFileURL(oldFilename);
        if (oldURL)
            [[NSFileManager defaultManager] removeItemAtURL:oldURL error:nil];
    }

    NSLog(@"[CustomGlass][MediaStore] saved key=%@ file=%@ bytes=%lu",
          defaultsKey,
          newFilename,
          (unsigned long)persistedData.length);

    if (persistedImage)
        *persistedImage = decodedImage;
    return YES;
}

static inline UIImage *DOCustomGlassMediaStoreLoadAvatar(void)
{
    return DOCustomGlassMediaStoreLoadImageForDefaultsKey(
        DOCustomGlassMediaStoreAvatarFilenameKey);
}

static inline BOOL DOCustomGlassMediaStoreSaveAvatar(UIImage *image, UIImage **persistedImage)
{
    return DOCustomGlassMediaStoreSaveImage(image,
                                             DOCustomGlassMediaStoreAvatarFilenameKey,
                                             @"avatar",
                                             persistedImage);
}

static inline UIImage *DOCustomGlassMediaStoreLoadWallpaper(void)
{
    return DOCustomGlassMediaStoreLoadImageForDefaultsKey(
        DOCustomGlassMediaStoreWallpaperFilenameKey);
}

static inline BOOL DOCustomGlassMediaStoreSaveWallpaper(UIImage *image, UIImage **persistedImage)
{
    return DOCustomGlassMediaStoreSaveImage(image,
                                             DOCustomGlassMediaStoreWallpaperFilenameKey,
                                             @"wallpaper",
                                             persistedImage);
}
