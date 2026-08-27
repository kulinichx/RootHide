//
//  DONavigationController.m
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import "DONavigationController.h"
#import <objc/runtime.h>
#import "DOModalBackAction.h"
#import "DOGlobalAppearance.h"
#import "DOThemeManager.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <math.h>

static NSString * const DOCustomGlassNavigationBackgroundBlurKey = @"DOCustomGlassTheme.BackgroundBlur";

static inline CGFloat DOCustomGlassNavigationClamp01(CGFloat value)
{
    return MIN(1.0, MAX(0.0, value));
}

static CGFloat DOCustomGlassNavigationPerceivedLuminance(CGFloat red, CGFloat green, CGFloat blue)
{
    return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue);
}

static NSString * const DOCustomGlassNavigationThemeKey = @"red";

static NSString *DOCustomGlassNavigationUserWallpaperPath(void)
{
    NSString *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0)
        return nil;

    return [[documents stringByAppendingPathComponent:@"CustomGlass"]
        stringByAppendingPathComponent:@"background.jpg"];
}

static UIImage *DOCustomGlassNavigationLoadUserWallpaper(void)
{
    NSString *path = DOCustomGlassNavigationUserWallpaperPath();
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path])
        return nil;

    // imageWithContentsOfFile intentionally bypasses UIImage's named-image
    // cache. User media is mutable data and must be decoded from its actual
    // persisted path on every process launch.
    return [UIImage imageWithContentsOfFile:path];
}

static UIImage *DOCustomGlassNavigationResolveBackground(DOTheme *theme, BOOL *usingUserWallpaper)
{
    BOOL isCustomGlass = [theme.key isEqualToString:DOCustomGlassNavigationThemeKey];
    UIImage *userWallpaper = isCustomGlass ? DOCustomGlassNavigationLoadUserWallpaper() : nil;

    if (usingUserWallpaper)
        *usingUserWallpaper = (userWallpaper != nil);

    // User media always has priority. DOTheme is consulted only for immutable
    // bundle artwork (including Background_Red as Custom Glass fallback).
    return userWallpaper ?: [theme image];
}

// Wallpaper blur is image processing, not a live backdrop. Keeping it off the
// CABackdropLayer/CAFilter path removes the window-attachment race that was
// unique to iPhone cold launches while preserving the same persisted control.
static UIImage *DOCustomGlassNavigationCreateBlurredImage(UIImage *image, CGFloat blurIntensity)
{
    if (!image || !image.CGImage)
        return image;

    CGFloat clamped = DOCustomGlassNavigationClamp01(blurIntensity);
    if (clamped <= 0.001)
        return image;

    CIImage *input = [CIImage imageWithCGImage:image.CGImage];
    if (!input)
        return image;

    // Bound the working image size. Full-resolution photo assets can be tens of
    // megapixels; blurring those during relaunch is unnecessary for a screen
    // background and can create a large transient memory spike on iPhone.
    CGFloat longestEdge = MAX(CGRectGetWidth(input.extent), CGRectGetHeight(input.extent));
    if (longestEdge > 2048.0) {
        CGFloat imageScale = 2048.0 / longestEdge;
        CIFilter *scaleFilter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
        [scaleFilter setValue:input forKey:kCIInputImageKey];
        [scaleFilter setValue:@(imageScale) forKey:kCIInputScaleKey];
        [scaleFilter setValue:@1.0 forKey:kCIInputAspectRatioKey];
        if (scaleFilter.outputImage)
            input = scaleFilter.outputImage;
    }

    CGFloat radius = 24.0 * pow(clamped, 1.08);
    CIImage *clampedInput = [input imageByClampingToExtent];
    CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!filter)
        return image;

    [filter setValue:clampedInput forKey:kCIInputImageKey];
    [filter setValue:@(radius) forKey:kCIInputRadiusKey];

    CIImage *output = filter.outputImage;
    if (!output)
        return image;
    output = [output imageByCroppingToRect:input.extent];

    static CIContext *context;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [CIContext contextWithOptions:nil];
    });

    CGImageRef outputCGImage = [context createCGImage:output fromRect:input.extent];
    if (!outputCGImage)
        return image;

    UIImage *result = [UIImage imageWithCGImage:outputCGImage
                                         scale:image.scale
                                   orientation:image.imageOrientation];
    CGImageRelease(outputCGImage);
    return result ?: image;
}

@interface DONavigationController ()

@property (nonatomic) UIImageView *backgroundImageView;
@property (nonatomic, strong) UIImage *customGlassBackgroundSourceImage;
@property (nonatomic, assign) BOOL customGlassUsingCustomBackground;
@property (nonatomic, assign) NSUInteger customGlassBackgroundBlurGeneration;
@property (nonatomic) DOMainViewController *mainView;
@property (nonatomic) DOModalBackAction *backAction;

@end

@interface UINavigationController (Private)
-(CGRect)_frameForViewController:(id)arg1;
@end

@implementation DONavigationController

- (BOOL)isCustomGlassFullScreenViewController:(UIViewController *)viewController
{
    return [NSStringFromClass(viewController.class) hasPrefix:@"DOCustomGlass"];
}

- (void)viewDidLoad
{
    // UIKit must finish UINavigationController's own view construction before
    // we install the shared wallpaper hierarchy. Calling self.view from
    // setupBackground before [super viewDidLoad] can recursively touch the
    // navigation view during cold launch and was the main R8 stability risk.
    [super viewDidLoad];
    [self setupBackground];
    [self setNavigationBarHidden:YES];

    // setupBackground already resolved the user-media path (or immutable
    // theme fallback) before the first image view was created. Apply only the
    // persisted Custom Glass wallpaper blur here.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat initialBlur = [defaults objectForKey:DOCustomGlassNavigationBackgroundBlurKey] ?
        [defaults floatForKey:DOCustomGlassNavigationBackgroundBlurKey] : 0.10;
    [self customGlassApplySharedBackgroundBlurIntensity:initialBlur];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];

    [self pushViewController:(self.mainView = [[DOMainViewController alloc] init]) animated:NO];
    [self setDelegate:self];
    [self setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
}

- (void)setupBackground
{
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    BOOL usingUserWallpaper = NO;

    // Resolve dynamic user media before asking DOTheme for its immutable
    // bundle-backed fallback. This keeps Custom Glass wallpaper ownership out of
    // the theme cache and makes the first real app frame use the persisted file.
    UIImage *sourceImage = DOCustomGlassNavigationResolveBackground(theme, &usingUserWallpaper);

    self.customGlassUsingCustomBackground = usingUserWallpaper;
    self.customGlassBackgroundSourceImage = sourceImage;
    self.customGlassBackgroundBlurGeneration = 0;

    self.view.backgroundColor = [UIColor blackColor];
    self.backgroundImageView = [[UIImageView alloc] init];
    self.backgroundImageView.image = sourceImage;
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundImageView.userInteractionEnabled = NO;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.layer.zPosition = -1;

    [self.view insertSubview:self.backgroundImageView atIndex:0];

    // Keep the one shared image overscanned so modal scale/push transitions
    // cannot expose a second wallpaper around the destination frame.
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:-48.0],
        [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:48.0],
        [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:-140.0],
        [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:140.0],
    ]];

    self.backAction = [[DOModalBackAction alloc] initWithAction:^{
        [self popViewControllerAnimated:YES];
    }];
    self.backAction.translatesAutoresizingMaskIntoConstraints = NO;
    self.backAction.hidden = YES;

    [self.view insertSubview:self.backAction atIndex:1];

    [NSLayoutConstraint activateConstraints:@[
        [self.backAction.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backAction.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backAction.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backAction.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)customGlassApplySharedBackgroundBlurIntensity:(CGFloat)blurIntensity
{
    CGFloat clamped = DOCustomGlassNavigationClamp01(blurIntensity);
    UIImage *sourceImage = self.customGlassBackgroundSourceImage;
    NSUInteger generation = ++self.customGlassBackgroundBlurGeneration;

    if (!sourceImage || clamped <= 0.001) {
        [UIView performWithoutAnimation:^{
            self.backgroundImageView.image = sourceImage;
        }];
        return;
    }

    // Core Image is intentionally off the main thread. Old requests are ignored
    // with a generation token, so dragging the slider cannot race a wallpaper
    // replacement or put an older blur result back on screen.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *blurredImage = DOCustomGlassNavigationCreateBlurredImage(sourceImage, clamped);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.customGlassBackgroundBlurGeneration ||
                sourceImage != self.customGlassBackgroundSourceImage)
                return;

            [UIView performWithoutAnimation:^{
                self.backgroundImageView.image = blurredImage ?: sourceImage;
            }];
        });
    });
}

- (void)customGlassRefreshSharedBackground
{
    // A refresh re-resolves the user-media path directly. DOTheme remains only
    // the immutable fallback provider and never caches the selected photo.
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    BOOL usingUserWallpaper = NO;
    UIImage *sourceImage = DOCustomGlassNavigationResolveBackground(theme, &usingUserWallpaper);

    self.customGlassUsingCustomBackground = usingUserWallpaper;
    self.customGlassBackgroundSourceImage = sourceImage;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat blur = [defaults objectForKey:DOCustomGlassNavigationBackgroundBlurKey] ?
        [defaults floatForKey:DOCustomGlassNavigationBackgroundBlurKey] : 0.10;

    // Assign the current source immediately. A persisted blur is rendered
    // asynchronously on top of this same image, so there is never a frame where
    // an older/native wallpaper is used as an intermediate state.
    ++self.customGlassBackgroundBlurGeneration;
    [UIView performWithoutAnimation:^{
        self.backgroundImageView.image = sourceImage;
    }];
    [self customGlassApplySharedBackgroundBlurIntensity:blur];
}

- (void)customGlassReplaceSharedBackgroundWithImage:(UIImage *)sourceImage
{
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    if (!sourceImage || ![theme.key isEqualToString:DOCustomGlassNavigationThemeKey]) {
        [self customGlassRefreshSharedBackground];
        return;
    }

    // The picker already decoded the exact JPEG that was successfully written.
    // Install it directly for zero-latency refresh, but never inject user media
    // into DOTheme's bundle-image cache.
    self.customGlassUsingCustomBackground = YES;
    self.customGlassBackgroundSourceImage = sourceImage;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat blur = [defaults objectForKey:DOCustomGlassNavigationBackgroundBlurKey] ?
        [defaults floatForKey:DOCustomGlassNavigationBackgroundBlurKey] : 0.10;

    ++self.customGlassBackgroundBlurGeneration;
    [UIView performWithoutAnimation:^{
        self.backgroundImageView.image = sourceImage;
    }];
    [self customGlassApplySharedBackgroundBlurIntensity:blur];
}

- (BOOL)customGlassHasSharedBackground
{
    return self.customGlassUsingCustomBackground && self.customGlassBackgroundSourceImage != nil;
}

- (CGFloat)customGlassLuminanceForView:(UIView *)view
{
    if (!view)
        return 0.28;

    UIImageView *imageView = self.backgroundImageView;
    UIImage *image = self.customGlassBackgroundSourceImage ?: imageView.image;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage || CGRectIsEmpty(imageView.bounds))
        return 0.28;

    CGPoint centerInImageView = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                            toView:imageView];
    CGSize imagePointSize = image.size;
    if (imagePointSize.width <= 0.0 || imagePointSize.height <= 0.0)
        return 0.28;

    CGFloat scale = MAX(CGRectGetWidth(imageView.bounds) / imagePointSize.width,
                        CGRectGetHeight(imageView.bounds) / imagePointSize.height);
    CGFloat renderedWidth = imagePointSize.width * scale;
    CGFloat renderedHeight = imagePointSize.height * scale;
    CGFloat offsetX = (CGRectGetWidth(imageView.bounds) - renderedWidth) * 0.5;
    CGFloat offsetY = (CGRectGetHeight(imageView.bounds) - renderedHeight) * 0.5;
    CGFloat normalizedX = (centerInImageView.x - offsetX) / MAX(renderedWidth, 1.0);
    CGFloat normalizedY = (centerInImageView.y - offsetY) / MAX(renderedHeight, 1.0);
    normalizedX = DOCustomGlassNavigationClamp01(normalizedX);
    normalizedY = DOCustomGlassNavigationClamp01(normalizedY);

    size_t pixelWidth = CGImageGetWidth(cgImage);
    size_t pixelHeight = CGImageGetHeight(cgImage);
    CGFloat sampleWidth = MAX(8.0, pixelWidth * 0.12);
    CGFloat sampleHeight = MAX(8.0, pixelHeight * 0.10);
    CGFloat centerX = normalizedX * pixelWidth;
    CGFloat centerY = normalizedY * pixelHeight;
    CGRect cropRect = CGRectMake(centerX - sampleWidth * 0.5,
                                 centerY - sampleHeight * 0.5,
                                 sampleWidth, sampleHeight);
    cropRect = CGRectIntersection(cropRect, CGRectMake(0.0, 0.0, pixelWidth, pixelHeight));
    if (CGRectIsEmpty(cropRect))
        return 0.28;

    CGImageRef crop = CGImageCreateWithImageInRect(cgImage, cropRect);
    if (!crop)
        return 0.28;

    unsigned char pixel[4] = {0, 0, 0, 255};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0.0, 0.0, 1.0, 1.0), crop);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(crop);

    CGFloat red = pixel[0] / 255.0;
    CGFloat green = pixel[1] / 255.0;
    CGFloat blue = pixel[2] / 255.0;
    return DOCustomGlassNavigationPerceivedLuminance(red, green, blue);
}

- (BOOL)customGlassPrefersDarkForegroundForView:(UIView *)view
{
    static char DOCustomGlassForegroundAssociationKey;
    CGFloat luminance = [self customGlassLuminanceForView:view];
    NSNumber *previous = objc_getAssociatedObject(view, &DOCustomGlassForegroundAssociationKey);

    BOOL useDarkForeground;
    if (luminance >= 0.68)
        useDarkForeground = YES;
    else if (luminance <= 0.46)
        useDarkForeground = NO;
    else if (previous)
        useDarkForeground = previous.boolValue;
    else
        useDarkForeground = luminance > 0.57;

    objc_setAssociatedObject(view, &DOCustomGlassForegroundAssociationKey,
                             @(useDarkForeground), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return useDarkForeground;
}

- (void)setBackgroundDimmed:(BOOL)dimmed
{
    [UIView animateWithDuration:0.3 animations:^{
        // Custom Glass pages rely on the wallpaper as their page background.
        // Preserve its luminance; only the native Dopamine fallback is dimmed.
        self.backgroundImageView.alpha =
            (self.customGlassUsingCustomBackground ? 1.0 : (dimmed ? 0.4 : 1.0));
    }];

    self.backgroundImageView.userInteractionEnabled = NO;
    self.backAction.hidden = !dimmed;
}

#pragma mark - Delegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController
           animationControllerForOperation:(UINavigationControllerOperation)operation
                        fromViewController:(UIViewController *)fromVC
                          toViewController:(UIViewController *)toVC {

    if (fromVC.class == DOMainViewController.class || toVC.class == DOMainViewController.class)
        return [[DOModalTransitionScale alloc] initForwards: operation == UINavigationControllerOperationPush];
    return [[DOModalTransitionPush alloc] initForwards: operation == UINavigationControllerOperationPush];
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    BOOL isMainView = [viewController isKindOfClass:[DOMainViewController class]];
    BOOL isCustomGlassView = [self isCustomGlassFullScreenViewController:viewController];
    [self setBackgroundDimmed:!(isMainView || isCustomGlassView)];
    [self.backAction setIgnoreFrame:[self _frameForViewController:viewController]];
}

#pragma mark - Overrides

-(CGRect)_frameForViewController:(id)viewController
{
    CGRect orig = [super _frameForViewController: viewController];
    if ([[viewController class] isEqual:[DOMainViewController class]] ||
        [self isCustomGlassFullScreenViewController:viewController])
        return orig;
    
    orig.size.width = fmin(orig.size.width - UI_MODAL_PADDING * 2, UI_IPAD_MAX_WIDTH);
    orig.size.height *= [DOGlobalAppearance isSmallDevice] ? 0.8 : 0.7;
    orig.origin.x = (self.view.frame.size.width - orig.size.width) / 2;
    orig.origin.y = (self.view.frame.size.height - orig.size.height) / 2;

    return orig;

}


@end
