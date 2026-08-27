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
#import "DOCustomGlassMediaStore.h"
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

static UIImage *DOCustomGlassNavigationResolveBackground(DOTheme *theme, BOOL *usingUserWallpaper)
{
    BOOL isCustomGlass = [theme.key isEqualToString:DOCustomGlassNavigationThemeKey];
    UIImage *userWallpaper = isCustomGlass ? DOCustomGlassMediaStoreLoadWallpaper() : nil;

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

// Collapse a small wallpaper crop to a handful of pixels and use both mean
// luminance and local contrast. The contrast term makes bright patches count
// without allowing one tiny highlight to force a heavy scrim over the band.
static CGFloat DOCustomGlassNavigationEffectiveLuminanceForCrop(CGImageRef crop)
{
    if (!crop)
        return 0.28;

    enum { sampleWidth = 4, sampleHeight = 3 };
    unsigned char pixels[sampleWidth * sampleHeight * 4] = {0};

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels,
                                                  sampleWidth,
                                                  sampleHeight,
                                                  8,
                                                  sampleWidth * 4,
                                                  colorSpace,
                                                  kCGImageAlphaPremultipliedLast |
                                                  kCGBitmapByteOrder32Big);
    if (!context) {
        CGColorSpaceRelease(colorSpace);
        return 0.28;
    }

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context,
                       CGRectMake(0.0, 0.0, sampleWidth, sampleHeight),
                       crop);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    CGFloat sum = 0.0;
    CGFloat sumSquares = 0.0;
    NSUInteger count = sampleWidth * sampleHeight;
    for (NSUInteger index = 0; index < count; index++) {
        NSUInteger offset = index * 4;
        CGFloat red = pixels[offset] / 255.0;
        CGFloat green = pixels[offset + 1] / 255.0;
        CGFloat blue = pixels[offset + 2] / 255.0;
        CGFloat luminance = DOCustomGlassNavigationPerceivedLuminance(red, green, blue);
        sum += luminance;
        sumSquares += luminance * luminance;
    }

    CGFloat mean = sum / MAX((CGFloat)count, 1.0);
    CGFloat variance = MAX(0.0, (sumSquares / MAX((CGFloat)count, 1.0)) - (mean * mean));
    return DOCustomGlassNavigationClamp01(mean + (sqrt(variance) * 0.30));
}

static CGFloat DOCustomGlassNavigationScrimAlpha(CGFloat luminance, CGFloat hierarchyBias)
{
    // Apple-style restraint: dark media receives essentially no intervention.
    // Dimming ramps non-linearly only when the local media gets bright, with a
    // hard 35% ceiling for very bright photo/video backgrounds.
    CGFloat t = DOCustomGlassNavigationClamp01((luminance - 0.30) / 0.62);
    CGFloat adaptive = 0.30 * pow(t, 1.45);
    return MIN(0.35, adaptive + (hierarchyBias * t));
}

static CGFloat DOCustomGlassNavigationGlobalScrimAlpha(CGFloat luminance)
{
    // Global intervention is deliberately tiny. It only catches wallpapers that
    // are bright almost everywhere; local fields do the real readability work.
    CGFloat t = DOCustomGlassNavigationClamp01((luminance - 0.62) / 0.34);
    return 0.06 * pow(t, 1.70);
}

static CAGradientLayer *DOCustomGlassNavigationCreateLocalizedScrimLayer(void)
{
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.type = kCAGradientLayerRadial;
    layer.startPoint = CGPointMake(0.5, 0.5);
    layer.endPoint = CGPointMake(1.0, 1.0);
    layer.locations = @[@0.0, @0.56, @1.0];
    layer.opacity = 0.0;
    layer.actions = @{
        @"bounds": [NSNull null],
        @"position": [NSNull null],
        @"colors": [NSNull null],
        @"opacity": [NSNull null],
    };
    return layer;
}

static void DOCustomGlassNavigationConfigureLocalizedScrimLayer(CAGradientLayer *layer,
                                                                 CGRect targetRect,
                                                                 CGRect viewportBounds,
                                                                 CGFloat alpha,
                                                                 CGFloat horizontalPadding,
                                                                 CGFloat verticalPadding)
{
    if (!layer || CGRectIsEmpty(targetRect) || alpha <= 0.001) {
        layer.opacity = 0.0;
        return;
    }

    CGRect fieldRect = CGRectInset(targetRect, -horizontalPadding, -verticalPadding);
    fieldRect = CGRectIntersection(fieldRect, viewportBounds);
    if (CGRectIsEmpty(fieldRect)) {
        layer.opacity = 0.0;
        return;
    }

    layer.frame = fieldRect;
    layer.colors = @[
        (id)[[UIColor blackColor] colorWithAlphaComponent:alpha].CGColor,
        (id)[[UIColor blackColor] colorWithAlphaComponent:(alpha * 0.68)].CGColor,
        (id)[[UIColor blackColor] colorWithAlphaComponent:0.0].CGColor,
    ];
    layer.opacity = 1.0;
}

@interface DONavigationController ()

@property (nonatomic) UIImageView *backgroundImageView;
@property (nonatomic, strong) UIView *customGlassWallpaperScrimView;
@property (nonatomic, strong) CALayer *customGlassWallpaperBaseScrimLayer;
@property (nonatomic, strong) CAGradientLayer *customGlassWallpaperHeaderScrimLayer;
@property (nonatomic, strong) CAGradientLayer *customGlassWallpaperProfileScrimLayer;
@property (nonatomic, strong) CAGradientLayer *customGlassWallpaperGlassScrimLayer;
@property (nonatomic, strong) CAGradientLayer *customGlassWallpaperJailbreakScrimLayer;
@property (nonatomic, weak) UIView *customGlassReadabilityHeaderView;
@property (nonatomic, weak) UIView *customGlassReadabilityProfileView;
@property (nonatomic, weak) UIView *customGlassReadabilityGlassView;
@property (nonatomic, weak) UIView *customGlassReadabilityJailbreakView;
@property (nonatomic, strong) UIImage *customGlassWallpaperScrimSourceImage;
@property (nonatomic, assign) CGSize customGlassWallpaperScrimViewportSize;
@property (nonatomic, assign) CGRect customGlassWallpaperHeaderFrame;
@property (nonatomic, assign) CGRect customGlassWallpaperProfileFrame;
@property (nonatomic, assign) CGRect customGlassWallpaperGlassFrame;
@property (nonatomic, assign) CGRect customGlassWallpaperJailbreakFrame;
@property (nonatomic, assign) BOOL customGlassReadabilityHomeVisible;
@property (nonatomic, strong) UIImage *customGlassBackgroundSourceImage;
@property (nonatomic, assign) BOOL customGlassUsingCustomBackground;
@property (nonatomic, assign) NSUInteger customGlassBackgroundBlurGeneration;
@property (nonatomic) DOMainViewController *mainView;
@property (nonatomic) DOModalBackAction *backAction;

- (CGFloat)customGlassWallpaperEffectiveLuminanceForView:(UIView *)view;
- (void)customGlassUpdateWallpaperScrimIfNeeded;

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

    // Keep readability separate from both wallpaper pixels and Glass material.
    // R14.2 uses a tiny global safety dim plus four feathered local fields that
    // follow the actual Home UI geometry instead of darkening full-width bands.
    UIView *wallpaperScrimView = [[UIView alloc] init];
    wallpaperScrimView.translatesAutoresizingMaskIntoConstraints = NO;
    wallpaperScrimView.backgroundColor = UIColor.clearColor;
    wallpaperScrimView.userInteractionEnabled = NO;
    wallpaperScrimView.layer.zPosition = -0.5;
    [self.view insertSubview:wallpaperScrimView aboveSubview:self.backgroundImageView];
    self.customGlassWallpaperScrimView = wallpaperScrimView;

    CALayer *baseScrimLayer = [CALayer layer];
    baseScrimLayer.backgroundColor = UIColor.blackColor.CGColor;
    baseScrimLayer.opacity = 0.0;
    baseScrimLayer.actions = @{
        @"bounds": [NSNull null],
        @"position": [NSNull null],
        @"opacity": [NSNull null],
    };
    [wallpaperScrimView.layer addSublayer:baseScrimLayer];
    self.customGlassWallpaperBaseScrimLayer = baseScrimLayer;

    self.customGlassWallpaperHeaderScrimLayer = DOCustomGlassNavigationCreateLocalizedScrimLayer();
    self.customGlassWallpaperProfileScrimLayer = DOCustomGlassNavigationCreateLocalizedScrimLayer();
    self.customGlassWallpaperGlassScrimLayer = DOCustomGlassNavigationCreateLocalizedScrimLayer();
    self.customGlassWallpaperJailbreakScrimLayer = DOCustomGlassNavigationCreateLocalizedScrimLayer();
    [wallpaperScrimView.layer addSublayer:self.customGlassWallpaperHeaderScrimLayer];
    [wallpaperScrimView.layer addSublayer:self.customGlassWallpaperProfileScrimLayer];
    [wallpaperScrimView.layer addSublayer:self.customGlassWallpaperGlassScrimLayer];
    [wallpaperScrimView.layer addSublayer:self.customGlassWallpaperJailbreakScrimLayer];

    self.customGlassReadabilityHomeVisible = YES;

    [NSLayoutConstraint activateConstraints:@[
        [wallpaperScrimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [wallpaperScrimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [wallpaperScrimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [wallpaperScrimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

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
    self.customGlassWallpaperScrimSourceImage = nil;
    [self customGlassUpdateWallpaperScrimIfNeeded];

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
    self.customGlassWallpaperScrimSourceImage = nil;
    [self customGlassUpdateWallpaperScrimIfNeeded];

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

- (void)customGlassRegisterReadabilityHeaderView:(UIView *)headerView
                                     profileView:(UIView *)profileView
                                       glassView:(UIView *)glassView
                                   jailbreakView:(UIView *)jailbreakView
{
    BOOL changed = self.customGlassReadabilityHeaderView != headerView ||
                   self.customGlassReadabilityProfileView != profileView ||
                   self.customGlassReadabilityGlassView != glassView ||
                   self.customGlassReadabilityJailbreakView != jailbreakView;

    self.customGlassReadabilityHeaderView = headerView;
    self.customGlassReadabilityProfileView = profileView;
    self.customGlassReadabilityGlassView = glassView;
    self.customGlassReadabilityJailbreakView = jailbreakView;

    if (changed)
        self.customGlassWallpaperScrimSourceImage = nil;

    [self customGlassUpdateWallpaperScrimIfNeeded];
}

- (CGFloat)customGlassWallpaperEffectiveLuminanceForView:(UIView *)view
{
    UIImageView *imageView = self.backgroundImageView;
    UIImage *image = self.customGlassBackgroundSourceImage;
    CGImageRef cgImage = image.CGImage;
    if (!view || !cgImage || CGRectIsEmpty(imageView.bounds))
        return 0.28;

    CGSize imagePointSize = image.size;
    if (imagePointSize.width <= 0.0 || imagePointSize.height <= 0.0)
        return 0.28;

    CGRect targetInImageView = [view convertRect:view.bounds toView:imageView];
    CGFloat scale = MAX(CGRectGetWidth(imageView.bounds) / imagePointSize.width,
                        CGRectGetHeight(imageView.bounds) / imagePointSize.height);
    CGFloat renderedWidth = imagePointSize.width * scale;
    CGFloat renderedHeight = imagePointSize.height * scale;
    CGFloat offsetX = (CGRectGetWidth(imageView.bounds) - renderedWidth) * 0.5;
    CGFloat offsetY = (CGRectGetHeight(imageView.bounds) - renderedHeight) * 0.5;
    CGRect renderedImageRect = CGRectMake(offsetX, offsetY, renderedWidth, renderedHeight);
    targetInImageView = CGRectIntersection(targetInImageView, renderedImageRect);
    if (CGRectIsEmpty(targetInImageView))
        return 0.28;

    CGRect sourcePointRect = CGRectMake((CGRectGetMinX(targetInImageView) - offsetX) / MAX(scale, 0.001),
                                        (CGRectGetMinY(targetInImageView) - offsetY) / MAX(scale, 0.001),
                                        CGRectGetWidth(targetInImageView) / MAX(scale, 0.001),
                                        CGRectGetHeight(targetInImageView) / MAX(scale, 0.001));
    sourcePointRect = CGRectIntersection(sourcePointRect,
                                         CGRectMake(0.0, 0.0, imagePointSize.width, imagePointSize.height));
    if (CGRectIsEmpty(sourcePointRect))
        return 0.28;

    size_t pixelWidth = CGImageGetWidth(cgImage);
    size_t pixelHeight = CGImageGetHeight(cgImage);
    CGFloat pixelScaleX = pixelWidth / MAX(imagePointSize.width, 1.0);
    CGFloat pixelScaleY = pixelHeight / MAX(imagePointSize.height, 1.0);
    CGRect cropRect = CGRectMake(CGRectGetMinX(sourcePointRect) * pixelScaleX,
                                 CGRectGetMinY(sourcePointRect) * pixelScaleY,
                                 CGRectGetWidth(sourcePointRect) * pixelScaleX,
                                 CGRectGetHeight(sourcePointRect) * pixelScaleY);
    cropRect = CGRectIntersection(cropRect, CGRectMake(0.0, 0.0, pixelWidth, pixelHeight));
    if (CGRectIsEmpty(cropRect))
        return 0.28;

    CGImageRef crop = CGImageCreateWithImageInRect(cgImage, cropRect);
    CGFloat luminance = DOCustomGlassNavigationEffectiveLuminanceForCrop(crop);
    if (crop)
        CGImageRelease(crop);
    return luminance;
}

- (void)customGlassUpdateWallpaperScrimIfNeeded
{
    CALayer *baseLayer = self.customGlassWallpaperBaseScrimLayer;
    if (!baseLayer)
        return;

    NSArray<CAGradientLayer *> *localLayers = @[
        self.customGlassWallpaperHeaderScrimLayer,
        self.customGlassWallpaperProfileScrimLayer,
        self.customGlassWallpaperGlassScrimLayer,
        self.customGlassWallpaperJailbreakScrimLayer,
    ];

    if (!self.customGlassUsingCustomBackground || !self.customGlassBackgroundSourceImage ||
        !self.customGlassReadabilityHomeVisible) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        baseLayer.opacity = 0.0;
        for (CAGradientLayer *layer in localLayers)
            layer.opacity = 0.0;
        [CATransaction commit];
        self.customGlassWallpaperScrimSourceImage = nil;
        self.customGlassWallpaperScrimViewportSize = CGSizeZero;
        return;
    }

    UIView *scrimView = self.customGlassWallpaperScrimView;
    CGSize viewportSize = scrimView.bounds.size;
    CGRect viewportBounds = scrimView.bounds;
    if (viewportSize.width <= 1.0 || viewportSize.height <= 1.0)
        return;

    UIView *headerView = self.customGlassReadabilityHeaderView;
    UIView *profileView = self.customGlassReadabilityProfileView;
    UIView *glassView = self.customGlassReadabilityGlassView;
    UIView *jailbreakView = self.customGlassReadabilityJailbreakView;

    CGRect headerFrame = headerView ? [headerView convertRect:headerView.bounds toView:scrimView] : CGRectZero;
    CGRect profileFrame = profileView ? [profileView convertRect:profileView.bounds toView:scrimView] : CGRectZero;
    CGRect glassFrame = glassView ? [glassView convertRect:glassView.bounds toView:scrimView] : CGRectZero;
    CGRect jailbreakFrame = jailbreakView ? [jailbreakView convertRect:jailbreakView.bounds toView:scrimView] : CGRectZero;

    UIImage *sourceImage = self.customGlassBackgroundSourceImage;
    if (self.customGlassWallpaperScrimSourceImage == sourceImage &&
        CGSizeEqualToSize(self.customGlassWallpaperScrimViewportSize, viewportSize) &&
        CGRectEqualToRect(self.customGlassWallpaperHeaderFrame, headerFrame) &&
        CGRectEqualToRect(self.customGlassWallpaperProfileFrame, profileFrame) &&
        CGRectEqualToRect(self.customGlassWallpaperGlassFrame, glassFrame) &&
        CGRectEqualToRect(self.customGlassWallpaperJailbreakFrame, jailbreakFrame))
        return;

    CGFloat globalLuminance = [self customGlassWallpaperEffectiveLuminanceForView:self.view];
    CGFloat headerLuminance = [self customGlassWallpaperEffectiveLuminanceForView:headerView];
    CGFloat profileLuminance = [self customGlassWallpaperEffectiveLuminanceForView:profileView];
    CGFloat glassLuminance = [self customGlassWallpaperEffectiveLuminanceForView:glassView];
    CGFloat jailbreakLuminance = [self customGlassWallpaperEffectiveLuminanceForView:jailbreakView];

    CGFloat baseAlpha = DOCustomGlassNavigationGlobalScrimAlpha(globalLuminance);
    CGFloat headerAlpha = MIN(0.26, DOCustomGlassNavigationScrimAlpha(headerLuminance, 0.018) * 0.88);
    CGFloat profileAlpha = MIN(0.16, DOCustomGlassNavigationScrimAlpha(profileLuminance, 0.0) * 0.58);
    CGFloat glassAlpha = MIN(0.31, DOCustomGlassNavigationScrimAlpha(glassLuminance, 0.030) * 1.06);
    CGFloat jailbreakAlpha = MIN(0.29, DOCustomGlassNavigationScrimAlpha(jailbreakLuminance, 0.026) * 1.02);

    CGFloat baseHorizontalPadding = MAX(28.0, viewportSize.width * 0.065);
    CGFloat baseVerticalPadding = MAX(22.0, viewportSize.height * 0.026);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    baseLayer.frame = viewportBounds;
    baseLayer.opacity = baseAlpha;

    DOCustomGlassNavigationConfigureLocalizedScrimLayer(self.customGlassWallpaperHeaderScrimLayer,
                                                         headerFrame, viewportBounds, headerAlpha,
                                                         baseHorizontalPadding * 1.10,
                                                         baseVerticalPadding * 1.25);
    DOCustomGlassNavigationConfigureLocalizedScrimLayer(self.customGlassWallpaperProfileScrimLayer,
                                                         profileFrame, viewportBounds, profileAlpha,
                                                         baseHorizontalPadding,
                                                         baseVerticalPadding);
    DOCustomGlassNavigationConfigureLocalizedScrimLayer(self.customGlassWallpaperGlassScrimLayer,
                                                         glassFrame, viewportBounds, glassAlpha,
                                                         baseHorizontalPadding * 1.18,
                                                         MAX(34.0, CGRectGetHeight(glassFrame) * 0.18));
    DOCustomGlassNavigationConfigureLocalizedScrimLayer(self.customGlassWallpaperJailbreakScrimLayer,
                                                         jailbreakFrame, viewportBounds, jailbreakAlpha,
                                                         baseHorizontalPadding * 1.08,
                                                         MAX(26.0, CGRectGetHeight(jailbreakFrame) * 0.55));
    [CATransaction commit];

    self.customGlassWallpaperScrimSourceImage = sourceImage;
    self.customGlassWallpaperScrimViewportSize = viewportSize;
    self.customGlassWallpaperHeaderFrame = headerFrame;
    self.customGlassWallpaperProfileFrame = profileFrame;
    self.customGlassWallpaperGlassFrame = glassFrame;
    self.customGlassWallpaperJailbreakFrame = jailbreakFrame;

    NSLog(@"[CustomGlass][LocalizedScrim] base=%.3f header=%.3f profile=%.3f glass=%.3f jail=%.3f",
          baseAlpha, headerAlpha, profileAlpha, glassAlpha, jailbreakAlpha);
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
    if (self.customGlassReadabilityHomeVisible != isMainView) {
        self.customGlassReadabilityHomeVisible = isMainView;
        self.customGlassWallpaperScrimSourceImage = nil;
        [self customGlassUpdateWallpaperScrimIfNeeded];
    }
    [self setBackgroundDimmed:!(isMainView || isCustomGlassView)];
    [self.backAction setIgnoreFrame:[self _frameForViewController:viewController]];
}

#pragma mark - Overrides

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.customGlassWallpaperBaseScrimLayer.frame = self.customGlassWallpaperScrimView.bounds;
    [CATransaction commit];

    [self customGlassUpdateWallpaperScrimIfNeeded];
}

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
