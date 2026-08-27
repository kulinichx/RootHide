//
//  DOTheme.m
//  Dopamine
//
//  Created by tomt000 on 14/02/2024.
//

#import "DOTheme.h"
#import "UIImage+Blur.h"

static NSString * const DOCustomGlassThemeKey = @"red";

static NSString *DOCustomGlassDocumentsBackgroundDirectoryPath(void)
{
    NSString *home = NSHomeDirectory();
    if (home.length == 0)
        return nil;

    return [home stringByAppendingPathComponent:@"Documents/CustomGlass"];
}

static NSString *DOCustomGlassLegacyBackgroundDirectoryPath(void)
{
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (applicationSupport.length == 0)
        return nil;

    return [applicationSupport stringByAppendingPathComponent:@"CustomGlass"];
}

static BOOL DOCustomGlassVersionedWallpaperFilename(NSString *filename)
{
    return filename.length > 0 &&
           [filename isEqualToString:filename.lastPathComponent] &&
           [filename hasPrefix:@"wallpaper-"] &&
           [filename.pathExtension.lowercaseString isEqualToString:@"jpg"];
}

static NSString *DOCustomGlassNewestLegacyWallpaperPath(NSString *directory)
{
    if (directory.length == 0)
        return nil;

    NSArray<NSString *> *entries = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:directory
                            error:nil];
    NSString *newestPath = nil;
    NSDate *newestDate = nil;

    for (NSString *entry in entries) {
        if (!DOCustomGlassVersionedWallpaperFilename(entry))
            continue;

        NSString *path = [directory stringByAppendingPathComponent:entry];
        NSDictionary *attributes = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path
                             error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!newestPath || (modified && (!newestDate || [modified compare:newestDate] == NSOrderedDescending))) {
            newestPath = path;
            newestDate = modified;
        }
    }

    if (newestPath.length > 0)
        return newestPath;

    NSString *legacyFixedPath = [directory stringByAppendingPathComponent:@"background.jpg"];
    return [[NSFileManager defaultManager] fileExistsAtPath:legacyFixedPath] ? legacyFixedPath : nil;
}

static NSString *DOCustomGlassWallpaperIdentifierForPath(NSString *path)
{
    if (path.length == 0)
        return @"compiled-fallback";

    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path
                         error:nil];
    NSNumber *size = attributes[NSFileSize] ?: @0;
    NSDate *modified = attributes[NSFileModificationDate];
    NSTimeInterval timestamp = modified ? modified.timeIntervalSince1970 : 0.0;
    return [NSString stringWithFormat:@"documents:background.jpg:%@:%0.6f", size, timestamp];
}

static NSString *DOCustomGlassThemeResolvedBackgroundPath(NSString **identifierOut)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *documentsDirectory = DOCustomGlassDocumentsBackgroundDirectoryPath();
    if (documentsDirectory.length == 0) {
        if (identifierOut)
            *identifierOut = @"compiled-fallback";
        return nil;
    }

    [fileManager createDirectoryAtPath:documentsDirectory
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];

    NSString *fixedPath = [documentsDirectory stringByAppendingPathComponent:@"background.jpg"];

    // R13.4 has one authoritative wallpaper pathname and no wallpaper pointer
    // preference. This mirrors Dopamine's existing Documents/bootlogo.png model.
    if (![fileManager fileExistsAtPath:fixedPath]) {
        NSString *legacyDirectory = DOCustomGlassLegacyBackgroundDirectoryPath();
        NSString *migrationSource = DOCustomGlassNewestLegacyWallpaperPath(legacyDirectory);
        if (migrationSource.length > 0)
            [fileManager copyItemAtPath:migrationSource toPath:fixedPath error:nil];
    }

    if (![fileManager fileExistsAtPath:fixedPath]) {
        if (identifierOut)
            *identifierOut = @"compiled-fallback";
        return nil;
    }

    if (identifierOut)
        *identifierOut = DOCustomGlassWallpaperIdentifierForPath(fixedPath);
    return fixedPath;
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
