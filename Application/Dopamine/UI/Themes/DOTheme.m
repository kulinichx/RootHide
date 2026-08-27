//
//  DOTheme.m
//  Dopamine
//
//  Created by tomt000 on 14/02/2024.
//

#import "DOTheme.h"
#import "UIImage+Blur.h"
#import "DOPreferenceManager.h"

static NSString * const DOCustomGlassThemeKey = @"red";
static NSString * const DOCustomGlassCurrentWallpaperFilenameKey = @"DOCustomGlassTheme.CurrentWallpaperFilename";

static NSString *DOCustomGlassThemeBackgroundDirectoryPath(void)
{
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (applicationSupport.length == 0)
        return nil;

    return [applicationSupport stringByAppendingPathComponent:@"CustomGlass"];
}

static BOOL DOCustomGlassWallpaperFilenameIsSafe(NSString *filename)
{
    return filename.length > 0 &&
           [filename isEqualToString:filename.lastPathComponent] &&
           [filename hasPrefix:@"wallpaper-"] &&
           [filename.pathExtension.lowercaseString isEqualToString:@"jpg"];
}

static NSString *DOCustomGlassExistingWallpaperPath(NSString *directory, NSString *filename)
{
    if (!DOCustomGlassWallpaperFilenameIsSafe(filename))
        return nil;

    NSString *path = [directory stringByAppendingPathComponent:filename];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

static NSString *DOCustomGlassNewestVersionedWallpaperFilename(NSString *directory)
{
    NSArray<NSString *> *entries = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:directory
                            error:nil];
    NSString *newestFilename = nil;
    NSDate *newestDate = nil;

    for (NSString *entry in entries) {
        if (!DOCustomGlassWallpaperFilenameIsSafe(entry))
            continue;

        NSString *path = [directory stringByAppendingPathComponent:entry];
        NSDictionary *attributes = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path
                             error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!newestFilename || (modified && (!newestDate || [modified compare:newestDate] == NSOrderedDescending))) {
            newestFilename = entry;
            newestDate = modified;
        }
    }

    return newestFilename;
}

static NSString *DOCustomGlassThemeResolvedBackgroundPath(NSString **identifierOut)
{
    NSString *directory = DOCustomGlassThemeBackgroundDirectoryPath();
    if (directory.length == 0) {
        if (identifierOut)
            *identifierOut = @"compiled-fallback";
        return nil;
    }

    DOPreferenceManager *preferenceManager = [DOPreferenceManager sharedManager];
    id storedValue = [preferenceManager preferenceValueForKey:DOCustomGlassCurrentWallpaperFilenameKey];
    NSString *filename = [storedValue isKindOfClass:NSString.class] ? (NSString *)storedValue : nil;
    NSString *path = DOCustomGlassExistingWallpaperPath(directory, filename);

    if (path.length > 0) {
        if (identifierOut)
            *identifierOut = [@"current:" stringByAppendingString:filename];
        return path;
    }

    // One-time R13.2 migration: if the old NSUserDefaults pointer still exists,
    // promote it into Dopamine's explicit preference plist.
    NSString *defaultsFilename = [[NSUserDefaults standardUserDefaults]
        stringForKey:DOCustomGlassCurrentWallpaperFilenameKey];
    path = DOCustomGlassExistingWallpaperPath(directory, defaultsFilename);
    if (path.length > 0) {
        [preferenceManager setPreferenceValue:defaultsFilename
                                       forKey:DOCustomGlassCurrentWallpaperFilenameKey];
        if (identifierOut)
            *identifierOut = [@"migrated:" stringByAppendingString:defaultsFilename];
        return path;
    }

    // If the pointer was lost but R13.2 already wrote a versioned JPEG, recover
    // the newest on-disk wallpaper and persist that filename for future launches.
    NSString *recoveredFilename = DOCustomGlassNewestVersionedWallpaperFilename(directory);
    path = DOCustomGlassExistingWallpaperPath(directory, recoveredFilename);
    if (path.length > 0) {
        [preferenceManager setPreferenceValue:recoveredFilename
                                       forKey:DOCustomGlassCurrentWallpaperFilenameKey];
        if (identifierOut)
            *identifierOut = [@"recovered:" stringByAppendingString:recoveredFilename];
        return path;
    }

    // R13/R13.1 compatibility: preserve the last fixed-name wallpaper until
    // the user chooses a wallpaper once under the versioned scheme.
    NSString *legacyPath = [directory stringByAppendingPathComponent:@"background.jpg"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacyPath]) {
        if (identifierOut)
            *identifierOut = @"legacy:background.jpg";
        return legacyPath;
    }

    if (identifierOut)
        *identifierOut = @"compiled-fallback";
    return nil;
}

@interface DOTheme ()
@property (nonatomic, retain) NSString *imageName;
@property (nonatomic, retain) NSString *customGlassWallpaperIdentifier;
@end

@implementation DOTheme

- (id)initWithDictionary: (NSDictionary *)dictionary
{
    self = [super init];
    if (self) {
        self.name = [dictionary objectForKey:@"name"];
        self.icon = [dictionary objectForKey:@"icon"];
        self.key = [dictionary objectForKey:@"key"];
        if ([self.key isEqualToString:DOCustomGlassThemeKey])
            self.icon = nil; // Keep Dopamine's primary/default blue app icon.
        self.imageName = [dictionary objectForKey:@"image"];
        self.windowColor = [self colorFromHexString:[dictionary objectForKey:@"windowColor"]];
        self.actionMenuColor = [self colorFromHexString:[dictionary objectForKey:@"actionMenuColor"]];
        self.blur = [[dictionary objectForKey:@"blur"] floatValue];
        self.titleShadow = [[dictionary objectForKey:@"titleShadow"] boolValue];
    }
    return self;
}

- (UIColor*)colorFromHexString:(NSString*)hexString
{
    unsigned int hexInt = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    [scanner scanHexInt:&hexInt];
    return [UIColor colorWithRed:((CGFloat)((hexInt & 0xFF0000) >> 16))/255.0 green:((CGFloat)((hexInt & 0xFF00) >> 8))/255.0 blue:((CGFloat)(hexInt & 0xFF))/255.0 alpha:((CGFloat)((hexInt & 0xFF000000) >> 24))/255.0];
}

- (UIImage *)image
{
    if ([self.key isEqualToString:DOCustomGlassThemeKey]) {
        NSString *wallpaperIdentifier = nil;
        NSString *customPath = DOCustomGlassThemeResolvedBackgroundPath(&wallpaperIdentifier);

        // The wallpaper filename is immutable. If the persisted pointer changes,
        // discard the in-memory image immediately; otherwise keep the normal
        // theme cache without ever reusing bytes from a replaced pathname.
        if (![self.customGlassWallpaperIdentifier isEqualToString:wallpaperIdentifier]) {
            _image = nil;
            self.customGlassWallpaperIdentifier = wallpaperIdentifier;
        }

        if (_image == nil) {
            UIImage *sourceImage = nil;
            NSData *customData = customPath.length > 0 ?
                [NSData dataWithContentsOfFile:customPath] : nil;
            if (customData.length > 0)
                sourceImage = [UIImage imageWithData:customData];

            if (!sourceImage)
                sourceImage = [UIImage imageNamed:self.imageName];

            _image = [sourceImage imageWithBlur:self.blur];
        }
        return _image;
    }

    if (_image == nil)
        _image = [[UIImage imageNamed:self.imageName] imageWithBlur:self.blur];
    return _image;
}

- (void)invalidateImage
{
    _image = nil;
    self.customGlassWallpaperIdentifier = nil;
}

- (UIImage *)generateBootLogo
{
    UIImage *backgroundImage = [self image];
    CGSize canvasSize = backgroundImage.size;

    UIImage *overlayImage = [UIImage imageNamed:@"DopamineLogo"];

    CGSize overlaySize = CGSizeMake(350, 350);
    CGPoint overlayOrigin = CGPointMake((canvasSize.width - overlaySize.width) / 2.0,
                                        (canvasSize.height - overlaySize.height) / 2.0);

    UIGraphicsBeginImageContextWithOptions(canvasSize, NO, backgroundImage.scale);

    [backgroundImage drawInRect:CGRectMake(0, 0, canvasSize.width, canvasSize.height)];

    // Render overlay (Dopamine Logo) in center of background for boot logo
    [overlayImage drawInRect:CGRectMake(overlayOrigin.x, overlayOrigin.y, overlaySize.width, overlaySize.height)];

    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return finalImage;
}

@end
