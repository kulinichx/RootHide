//
//  DOMainViewController.m
//  Dopamine
//
//  Created by tomt000 on 08/01/2024.
//

#import "DOMainViewController.h"
#import "DOUIManager.h"
#import "DOPreferenceManager.h"
#import "DOEnvironmentManager.h"
#import "DOJailbreaker.h"
#import "DOGlobalAppearance.h"
#import "DOActionMenuButton.h"
#import "DOUpdateViewController.h"
#import "DOLogCrashViewController.h"
#import "DOCustomGlassMediaStore.h"
#import "DOCustomGlassRefractionView.h"
#import "DOSupporterLicense.h"
#import <pthread.h>
#import <sys/sysctl.h>
#import <libjailbreak/libjailbreak.h>
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface UINavigationController (DOCustomGlassSharedBackground)
- (void)customGlassRefreshSharedBackground;
- (void)customGlassReplaceSharedBackgroundWithImage:(UIImage *)image;
- (void)customGlassApplySharedBackgroundBlurIntensity:(CGFloat)blurIntensity;
- (BOOL)customGlassIsUsingVideoWallpaper;
- (void)customGlassSetWallpaperPlaybackRate:(CGFloat)playbackRate;
- (BOOL)customGlassHasSharedBackground;
- (UIImage *)customGlassCurrentDisplayedBackgroundImage;
- (UIView *)customGlassBackgroundSamplingView;
- (UIView *)customGlassWallpaperScrimSamplingView;
- (NSArray<NSNumber *> *)customGlassCurrentWallpaperScrimLocations;
- (NSArray<NSNumber *> *)customGlassCurrentWallpaperScrimAlphas;
- (BOOL)customGlassPrefersDarkForegroundForView:(UIView *)view;
@end

static UIColor *DOCustomGlassForegroundColorForMode(BOOL darkForeground, CGFloat alpha)
{
    return [UIColor colorWithWhite:(darkForeground ? 0.08 : 1.0) alpha:alpha];
}

static void DOCustomGlassApplyForegroundMode(UIView *view, BOOL darkForeground)
{
    if (!view)
        return;

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        CGFloat alpha = label.font.pointSize >= 15.0 ? 0.96 : 0.78;
        label.textColor = DOCustomGlassForegroundColorForMode(darkForeground, alpha);
        label.shadowColor = [UIColor colorWithWhite:(darkForeground ? 1.0 : 0.0) alpha:0.08];
        label.shadowOffset = CGSizeMake(0.0, 0.30);
    }
    else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        UIColor *foreground = DOCustomGlassForegroundColorForMode(darkForeground, 0.96);
        button.tintColor = foreground;
        if (button.configuration) {
            UIButtonConfiguration *configuration = [button.configuration copy];
            configuration.baseForegroundColor = foreground;
            button.configuration = configuration;
        }
        [button setTitleColor:foreground forState:UIControlStateNormal];
    }
    else if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        if (imageView.image.renderingMode == UIImageRenderingModeAlwaysTemplate)
            imageView.tintColor = DOCustomGlassForegroundColorForMode(darkForeground, 0.94);
    }

    for (UIView *subview in view.subviews)
        DOCustomGlassApplyForegroundMode(subview, darkForeground);
}

static void DOCustomGlassApplyAdaptiveForeground(UINavigationController *navigationController, UIView *view)
{
    // Custom Glass uses stable Light Content. Wallpaper luminance still drives
    // material-body separation inside DOCustomLiquidGlassView, but it must never
    // flip labels/icons between black and white on bright photos.
    (void)navigationController;
    DOCustomGlassApplyForegroundMode(view, NO);
}

#pragma mark - Custom Glass Theme Settings V1

static NSString * const DOCustomGlassBackgroundBlurKey = @"DOCustomGlassTheme.BackgroundBlur";
static NSString * const DOCustomGlassBlurIntensityKey = @"DOCustomGlassTheme.GlassBlurIntensity";
static NSString * const DOCustomGlassTransparencyKey = @"DOCustomGlassTheme.GlassTransparency";
static NSString * const DOCustomGlassTintAlphaKey = @"DOCustomGlassTheme.GlassTintAlpha";
static NSString * const DOCustomGlassAppearanceKey = @"DOCustomGlassTheme.Appearance";
static NSString * const DOCustomGlassAppearanceLight = @"light";
static NSString * const DOCustomGlassAppearanceDark = @"dark";
static NSString * const DOCustomGlassUsernameKey = @"DOCustomGlassTheme.Username";
static NSString * const DOCustomGlassMottoKey = @"DOCustomGlassTheme.Motto";
static NSString * const DOCustomGlassProfileFocusEnabledKey = @"DOCustomGlassTheme.ProfileFocusEnabled";
static NSString * const DOCustomGlassProfileFocusDockRightKey = @"DOCustomGlassTheme.ProfileFocusDockRight";
static NSString * const DOCustomGlassWallpaperPlaybackRateKey = @"DOCustomGlassTheme.WallpaperPlaybackRate";
static CGFloat const DOCustomGlassWallpaperPlaybackRateDefault = 0.65;
static NSString * const DOCustomGlassThemeDidChangeNotification = @"DOCustomGlassTheme.DidChange";
static NSUInteger const DOCustomGlassUsernameCharacterLimit = 20;
static NSUInteger const DOCustomGlassMottoCharacterLimit = 32;

static inline CGFloat DOCustomGlassClamp01(CGFloat value)
{
    return MIN(1.0, MAX(0.0, value));
}

static UIImage *DOCustomGlassSolidImage(UIColor *color)
{
    CGRect rect = CGRectMake(0.0, 0.0, 1.0, 1.0);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);
    [color setFill];
    UIRectFill(rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static id DOCustomGlassCreateCAFilter(NSString *type)
{
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL selector = NSSelectorFromString(@"filterWithType:");
    if (!filterClass || ![filterClass respondsToSelector:selector])
        return nil;

    IMP implementation = [filterClass methodForSelector:selector];
    typedef id (*DOCustomGlassFilterFactoryIMP)(id, SEL, id);
    DOCustomGlassFilterFactoryIMP factory = (DOCustomGlassFilterFactoryIMP)implementation;
    return factory(filterClass, selector, type);
}

@interface DOCustomWallpaperBlurView : UIView

@property(nonatomic, strong) UIVisualEffectView *fallbackBlurView;
@property(nonatomic, assign) CGFloat blurIntensity;

- (void)setBlurIntensity:(CGFloat)blurIntensity;

@end

@implementation DOCustomWallpaperBlurView

@synthesize blurIntensity = _blurIntensity;

+ (Class)layerClass
{
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _blurIntensity = 0.0;
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        [self setBlurIntensity:0.0];
    }
    return self;
}

- (void)setBlurIntensity:(CGFloat)blurIntensity
{
    _blurIntensity = DOCustomGlassClamp01(blurIntensity);

    BOOL isBackdropLayer = [NSStringFromClass(self.layer.class) containsString:@"Backdrop"];
    if (isBackdropLayer) {
        CGFloat radius = 22.0 * pow(_blurIntensity, 1.10);
        NSMutableArray *filters = [NSMutableArray array];

        if (radius > 0.05) {
            id blur = DOCustomGlassCreateCAFilter(@"gaussianBlur");
            if (blur) {
                [blur setValue:@(radius) forKey:@"inputRadius"];
                [blur setValue:@YES forKey:@"inputNormalizeEdges"];
                [blur setValue:@YES forKey:@"inputHardEdges"];
                [filters addObject:blur];
            }
        }

        [self.layer setValue:filters forKey:@"filters"];
        [self.layer setValue:@1.0 forKey:@"scale"];
        [self.fallbackBlurView removeFromSuperview];
        self.fallbackBlurView = nil;
    }
    else {
        if (!self.fallbackBlurView) {
            UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
            self.fallbackBlurView = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.fallbackBlurView.userInteractionEnabled = NO;
            [self addSubview:self.fallbackBlurView];
        }
        self.fallbackBlurView.alpha = _blurIntensity;
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.fallbackBlurView.frame = self.bounds;
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];

    // CABackdropLayer can keep a stale sampling state when a controller is
    // pushed, popped, and then recreated. Rebuild the gaussian filter after
    // the view is attached to a real window so repeated entries behave exactly
    // like the first presentation instead of waiting for a wallpaper change.
    if (self.window) {
        CGFloat blurIntensity = self.blurIntensity;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setBlurIntensity:blurIntensity];
            [weakSelf.layer setNeedsDisplay];
            [weakSelf setNeedsLayout];
        });
    }
}

@end

@interface DOCustomLiquidGlassView : UIView

@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UIView *neutralTintView;
@property(nonatomic, strong) UIVisualEffectView *fallbackBlurView;
@property(nonatomic, strong) CAGradientLayer *specularGradientLayer;
@property(nonatomic, strong) CAShapeLayer *specularMaskLayer;
@property(nonatomic, strong) CAGradientLayer *specularBoostGradientLayer;
@property(nonatomic, strong) CAShapeLayer *specularBoostMaskLayer;
@property(nonatomic, strong) CAGradientLayer *specularDarkGradientLayer;
@property(nonatomic, strong) CAShapeLayer *specularDarkMaskLayer;
@property(nonatomic, assign) CGFloat preferredCornerRadius;
@property(nonatomic, assign) CGFloat baseTintAlpha;
@property(nonatomic, assign) CGFloat materialScale;
@property(nonatomic, assign) CGFloat materialBodyScale;
@property(nonatomic, assign) CGFloat materialOpticalScale;
@property(nonatomic, assign) CGFloat materialBackdropScale;
@property(nonatomic, assign) CGFloat materialSpecularScale;
@property(nonatomic, assign) CGFloat materialEdgeDarkScale;
@property(nonatomic, assign) BOOL suppressBackdrop;
@property(nonatomic, assign) CGFloat lastRenderedShortDimension;

- (instancetype)initWithCornerRadius:(CGFloat)cornerRadius baseTintAlpha:(CGFloat)baseTintAlpha;
- (void)reloadMaterial;

@end

@implementation DOCustomLiquidGlassView

+ (Class)layerClass
{
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass ?: [CALayer class];
}

- (instancetype)initWithCornerRadius:(CGFloat)cornerRadius baseTintAlpha:(CGFloat)baseTintAlpha
{
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _preferredCornerRadius = MAX(0.0, cornerRadius);
        _baseTintAlpha = MAX(0.0, baseTintAlpha);
        _materialScale = 1.0;
        _materialBodyScale = 1.0;
        _materialOpticalScale = 1.0;
        _materialBackdropScale = 1.0;
        _materialSpecularScale = 1.0;
        _materialEdgeDarkScale = 1.0;
        _suppressBackdrop = NO;
        _lastRenderedShortDimension = 0.0;

        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
        self.layer.cornerRadius = _preferredCornerRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _neutralTintView = [[UIView alloc] initWithFrame:CGRectZero];
        _neutralTintView.userInteractionEnabled = NO;
        [self addSubview:_neutralTintView];

        _contentView = [[UIView alloc] initWithFrame:CGRectZero];
        _contentView.translatesAutoresizingMaskIntoConstraints = NO;
        _contentView.backgroundColor = UIColor.clearColor;
        _contentView.layer.zPosition = 10.0;
        [self addSubview:_contentView];
        [NSLayoutConstraint activateConstraints:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
        ]];

        // Glass V2.2: the optical language is perimeter-only. The material body
        // comes from backdrop + neutral tint; highlight owns only three thin,
        // directional rails inspired by Mango's specular/boost/dark structure.
        _specularGradientLayer = [CAGradientLayer layer];
        _specularGradientLayer.startPoint = CGPointMake(0.0, 0.0);
        _specularGradientLayer.endPoint = CGPointMake(1.0, 1.0);
        _specularGradientLayer.locations = @[@0.0, @0.34, @0.50, @0.66, @1.0];
        _specularGradientLayer.zPosition = 901.0;
        _specularMaskLayer = [CAShapeLayer layer];
        _specularMaskLayer.fillColor = UIColor.clearColor.CGColor;
        _specularMaskLayer.strokeColor = UIColor.whiteColor.CGColor;
        _specularMaskLayer.lineWidth = 1.30;
        _specularGradientLayer.mask = _specularMaskLayer;
        [self.layer addSublayer:_specularGradientLayer];

        _specularBoostGradientLayer = [CAGradientLayer layer];
        _specularBoostGradientLayer.startPoint = CGPointMake(0.0, 0.0);
        _specularBoostGradientLayer.endPoint = CGPointMake(1.0, 1.0);
        _specularBoostGradientLayer.locations = @[@0.0, @0.22, @0.50, @0.78, @1.0];
        _specularBoostGradientLayer.zPosition = 902.0;
        _specularBoostMaskLayer = [CAShapeLayer layer];
        _specularBoostMaskLayer.fillColor = UIColor.clearColor.CGColor;
        _specularBoostMaskLayer.strokeColor = UIColor.whiteColor.CGColor;
        _specularBoostMaskLayer.lineWidth = 0.70;
        _specularBoostGradientLayer.mask = _specularBoostMaskLayer;
        [self.layer addSublayer:_specularBoostGradientLayer];

        // Rotate the dark field by 90 degrees relative to the bright field so the
        // opposite edges carry a quiet contour instead of a uniform black stroke.
        _specularDarkGradientLayer = [CAGradientLayer layer];
        _specularDarkGradientLayer.startPoint = CGPointMake(1.0, 0.0);
        _specularDarkGradientLayer.endPoint = CGPointMake(0.0, 1.0);
        _specularDarkGradientLayer.locations = @[@0.0, @0.24, @0.50, @0.76, @1.0];
        _specularDarkGradientLayer.zPosition = 900.0;
        _specularDarkMaskLayer = [CAShapeLayer layer];
        _specularDarkMaskLayer.fillColor = UIColor.clearColor.CGColor;
        _specularDarkMaskLayer.strokeColor = UIColor.whiteColor.CGColor;
        _specularDarkMaskLayer.lineWidth = 0.32;
        _specularDarkGradientLayer.mask = _specularDarkMaskLayer;
        [self.layer addSublayer:_specularDarkGradientLayer];

        [self reloadMaterial];
    }
    return self;
}

- (BOOL)usesDarkAppearance
{
    UIUserInterfaceStyle style = self.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified)
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    return style == UIUserInterfaceStyleDark;
}

- (CGFloat)surfaceGeometryScale
{
    CGFloat shortDimension = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    if (shortDimension <= 1.0)
        return MIN(0.92, MAX(0.42, 0.58 * MAX(0.35, self.materialScale)));

    // GlassFolders' folder-sized optical rail is intentionally richer than a
    // small action pill. Scale the geometry from the surface's short edge so
    // compact controls never inherit a folder-sized shoulder/filament.
    CGFloat normalized = DOCustomGlassClamp01((shortDimension - 42.0) / 118.0);
    CGFloat sizeScale = 0.42 + (0.50 * normalized);
    CGFloat roleScale = sqrt(MAX(0.18, MIN(1.15, self.materialScale)));
    return MIN(0.96, MAX(0.24, sizeScale * roleScale));
}

- (void)reloadMaterial
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    CGFloat blurStrength = [defaults objectForKey:DOCustomGlassBlurIntensityKey] ?
        [defaults floatForKey:DOCustomGlassBlurIntensityKey] : 0.85;
    CGFloat transparency = [defaults objectForKey:DOCustomGlassTransparencyKey] ?
        [defaults floatForKey:DOCustomGlassTransparencyKey] : 0.70;
    CGFloat highlight = [defaults objectForKey:DOCustomGlassTintAlphaKey] ?
        [defaults floatForKey:DOCustomGlassTintAlphaKey] : 0.05;

    blurStrength = DOCustomGlassClamp01(blurStrength);
    transparency = DOCustomGlassClamp01(transparency);
    CGFloat highlightResponse = DOCustomGlassClamp01(highlight / 0.16);
    // R6 keeps the four Theme Settings controls strictly orthogonal:
    // wallpaper blur belongs to DOCustomWallpaperBlurView, Glass blur owns
    // only the local backdrop kernel, transparency owns only the material
    // body/transmission, and highlight owns only the optical rails.
    //
    // The response curves are intentionally wider than R5. On a phone-sized
    // panel, 20% vs 70% transparency and 30% vs 85% highlight must produce a
    // visible change without making the rail physically thicker.
    CGFloat blurResponse = pow(blurStrength, 0.92);
    CGFloat transmissionResponse = pow(transparency, 1.18);
    CGFloat bodyAuthority = 1.0 - transmissionResponse;

    // Match the proven GlassFolders response contract: edge luminance grows
    // much more clearly in the upper half of the slider while geometry barely
    // changes. 0% is genuinely quiet; 100% is obviously illuminated.
    CGFloat opticalResponse =
        (0.12 * highlightResponse) + (0.88 * pow(highlightResponse, 1.80));
    BOOL darkAppearance = [self usesDarkAppearance];
    BOOL darkGlassAppearance =
        [[defaults stringForKey:DOCustomGlassAppearanceKey] isEqualToString:DOCustomGlassAppearanceDark];

    // Per-surface optical role controls. The global sliders still define the
    // user's material; these scales only shape how a specific control expresses
    // that material (broad platter vs. concentrated interactive lens).
    CGFloat materialBackdropScale = MAX(0.0, MIN(1.25, self.materialBackdropScale));
    CGFloat materialSpecularScale = MAX(0.0, MIN(1.35, self.materialSpecularScale));
    CGFloat materialEdgeDarkScale = MAX(0.0, MIN(1.35, self.materialEdgeDarkScale));

    BOOL isBackdropLayer = [NSStringFromClass(self.layer.class) containsString:@"Backdrop"];
    if (isBackdropLayer && !self.suppressBackdrop) {
        CGFloat blurRadius = darkGlassAppearance ?
            (1.10 + (18.2 * blurResponse)) :
            (0.35 + (17.0 * blurResponse));
        // Dark Glass increases diffusion modestly, but preserves wallpaper
        // color transmission instead of turning the material into a black blur.
        // A structural platter gets a quieter, broader diffusion pass while
        // an interactive lens can keep a more concentrated local backdrop.
        // Scale the whole backdrop transform toward neutral rather than stacking
        // a second full-strength material on top of nested controls.
        blurRadius *= materialBackdropScale;
        CGFloat saturation = darkGlassAppearance ?
            (0.98 + (0.08 * blurResponse)) :
            (1.01 + (0.11 * blurResponse));
        saturation = 1.0 + ((saturation - 1.0) * materialBackdropScale);
        CGFloat brightness = darkGlassAppearance ?
            (-0.018 - (0.018 * bodyAuthority)) :
            (darkAppearance ?
                (0.006 + (0.012 * blurResponse)) :
                (0.002 + (0.006 * blurResponse)));
        brightness *= materialBackdropScale;

        id saturate = DOCustomGlassCreateCAFilter(@"colorSaturate");
        id brighten = DOCustomGlassCreateCAFilter(@"colorBrightness");
        id blur = DOCustomGlassCreateCAFilter(@"gaussianBlur");
        NSMutableArray *filters = [NSMutableArray array];

        if (saturate) {
            [saturate setValue:@(saturation) forKey:@"inputAmount"];
            [filters addObject:saturate];
        }
        if (brighten) {
            [brighten setValue:@(brightness) forKey:@"inputAmount"];
            [filters addObject:brighten];
        }
        if (blur && blurRadius > 0.05) {
            [blur setValue:@(blurRadius) forKey:@"inputRadius"];
            [blur setValue:@YES forKey:@"inputNormalizeEdges"];
            [blur setValue:@YES forKey:@"inputHardEdges"];
            [filters addObject:blur];
        }

        [self.layer setValue:filters forKey:@"filters"];
        [self.layer setValue:@1.0 forKey:@"scale"];
        [self.fallbackBlurView removeFromSuperview];
        self.fallbackBlurView = nil;
    }
    else if (isBackdropLayer) {
        // Group shells keep their own visible boundary/body but deliberately
        // skip a second backdrop blur underneath the three restart pills.
        [self.layer setValue:@[] forKey:@"filters"];
        [self.fallbackBlurView removeFromSuperview];
        self.fallbackBlurView = nil;
    }
    else {
        if (!self.fallbackBlurView) {
            UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
            self.fallbackBlurView = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.fallbackBlurView.userInteractionEnabled = NO;
            [self insertSubview:self.fallbackBlurView atIndex:0];
        }
        self.fallbackBlurView.hidden = self.suppressBackdrop;
        self.fallbackBlurView.alpha = self.suppressBackdrop ? 0.0 :
            MIN(0.68, (0.18 + (0.50 * blurResponse)) * materialBackdropScale);
    }

    // Transparency owns a real material-body range now. R5's 0.8%...6.5%
    // neutral lift was too narrow, so Glass disappeared into both blurred and
    // low-contrast wallpapers. Keep a small body even at 100% transmission,
    // and let low transparency build a clearly separate optical layer.
    // Preserve a minimum material body even at maximum transparency. The user
    // should always be able to distinguish a Glass surface from the wallpaper;
    // transparency changes transmission, not whether the hierarchy exists.
    CGFloat tintAlpha =
        0.030 +
        (0.132 * bodyAuthority) +
        (0.12 * self.baseTintAlpha);
    if (darkAppearance)
        tintAlpha += 0.010 * bodyAuthority;

    // Keep the material body globally stable for a selected Glass appearance.
    // The CABackdropLayer already reacts naturally to local wallpaper content;
    // flipping the neutral body between black and white per surface made two
    // identical Main Glass views look like different materials on the same page.
    // Light Glass therefore keeps one faint white transmission body everywhere,
    // while Dark Glass keeps one dark neutral body everywhere.
    if (darkGlassAppearance) {
        CGFloat darkBodyAlpha =
            0.088 +
            (0.118 * bodyAuthority) +
            (0.10 * self.baseTintAlpha);
        self.neutralTintView.backgroundColor = UIColor.blackColor;
        self.neutralTintView.alpha = MIN(0.245, MAX(0.072, darkBodyAlpha));
    }
    else {
        self.neutralTintView.backgroundColor = UIColor.whiteColor;
        self.neutralTintView.alpha = MIN(0.190, tintAlpha);
    }
    self.neutralTintView.alpha *= MAX(0.0, MIN(1.0, self.materialBodyScale));

    CGFloat materialOpticalScale = MAX(0.0, MIN(1.25, self.materialOpticalScale));
    CGFloat brightOpticalScale = materialOpticalScale * materialSpecularScale;
    CGFloat darkEdgeScale = materialOpticalScale * materialEdgeDarkScale;

    // V2.2 contract: Glass Highlight maps only to perimeter specular intensity.
    // Geometry no longer attenuates compact CTA surfaces; Role scales preserve
    // Main/Outer > Inset hierarchy without changing physical rail thickness.
    CGFloat specularAlpha = MIN(0.30,
        0.30 * opticalResponse * brightOpticalScale);
    CGFloat specularBoostAlpha = MIN(0.60,
        0.60 * opticalResponse * brightOpticalScale);
    CGFloat specularDarkAlpha = MIN(0.12,
        0.12 * opticalResponse * darkEdgeScale);

    self.specularGradientLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:specularAlpha].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:specularAlpha * 0.62].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:specularAlpha * 0.30].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:specularAlpha * 0.82].CGColor
    ];

    self.specularBoostGradientLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:specularBoostAlpha].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:specularBoostAlpha * 0.22].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:specularBoostAlpha * 0.14].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:specularBoostAlpha * 0.78].CGColor
    ];

    // Back-facing edges stay almost transparent. The two small dark lobes
    // reinforce material separation, while every corner fades fully to zero.
    self.specularDarkGradientLayer.colors = @[
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:specularDarkAlpha * 0.12].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:specularDarkAlpha * 0.08].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor
    ];

    // Apple-style hierarchy: a broader low-energy reflection region plus a
    // narrower bright filament. The dark rail stays subordinate and never
    // closes the perimeter into a black outline.
    self.specularMaskLayer.lineWidth = 1.30;
    self.specularBoostMaskLayer.lineWidth = 0.70;
    self.specularDarkMaskLayer.lineWidth = 0.32;

    // Keep one neutral structural hairline so Glass still has a material boundary
    // at Highlight = 0. It depends on body/appearance only, never on Highlight.
    CGFloat structuralBorderAlpha = darkGlassAppearance ?
        (0.024 + (0.014 * bodyAuthority)) :
        (0.015 + (0.011 * bodyAuthority));
    self.layer.borderWidth = 0.25;
    self.layer.borderColor = [UIColor colorWithWhite:1.0
                                             alpha:MIN(0.035, structuralBorderAlpha)].CGColor;

}

- (void)layoutSubviews
{
    [super layoutSubviews];

    self.layer.cornerRadius = self.preferredCornerRadius;
    self.neutralTintView.frame = self.bounds;
    self.fallbackBlurView.frame = self.bounds;

    CGFloat shortDimension = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    if (shortDimension > 1.0 && fabs(shortDimension - self.lastRenderedShortDimension) > 0.5) {
        self.lastRenderedShortDimension = shortDimension;
        [self reloadMaterial];
    }

    CGFloat rimInset = self.suppressBackdrop ? 0.28 : 0.34;
    CGRect rimRect = CGRectInset(self.bounds, rimInset, rimInset);
    CGFloat rimRadius = MAX(0.0, self.preferredCornerRadius - rimInset);
    UIBezierPath *rimPath = [UIBezierPath bezierPathWithRoundedRect:rimRect
                                                      cornerRadius:rimRadius];

    self.specularGradientLayer.frame = self.bounds;
    self.specularMaskLayer.frame = self.bounds;
    self.specularMaskLayer.path = rimPath.CGPath;

    self.specularBoostGradientLayer.frame = self.bounds;
    self.specularBoostMaskLayer.frame = self.bounds;
    self.specularBoostMaskLayer.path = rimPath.CGPath;

    self.specularDarkGradientLayer.frame = self.bounds;
    self.specularDarkMaskLayer.frame = self.bounds;
    self.specularDarkMaskLayer.path = rimPath.CGPath;
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    // Controllers explicitly reload their mounted Glass surfaces on appearance
    // and theme changes. Avoid a second asynchronous filter rebuild for every
    // panel during cold launch; that burst was unnecessary on compact iPhones.
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle)
        [self reloadMaterial];
}

@end

// Main Glass is one material across home, Theme Settings, the restart shell,
// and the compact jailbreak status bar. Geometry may differ, but body, backdrop,
// and optical response must not drift into separate material families.
static void DOCustomGlassApplyMainMaterialProfile(DOCustomLiquidGlassView *glassView)
{
    if (!glassView)
        return;

    glassView.materialScale = 0.90;
    glassView.materialBodyScale = 0.92;
    glassView.materialOpticalScale = 0.84;
    glassView.materialBackdropScale = 0.92;
    glassView.materialSpecularScale = 0.82;
    glassView.materialEdgeDarkScale = 0.88;
    glassView.suppressBackdrop = NO;
}

@interface DOCustomGlassSegmentedControl : UISegmentedControl
@property(nonatomic, strong) CALayer *glassSelectionLayer;
@end

@implementation DOCustomGlassSegmentedControl

- (instancetype)initWithItems:(NSArray *)items
{
    self = [super initWithItems:items];
    if (self) {
        _glassSelectionLayer = [CALayer layer];
        _glassSelectionLayer.backgroundColor =
            [UIColor colorWithWhite:1.0 alpha:0.11].CGColor;
        _glassSelectionLayer.cornerRadius = 19.0;
        _glassSelectionLayer.cornerCurve = kCACornerCurveContinuous;
        [self.layer insertSublayer:_glassSelectionLayer atIndex:0];
    }
    return self;
}

- (void)setSelectedSegmentIndex:(NSInteger)selectedSegmentIndex
{
    [super setSelectedSegmentIndex:selectedSegmentIndex];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    NSInteger segmentCount = MAX(1, self.numberOfSegments);
    NSInteger selectedIndex = self.selectedSegmentIndex;
    BOOL hasSelection = selectedIndex != UISegmentedControlNoSegment &&
        selectedIndex >= 0 && selectedIndex < segmentCount;
    if (!hasSelection)
        selectedIndex = 0;

    CGFloat totalWidth = CGRectGetWidth(self.bounds);
    CGFloat segmentWidth = totalWidth / (CGFloat)segmentCount;
    CGRect selectionFrame = self.bounds;
    selectionFrame.origin.x = segmentWidth * selectedIndex;
    selectionFrame.size.width = (selectedIndex == segmentCount - 1)
        ? MAX(0.0, totalWidth - selectionFrame.origin.x)
        : segmentWidth;

    CACornerMask maskedCorners = 0;
    if (segmentCount == 1) {
        maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner |
            kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    }
    else if (selectedIndex == 0) {
        maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    }
    else if (selectedIndex == segmentCount - 1) {
        maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.glassSelectionLayer.hidden = !hasSelection;
    self.glassSelectionLayer.frame = selectionFrame;
    self.glassSelectionLayer.cornerRadius = 19.0;
    self.glassSelectionLayer.cornerCurve = kCACornerCurveContinuous;
    self.glassSelectionLayer.maskedCorners = maskedCorners;
    [CATransaction commit];
}

@end

static UIButton *DOCustomGlassBackButton(UIViewController *controller)
{
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"chevron.left"];
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);

    __weak UIViewController *weakController = controller;
    UIButton *button = [UIButton buttonWithConfiguration:configuration
                                           primaryAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakController.navigationController popViewControllerAnimated:YES];
    }]];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"返回";
    return button;
}

@interface DOCustomGlassThemeSettingsViewController : UIViewController <PHPickerViewControllerDelegate>

@property UIImageView *customGlassBackgroundImageView;
@property DOCustomWallpaperBlurView *backgroundBlurView;
@property DOCustomLiquidGlassView *previewGlassView;

@property UISegmentedControl *glassAppearanceControl;
@property UISlider *backgroundBlurSlider;
@property UISlider *glassBlurSlider;
@property UISlider *glassTransparencySlider;
@property UISlider *glassTintSlider;
@property UIView *wallpaperPlaybackRateRow;
@property UISegmentedControl *wallpaperPlaybackRateControl;

@property UILabel *backgroundBlurValueLabel;
@property UILabel *glassBlurValueLabel;
@property UILabel *glassTransparencyValueLabel;
@property UILabel *glassTintValueLabel;

- (void)prepareForPresentation;
- (void)refreshThemePageFromPersistedState;

@end

@implementation DOCustomGlassThemeSettingsViewController

- (DOCustomLiquidGlassView *)themeGlassViewWithCornerRadius:(CGFloat)cornerRadius tintAlpha:(CGFloat)tintAlpha
{
    DOCustomLiquidGlassView *glassView =
        [[DOCustomLiquidGlassView alloc] initWithCornerRadius:cornerRadius baseTintAlpha:tintAlpha];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    return glassView;
}

- (void)refreshLiquidGlassInView:(UIView *)view
{
    if ([view isKindOfClass:[DOCustomLiquidGlassView class]])
        [(DOCustomLiquidGlassView *)view reloadMaterial];

    for (UIView *subview in view.subviews)
        [self refreshLiquidGlassInView:subview];
}

- (UILabel *)themeSectionLabelWithText:(NSString *)text
{
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    return label;
}

- (DOCustomLiquidGlassView *)themeRowWithTitle:(NSString *)title
                                 subtitle:(NSString *)subtitle
                                imageName:(NSString *)imageName
                                   action:(UIAction *)action
{
    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    DOCustomLiquidGlassView *row = [self themeGlassViewWithCornerRadius:22.0 tintAlpha:0.05];
    // Exact Main Glass profile: Theme Settings rows must render the same
    // material as the home cards rather than a nearby approximation.
    DOCustomGlassApplyMainMaterialProfile(row);
    [row reloadMaterial];

    UIImageSymbolConfiguration *symbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:(isPad ? 21.0 : 19.0)
                                                        weight:UIImageSymbolWeightMedium
                                                         scale:UIImageSymbolScaleMedium];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:imageName withConfiguration:symbolConfiguration]];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tintColor = UIColor.whiteColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:(isPad ? 17.0 : 16.0) weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
    subtitleLabel.font = [UIFont systemFontOfSize:(isPad ? 13.0 : 12.0) weight:UIFontWeightRegular];
    subtitleLabel.numberOfLines = 1;
    subtitleLabel.adjustsFontSizeToFitWidth = YES;
    subtitleLabel.minimumScaleFactor = 0.88;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentFill;
    textStack.spacing = 3.0;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *chevronConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                        weight:UIImageSymbolWeightSemibold
                                                         scale:UIImageSymbolScaleSmall];
    UIImageView *chevronView = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right" withConfiguration:chevronConfiguration]];
    chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    chevronView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.42];
    chevronView.contentMode = UIViewContentModeScaleAspectFit;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = title;
    [button addAction:action forControlEvents:UIControlEventTouchUpInside];

    [row.contentView addSubview:iconView];
    [row.contentView addSubview:textStack];
    [row.contentView addSubview:chevronView];
    [row.contentView addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:(isPad ? 76.0 : 70.0)],

        [iconView.leadingAnchor constraintEqualToAnchor:row.contentView.leadingAnchor constant:18.0],
        [iconView.centerYAnchor constraintEqualToAnchor:row.contentView.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:(isPad ? 28.0 : 26.0)],
        [iconView.heightAnchor constraintEqualToConstant:(isPad ? 28.0 : 26.0)],

        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14.0],
        [textStack.centerYAnchor constraintEqualToAnchor:row.contentView.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:chevronView.leadingAnchor constant:-12.0],

        [chevronView.trailingAnchor constraintEqualToAnchor:row.contentView.trailingAnchor constant:-18.0],
        [chevronView.centerYAnchor constraintEqualToAnchor:row.contentView.centerYAnchor],
        [chevronView.widthAnchor constraintEqualToConstant:12.0],
        [chevronView.heightAnchor constraintEqualToConstant:18.0],

        [button.leadingAnchor constraintEqualToAnchor:row.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:row.contentView.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:row.contentView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:row.contentView.bottomAnchor]
    ]];

    return row;
}

- (UILabel *)appearanceValueLabel
{
    UILabel *label = [[UILabel alloc] init];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.68];
    label.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:48.0].active = YES;
    return label;
}

- (UISlider *)appearanceSlider
{
    UISlider *slider = [[UISlider alloc] init];
    slider.minimumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.24];
    [slider addTarget:self action:@selector(appearanceSliderChanged:) forControlEvents:UIControlEventValueChanged];
    return slider;
}

- (UIView *)appearanceControlRowWithTitle:(NSString *)title
                                subtitle:(NSString *)subtitle
                                  slider:(UISlider *)slider
                              valueLabel:(UILabel *)valueLabel
{
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.52];
    subtitleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];

    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.spacing = 2.0;

    UIStackView *headerRow = [[UIStackView alloc] initWithArrangedSubviews:@[titleStack, valueLabel]];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 10.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[headerRow, slider]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 7.0;
    return row;
}

- (UIView *)appearanceSegmentedRowWithTitle:(NSString *)title
                                   subtitle:(NSString *)subtitle
                                    control:(UISegmentedControl *)control
{
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.52];
    subtitleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];

    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.spacing = 2.0;

    DOCustomLiquidGlassView *inset = [self themeGlassViewWithCornerRadius:21.0 tintAlpha:0.0];
    inset.materialScale = 0.70;
    inset.materialBodyScale = 0.24;
    inset.materialOpticalScale = 0.36;
    inset.materialBackdropScale = 0.0;
    inset.materialSpecularScale = 0.30;
    inset.materialEdgeDarkScale = 0.34;
    inset.suppressBackdrop = YES;
    [inset reloadMaterial];

    control.translatesAutoresizingMaskIntoConstraints = NO;
    [inset.contentView addSubview:control];
    [NSLayoutConstraint activateConstraints:@[
        [control.leadingAnchor constraintEqualToAnchor:inset.contentView.leadingAnchor constant:2.0],
        [control.trailingAnchor constraintEqualToAnchor:inset.contentView.trailingAnchor constant:-2.0],
        [control.topAnchor constraintEqualToAnchor:inset.contentView.topAnchor constant:2.0],
        [control.bottomAnchor constraintEqualToAnchor:inset.contentView.bottomAnchor constant:-2.0],
        [inset.heightAnchor constraintEqualToConstant:42.0]
    ]];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[titleStack, inset]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 7.0;
    return row;
}

static NSInteger DOCustomGlassPlaybackRateSegmentIndex(CGFloat rate)
{
    static const CGFloat rates[] = {0.50, 0.65, 0.80, 1.00};
    NSInteger bestIndex = 0;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSInteger index = 0; index < 4; index++) {
        CGFloat distance = fabs(rate - rates[index]);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = index;
        }
    }
    return bestIndex;
}

static CGFloat DOCustomGlassPlaybackRateForSegmentIndex(NSInteger index)
{
    static const CGFloat rates[] = {0.50, 0.65, 0.80, 1.00};
    NSInteger clampedIndex = MIN(3, MAX(0, index));
    return rates[clampedIndex];
}

static UIImage *DOCustomGlassCreateVideoPosterImage(NSURL *videoURL)
{
    if (!videoURL.isFileURL)
        return nil;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(2048.0, 2048.0);

    NSError *error = nil;
    CMTime requestedTime = CMTimeMakeWithSeconds(0.10, 600);
    CGImageRef frame = [generator copyCGImageAtTime:requestedTime actualTime:NULL error:&error];
    if (!frame) {
        error = nil;
        frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
    }
    if (!frame) {
        NSLog(@"[CustomGlass][VideoWallpaper] poster generation failed: %@", error);
        return nil;
    }

    UIImage *poster = [UIImage imageWithCGImage:frame];
    CGImageRelease(frame);
    return poster;
}

static NSInteger DOCustomGlassLivePhotoVideoResourcePriority(PHAssetResourceType type)
{
    switch (type) {
        case PHAssetResourceTypeFullSizePairedVideo:
            return 3;
        case PHAssetResourceTypePairedVideo:
            return 2;
        case PHAssetResourceTypeAdjustmentBasePairedVideo:
            return 1;
        default:
            return 0;
    }
}

static NSInteger DOCustomGlassLivePhotoImageResourcePriority(PHAssetResourceType type)
{
    switch (type) {
        case PHAssetResourceTypeFullSizePhoto:
            return 3;
        case PHAssetResourceTypePhoto:
            return 2;
        case PHAssetResourceTypeAdjustmentBasePhoto:
            return 1;
        default:
            return 0;
    }
}

static NSError *DOCustomGlassLivePhotoImportError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"DOCustomGlassLivePhotoImport"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Live Photo import failed."}];
}

// PHPicker can vend a PHLivePhoto without granting broad Photo Library access.
// PHAssetResource then exposes that selected object's paired resources directly,
// so Live Photo stays inside the same privacy model as the existing picker.
static void DOCustomGlassExportLivePhoto(PHLivePhoto *livePhoto,
                                         void (^completion)(NSURL *videoURL,
                                                            UIImage *posterImage,
                                                            NSError *error))
{
    if (!livePhoto || !completion)
        return;

    NSArray<PHAssetResource *> *resources = [PHAssetResource assetResourcesForLivePhoto:livePhoto];
    PHAssetResource *videoResource = nil;
    PHAssetResource *imageResource = nil;
    NSInteger videoPriority = 0;
    NSInteger imagePriority = 0;

    for (PHAssetResource *resource in resources) {
        NSInteger candidateVideoPriority = DOCustomGlassLivePhotoVideoResourcePriority(resource.type);
        if (candidateVideoPriority > videoPriority) {
            videoPriority = candidateVideoPriority;
            videoResource = resource;
        }

        NSInteger candidateImagePriority = DOCustomGlassLivePhotoImageResourcePriority(resource.type);
        if (candidateImagePriority > imagePriority) {
            imagePriority = candidateImagePriority;
            imageResource = resource;
        }
    }

    if (!videoResource) {
        completion(nil, nil,
                   DOCustomGlassLivePhotoImportError(1, @"Live Photo has no paired video resource."));
        return;
    }

    NSURL *temporaryRoot = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *temporaryDirectory = [temporaryRoot
        URLByAppendingPathComponent:[NSString stringWithFormat:@"CustomGlass-LivePhoto-%@",
                                                               NSUUID.UUID.UUIDString]
                         isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:temporaryDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        completion(nil, nil, directoryError ?: DOCustomGlassLivePhotoImportError(2, @"Unable to create Live Photo staging directory."));
        return;
    }

    NSURL *videoURL = [temporaryDirectory URLByAppendingPathComponent:@"paired.mov" isDirectory:NO];
    NSString *imageExtension = imageResource.originalFilename.pathExtension.lowercaseString;
    if (imageExtension.length == 0)
        imageExtension = @"jpg";
    NSURL *imageURL = [temporaryDirectory
        URLByAppendingPathComponent:[NSString stringWithFormat:@"poster.%@", imageExtension]
                         isDirectory:NO];

    PHAssetResourceRequestOptions *options = [[PHAssetResourceRequestOptions alloc] init];
    options.networkAccessAllowed = YES;

    PHAssetResourceManager *manager = [PHAssetResourceManager defaultManager];
    dispatch_group_t group = dispatch_group_create();
    __block NSError *videoError = nil;
    __block NSError *imageError = nil;

    dispatch_group_enter(group);
    [manager writeDataForAssetResource:videoResource
                                toFile:videoURL
                               options:options
                     completionHandler:^(NSError *error) {
        videoError = error;
        dispatch_group_leave(group);
    }];

    if (imageResource) {
        dispatch_group_enter(group);
        [manager writeDataForAssetResource:imageResource
                                    toFile:imageURL
                                   options:options
                         completionHandler:^(NSError *error) {
            imageError = error;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group,
                          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL hasVideo = !videoError && [fileManager fileExistsAtPath:videoURL.path];
        if (!hasVideo) {
            NSError *error = videoError ?:
                DOCustomGlassLivePhotoImportError(3, @"Unable to export Live Photo paired video.");
            completion(nil, nil, error);
            [fileManager removeItemAtURL:temporaryDirectory error:nil];
            return;
        }

        UIImage *poster = nil;
        if (imageResource && !imageError && [fileManager fileExistsAtPath:imageURL.path])
            poster = [UIImage imageWithContentsOfFile:imageURL.path];
        if (!poster)
            poster = DOCustomGlassCreateVideoPosterImage(videoURL);

        if (!poster) {
            completion(nil, nil,
                       DOCustomGlassLivePhotoImportError(4, @"Unable to create Live Photo poster image."));
            [fileManager removeItemAtURL:temporaryDirectory error:nil];
            return;
        }

        // The callback must synchronously consume videoURL. MediaStore does so
        // by copying it into the persistent CustomGlass directory.
        completion(videoURL, poster, nil);
        [fileManager removeItemAtURL:temporaryDirectory error:nil];
    });
}

- (void)presentCustomGlassBackgroundPicker
{
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        [PHPickerFilter imagesFilter],
        [PHPickerFilter livePhotosFilter],
        [PHPickerFilter videosFilter]
    ]];
    configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    configuration.selectionLimit = 1;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    [picker dismissViewControllerAnimated:YES completion:nil];

    PHPickerResult *result = results.firstObject;
    if (!result)
        return;

    NSItemProvider *provider = result.itemProvider;
    __weak typeof(self) weakSelf = self;

    void (^finishWallpaperImport)(BOOL) = ^(BOOL saved) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!saved)
                return;

            [[UIApplication sharedApplication] ignoreSnapshotOnNextApplicationLaunch];

            // Always re-resolve MediaStore so image and video imports share the
            // exact same cold-launch and live-preview path.
            [weakSelf.navigationController customGlassRefreshSharedBackground];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:DOCustomGlassThemeDidChangeNotification object:nil];
            [weakSelf syncAppearanceControlsFromDefaults];
            [weakSelf applyAppearancePreviewAndPersist:NO];
        });
    };

    void (^importStaticImage)(void) = ^{
        if (![provider canLoadObjectOfClass:UIImage.class])
            return;

        [provider loadObjectOfClass:UIImage.class
                  completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            if (error || ![object isKindOfClass:UIImage.class]) {
                NSLog(@"[CustomGlass][Wallpaper] image provider failed: %@", error);
                return;
            }

            BOOL saved = DOCustomGlassMediaStoreSaveWallpaper((UIImage *)object, NULL);
            finishWallpaperImport(saved);
        }];
    };

    // Detect Live Photo before public.movie. A Live Photo is imported as its
    // paired motion resource plus key photo, then handed to the exact same
    // persistent AVPlayer pipeline as an ordinary video wallpaper.
    if ([provider canLoadObjectOfClass:PHLivePhoto.class]) {
        [provider loadObjectOfClass:PHLivePhoto.class
                  completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            if (error || ![object isKindOfClass:PHLivePhoto.class]) {
                NSLog(@"[CustomGlass][LivePhoto] provider failed: %@", error);
                importStaticImage();
                return;
            }

            DOCustomGlassExportLivePhoto((PHLivePhoto *)object,
                                         ^(NSURL *videoURL, UIImage *poster, NSError *exportError) {
                if (exportError || !videoURL || !poster) {
                    NSLog(@"[CustomGlass][LivePhoto] export failed: %@", exportError);
                    importStaticImage();
                    return;
                }

                BOOL saved = DOCustomGlassMediaStoreSaveWallpaperVideo(videoURL, poster, NULL);
                if (!saved)
                    NSLog(@"[CustomGlass][LivePhoto] MediaStore commit failed");
                finishWallpaperImport(saved);
            });
        }];
        return;
    }

    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                         completionHandler:^(NSURL *fileURL, NSError *error) {
            if (error || !fileURL) {
                NSLog(@"[CustomGlass][VideoWallpaper] provider failed: %@", error);
                return;
            }

            // PHPicker's representation URL is temporary. Generate the poster
            // and copy the movie into MediaStore before this callback returns.
            UIImage *poster = DOCustomGlassCreateVideoPosterImage(fileURL);
            BOOL saved = poster ?
                DOCustomGlassMediaStoreSaveWallpaperVideo(fileURL, poster, NULL) : NO;
            finishWallpaperImport(saved);
        }];
        return;
    }

    importStaticImage();
}

- (void)showThemePlaceholderForTitle:(NSString *)title
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:@"基础页面已经接入；具体编辑功能会在下一阶段逐项加入。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Close")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)prepareForPresentation
{
    // The navigation controller already owns the persistent first-frame
    // wallpaper. Prime only this controller's local Glass hierarchy before the
    // transition; do not re-decode or re-blur the shared image here.
    [self loadViewIfNeeded];
    [self syncAppearanceControlsFromDefaults];
    [self refreshLiquidGlassInView:self.view];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"主题设置";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.clearColor;

    // The navigation controller owns the only Custom Glass wallpaper layer.
    // This page stays transparent above that persistent source.

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DOCustomGlassAppearanceKey : DOCustomGlassAppearanceLight,
        DOCustomGlassBackgroundBlurKey : @0.10,
        DOCustomGlassBlurIntensityKey : @0.85,
        DOCustomGlassTransparencyKey : @0.70,
        DOCustomGlassTintAlphaKey : @0.05,
        DOCustomGlassUsernameKey : @"",
        DOCustomGlassMottoKey : @"",
        DOCustomGlassWallpaperPlaybackRateKey : @(DOCustomGlassWallpaperPlaybackRateDefault)
    }];

    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.opaque = NO;
    [self.view addSubview:scrollView];

    UIStackView *contentStack = [[UIStackView alloc] init];
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.alignment = UIStackViewAlignmentFill;
    contentStack.spacing = 9.0;
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentStack];

    UIButton *backButton = DOCustomGlassBackButton(self);
    [self.view addSubview:backButton];

    UILabel *pageTitleLabel = [[UILabel alloc] init];
    pageTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    pageTitleLabel.text = @"主题设置";
    pageTitleLabel.textColor = UIColor.whiteColor;
    pageTitleLabel.font = [UIFont systemFontOfSize:(isPad ? 18.0 : 17.0) weight:UIFontWeightSemibold];
    pageTitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:pageTitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
        [backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4.0],
        [backButton.widthAnchor constraintEqualToConstant:44.0],
        [backButton.heightAnchor constraintEqualToConstant:40.0],

        [pageTitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [pageTitleLabel.centerYAnchor constraintEqualToAnchor:backButton.centerYAnchor],

        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [contentStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:(isPad ? 12.0 : 8.0)],
        [contentStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-28.0],
        [contentStack.centerXAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.centerXAnchor],
        [contentStack.widthAnchor constraintLessThanOrEqualToConstant:620.0]
    ]];

    NSLayoutConstraint *responsiveWidth =
        [contentStack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:(isPad ? -56.0 : -40.0)];
    responsiveWidth.priority = UILayoutPriorityDefaultHigh;
    responsiveWidth.active = YES;

    __weak typeof(self) weakSelf = self;

    UILabel *wallpaperLabel = [self themeSectionLabelWithText:@"背景"];
    [contentStack addArrangedSubview:wallpaperLabel];

    [contentStack addArrangedSubview:[self themeRowWithTitle:@"背景"
                                                    subtitle:@"选择首页背景图片或视频"
                                                   imageName:@"photo"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf presentCustomGlassBackgroundPicker];
    }]]];

    UIView *appearanceSpacer = [[UIView alloc] init];
    [contentStack addArrangedSubview:appearanceSpacer];
    [appearanceSpacer.heightAnchor constraintEqualToConstant:7.0].active = YES;

    UILabel *appearanceLabel = [self themeSectionLabelWithText:@"外观效果"];
    [contentStack addArrangedSubview:appearanceLabel];

    // The control panel is the actual Main Glass renderer used by the home
    // cards. Slider changes therefore preview the same body, backdrop and
    // directional optics instead of a deliberately quieter panel variant.
    self.previewGlassView = [self themeGlassViewWithCornerRadius:26.0 tintAlpha:0.05];
    DOCustomGlassApplyMainMaterialProfile(self.previewGlassView);
    [self.previewGlassView reloadMaterial];
    [contentStack addArrangedSubview:self.previewGlassView];
    // This panel previously collapsed to zero height because the Glass content
    // surface was frame-driven. Keep a safety floor even though contentView is
    // now Auto Layout driven, so all four sliders remain visible on every iOS 16
    // device and Dynamic Type configuration.
    [self.previewGlassView.heightAnchor constraintGreaterThanOrEqualToConstant:(isPad ? 488.0 : 472.0)].active = YES;

    UIStackView *controlsStack = [[UIStackView alloc] init];
    controlsStack.translatesAutoresizingMaskIntoConstraints = NO;
    controlsStack.axis = UILayoutConstraintAxisVertical;
    controlsStack.spacing = isPad ? 16.0 : 14.0;
    [self.previewGlassView.contentView addSubview:controlsStack];

    [NSLayoutConstraint activateConstraints:@[
        [controlsStack.leadingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.leadingAnchor constant:20.0],
        [controlsStack.trailingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.trailingAnchor constant:-20.0],
        [controlsStack.topAnchor constraintEqualToAnchor:self.previewGlassView.contentView.topAnchor constant:18.0],
        [controlsStack.bottomAnchor constraintEqualToAnchor:self.previewGlassView.contentView.bottomAnchor constant:-16.0]
    ]];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    UILabel *liquidGlassLabel = [[UILabel alloc] init];
    liquidGlassLabel.text = @"Liquid Glass";
    liquidGlassLabel.textColor = UIColor.whiteColor;
    liquidGlassLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [controlsStack addArrangedSubview:liquidGlassLabel];

    self.glassAppearanceControl = [[DOCustomGlassSegmentedControl alloc] initWithItems:@[@"Light Glass", @"Dark Glass"]];
    self.glassAppearanceControl.translatesAutoresizingMaskIntoConstraints = NO;
    // The segmented control is content inside an Inset Glass surface. Keep the
    // native control itself optically quiet so it does not read as a second,
    // unrelated grey platter pasted over the parent Glass panel.
    self.glassAppearanceControl.selectedSegmentTintColor = UIColor.clearColor;
    self.glassAppearanceControl.backgroundColor = UIColor.clearColor;

    UIImage *normalSegmentImage = DOCustomGlassSolidImage(UIColor.clearColor);
    UIImage *selectedSegmentImage = DOCustomGlassSolidImage(UIColor.clearColor);
    UIImage *clearSegmentImage = DOCustomGlassSolidImage(UIColor.clearColor);
    [self.glassAppearanceControl setBackgroundImage:normalSegmentImage
                                          forState:UIControlStateNormal
                                        barMetrics:UIBarMetricsDefault];
    [self.glassAppearanceControl setBackgroundImage:selectedSegmentImage
                                          forState:UIControlStateSelected
                                        barMetrics:UIBarMetricsDefault];
    [self.glassAppearanceControl setDividerImage:clearSegmentImage
                             forLeftSegmentState:UIControlStateNormal
                               rightSegmentState:UIControlStateNormal
                                      barMetrics:UIBarMetricsDefault];
    [self.glassAppearanceControl setDividerImage:clearSegmentImage
                             forLeftSegmentState:UIControlStateSelected
                               rightSegmentState:UIControlStateNormal
                                      barMetrics:UIBarMetricsDefault];
    [self.glassAppearanceControl setDividerImage:clearSegmentImage
                             forLeftSegmentState:UIControlStateNormal
                               rightSegmentState:UIControlStateSelected
                                      barMetrics:UIBarMetricsDefault];

    self.glassAppearanceControl.layer.cornerRadius = 19.0;
    self.glassAppearanceControl.layer.cornerCurve = kCACornerCurveContinuous;
    self.glassAppearanceControl.layer.masksToBounds = YES;
    self.glassAppearanceControl.accessibilityLabel = @"Liquid Glass";
    [self.glassAppearanceControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1.0 alpha:0.68],
        NSFontAttributeName : [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium]
    } forState:UIControlStateNormal];
    [self.glassAppearanceControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSFontAttributeName : [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold]
    } forState:UIControlStateSelected];

    NSString *appearance = [defaults stringForKey:DOCustomGlassAppearanceKey];
    self.glassAppearanceControl.selectedSegmentIndex =
        [appearance isEqualToString:DOCustomGlassAppearanceDark] ? 1 : 0;
    [self.glassAppearanceControl addTarget:self
                                    action:@selector(glassAppearanceChanged:)
                          forControlEvents:UIControlEventValueChanged];

    // Inset Glass role: a shallow local control surface inside the parent panel.
    // It deliberately has no backdrop pass; the parent previewGlassView owns
    // diffusion/transmission. Only a light body + quiet contour establish depth.
    DOCustomLiquidGlassView *appearanceInset =
        [self themeGlassViewWithCornerRadius:21.0 tintAlpha:0.0];
    appearanceInset.materialScale = 0.70;
    appearanceInset.materialBodyScale = 0.24;
    appearanceInset.materialOpticalScale = 0.36;
    appearanceInset.materialBackdropScale = 0.0;
    appearanceInset.materialSpecularScale = 0.30;
    appearanceInset.materialEdgeDarkScale = 0.34;
    appearanceInset.suppressBackdrop = YES;
    [appearanceInset reloadMaterial];
    [appearanceInset.contentView addSubview:self.glassAppearanceControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.glassAppearanceControl.leadingAnchor constraintEqualToAnchor:appearanceInset.contentView.leadingAnchor constant:2.0],
        [self.glassAppearanceControl.trailingAnchor constraintEqualToAnchor:appearanceInset.contentView.trailingAnchor constant:-2.0],
        [self.glassAppearanceControl.topAnchor constraintEqualToAnchor:appearanceInset.contentView.topAnchor constant:2.0],
        [self.glassAppearanceControl.bottomAnchor constraintEqualToAnchor:appearanceInset.contentView.bottomAnchor constant:-2.0]
    ]];
    [controlsStack addArrangedSubview:appearanceInset];
    [appearanceInset.heightAnchor constraintEqualToConstant:44.0].active = YES;

    self.backgroundBlurSlider = [self appearanceSlider];
    self.backgroundBlurSlider.minimumValue = 0.0;
    self.backgroundBlurSlider.maximumValue = 1.0;
    self.backgroundBlurSlider.value = [defaults floatForKey:DOCustomGlassBackgroundBlurKey];
    self.backgroundBlurValueLabel = [self appearanceValueLabel];
    [controlsStack addArrangedSubview:[self appearanceControlRowWithTitle:@"壁纸模糊"
                                                                 subtitle:@"整张背景的模糊程度"
                                                                   slider:self.backgroundBlurSlider
                                                               valueLabel:self.backgroundBlurValueLabel]];

    self.wallpaperPlaybackRateControl = [[DOCustomGlassSegmentedControl alloc]
        initWithItems:@[@"0.50×", @"0.65×", @"0.80×", @"1.00×"]];
    self.wallpaperPlaybackRateControl.selectedSegmentTintColor = UIColor.clearColor;
    self.wallpaperPlaybackRateControl.backgroundColor = UIColor.clearColor;
    self.wallpaperPlaybackRateControl.apportionsSegmentWidthsByContent = NO;
    self.wallpaperPlaybackRateControl.accessibilityLabel = @"动态壁纸速度";

    UIImage *speedNormalImage = DOCustomGlassSolidImage(UIColor.clearColor);
    UIImage *speedSelectedImage = DOCustomGlassSolidImage(UIColor.clearColor);
    UIImage *speedDividerImage = DOCustomGlassSolidImage(UIColor.clearColor);
    [self.wallpaperPlaybackRateControl setBackgroundImage:speedNormalImage
                                                 forState:UIControlStateNormal
                                               barMetrics:UIBarMetricsDefault];
    [self.wallpaperPlaybackRateControl setBackgroundImage:speedSelectedImage
                                                 forState:UIControlStateSelected
                                               barMetrics:UIBarMetricsDefault];
    [self.wallpaperPlaybackRateControl setDividerImage:speedDividerImage
                                   forLeftSegmentState:UIControlStateNormal
                                     rightSegmentState:UIControlStateNormal
                                            barMetrics:UIBarMetricsDefault];
    [self.wallpaperPlaybackRateControl setDividerImage:speedDividerImage
                                   forLeftSegmentState:UIControlStateSelected
                                     rightSegmentState:UIControlStateNormal
                                            barMetrics:UIBarMetricsDefault];
    [self.wallpaperPlaybackRateControl setDividerImage:speedDividerImage
                                   forLeftSegmentState:UIControlStateNormal
                                     rightSegmentState:UIControlStateSelected
                                            barMetrics:UIBarMetricsDefault];
    [self.wallpaperPlaybackRateControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1.0 alpha:0.68],
        NSFontAttributeName : [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]
    } forState:UIControlStateNormal];
    [self.wallpaperPlaybackRateControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSFontAttributeName : [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold]
    } forState:UIControlStateSelected];
    [self.wallpaperPlaybackRateControl addTarget:self
                                          action:@selector(wallpaperPlaybackRateChanged:)
                                forControlEvents:UIControlEventValueChanged];

    CGFloat persistedPlaybackRate = [defaults objectForKey:DOCustomGlassWallpaperPlaybackRateKey] ?
        [defaults floatForKey:DOCustomGlassWallpaperPlaybackRateKey] :
        DOCustomGlassWallpaperPlaybackRateDefault;
    self.wallpaperPlaybackRateControl.selectedSegmentIndex =
        DOCustomGlassPlaybackRateSegmentIndex(persistedPlaybackRate);
    self.wallpaperPlaybackRateRow =
        [self appearanceSegmentedRowWithTitle:@"动态壁纸速度"
                                     subtitle:@"视频 / Live Photo 的播放速度"
                                      control:self.wallpaperPlaybackRateControl];
    self.wallpaperPlaybackRateRow.hidden = ![self.navigationController customGlassIsUsingVideoWallpaper];
    [controlsStack addArrangedSubview:self.wallpaperPlaybackRateRow];

    self.glassBlurSlider = [self appearanceSlider];
    self.glassBlurSlider.minimumValue = 0.0;
    self.glassBlurSlider.maximumValue = 1.0;
    self.glassBlurSlider.value = [defaults floatForKey:DOCustomGlassBlurIntensityKey];
    self.glassBlurValueLabel = [self appearanceValueLabel];
    [controlsStack addArrangedSubview:[self appearanceControlRowWithTitle:@"Glass 模糊"
                                                                 subtitle:@"玻璃自身的模糊强度"
                                                                   slider:self.glassBlurSlider
                                                               valueLabel:self.glassBlurValueLabel]];

    self.glassTransparencySlider = [self appearanceSlider];
    self.glassTransparencySlider.minimumValue = 0.0;
    self.glassTransparencySlider.maximumValue = 1.0;
    self.glassTransparencySlider.value = [defaults floatForKey:DOCustomGlassTransparencyKey];
    self.glassTransparencyValueLabel = [self appearanceValueLabel];
    [controlsStack addArrangedSubview:[self appearanceControlRowWithTitle:@"Glass 透明度"
                                                                 subtitle:@"越高越通透"
                                                                   slider:self.glassTransparencySlider
                                                               valueLabel:self.glassTransparencyValueLabel]];

    self.glassTintSlider = [self appearanceSlider];
    self.glassTintSlider.minimumValue = 0.0;
    self.glassTintSlider.maximumValue = 0.16;
    self.glassTintSlider.value = [defaults floatForKey:DOCustomGlassTintAlphaKey];
    self.glassTintValueLabel = [self appearanceValueLabel];
    [controlsStack addArrangedSubview:[self appearanceControlRowWithTitle:@"Glass 高光"
                                                                 subtitle:@"玻璃表面的白色高光强度"
                                                                   slider:self.glassTintSlider
                                                               valueLabel:self.glassTintValueLabel]];

    UIButtonConfiguration *resetConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    resetConfiguration.title = @"恢复推荐值";
    resetConfiguration.image = [UIImage systemImageNamed:@"arrow.counterclockwise"];
    resetConfiguration.imagePadding = 7.0;
    resetConfiguration.baseForegroundColor = [UIColor colorWithWhite:1.0 alpha:0.86];

    UIButton *resetButton = [UIButton buttonWithConfiguration:resetConfiguration
                                                primaryAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf restoreRecommendedAppearanceValues];
    }]];
    [controlsStack addArrangedSubview:resetButton];
    [resetButton.heightAnchor constraintEqualToConstant:38.0].active = YES;

    UIScreenEdgePanGestureRecognizer *edgeBackGesture =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdgeBackGesture:)];
    edgeBackGesture.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edgeBackGesture];

    [self applyAppearancePreviewAndPersist:NO];
}

- (void)syncAppearanceControlsFromDefaults
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (self.glassAppearanceControl) {
        NSString *appearance = [defaults stringForKey:DOCustomGlassAppearanceKey];
        self.glassAppearanceControl.selectedSegmentIndex =
            [appearance isEqualToString:DOCustomGlassAppearanceDark] ? 1 : 0;
    }
    if (self.backgroundBlurSlider)
        self.backgroundBlurSlider.value = [defaults floatForKey:DOCustomGlassBackgroundBlurKey];
    if (self.glassBlurSlider)
        self.glassBlurSlider.value = [defaults floatForKey:DOCustomGlassBlurIntensityKey];
    if (self.glassTransparencySlider)
        self.glassTransparencySlider.value = [defaults floatForKey:DOCustomGlassTransparencyKey];
    if (self.glassTintSlider)
        self.glassTintSlider.value = [defaults floatForKey:DOCustomGlassTintAlphaKey];
    if (self.wallpaperPlaybackRateControl) {
        CGFloat playbackRate = [defaults objectForKey:DOCustomGlassWallpaperPlaybackRateKey] ?
            [defaults floatForKey:DOCustomGlassWallpaperPlaybackRateKey] :
            DOCustomGlassWallpaperPlaybackRateDefault;
        self.wallpaperPlaybackRateControl.selectedSegmentIndex =
            DOCustomGlassPlaybackRateSegmentIndex(playbackRate);
    }
    if (self.wallpaperPlaybackRateRow)
        self.wallpaperPlaybackRateRow.hidden = ![self.navigationController customGlassIsUsingVideoWallpaper];
}

- (void)refreshThemePageFromPersistedState
{
    [self syncAppearanceControlsFromDefaults];
    [self applyAppearancePreviewAndPersist:NO];

    // Force a full layout/display pass after the background image and all
    // CABackdropLayer filters are rebuilt. This is intentionally shared by
    // first presentation, repeated navigation entries and post-picker refresh.
    [self refreshLiquidGlassInView:self.view];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    DOCustomGlassApplyAdaptiveForeground(self.navigationController, self.view);
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshThemePageFromPersistedState];

    // One deferred local-material pass is enough after the transition attaches
    // these Glass layers. Do not run wallpaper decode/blur a second time.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf refreshLiquidGlassInView:weakSelf.view];
        [weakSelf.view setNeedsLayout];
        [weakSelf.view layoutIfNeeded];
    });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
}

- (void)glassAppearanceChanged:(UISegmentedControl *)control
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *appearance = control.selectedSegmentIndex == 1 ?
        DOCustomGlassAppearanceDark : DOCustomGlassAppearanceLight;

    [defaults setObject:appearance forKey:DOCustomGlassAppearanceKey];
    [defaults synchronize];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:DOCustomGlassThemeDidChangeNotification object:nil];

    [self refreshLiquidGlassInView:self.view];
    DOCustomGlassApplyAdaptiveForeground(self.navigationController, self.view);
}

- (void)appearanceSliderChanged:(UISlider *)slider
{
    [self applyAppearancePreviewAndPersist:YES];
}

- (void)wallpaperPlaybackRateChanged:(UISegmentedControl *)control
{
    CGFloat playbackRate = DOCustomGlassPlaybackRateForSegmentIndex(control.selectedSegmentIndex);
    [self.navigationController customGlassSetWallpaperPlaybackRate:playbackRate];
}

- (void)applyAppearancePreviewAndPersist:(BOOL)persist
{
    CGFloat backgroundBlur = self.backgroundBlurSlider.value;
    CGFloat glassBlur = self.glassBlurSlider.value;
    CGFloat transparency = self.glassTransparencySlider.value;
    CGFloat tintAlpha = self.glassTintSlider.value;

    [self.navigationController customGlassApplySharedBackgroundBlurIntensity:backgroundBlur];

    if (persist) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setFloat:backgroundBlur forKey:DOCustomGlassBackgroundBlurKey];
        [defaults setFloat:glassBlur forKey:DOCustomGlassBlurIntensityKey];
        [defaults setFloat:transparency forKey:DOCustomGlassTransparencyKey];
        [defaults setFloat:tintAlpha forKey:DOCustomGlassTintAlphaKey];
        [defaults synchronize];

        // DOMainViewController stays alive underneath this pushed settings page.
        // Notify it immediately so its already-created Glass surfaces consume
        // the same values now, rather than depending only on navigation timing.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DOCustomGlassThemeDidChangeNotification object:nil];
    }

    // Refresh every glass surface on this page, including the Background row
    // and the live controls panel, from the exact same persisted parameters the
    // home screen will read when it becomes visible again.
    [self refreshLiquidGlassInView:self.view];
    DOCustomGlassApplyAdaptiveForeground(self.navigationController, self.view);

    self.backgroundBlurValueLabel.text = [NSString stringWithFormat:@"%.0f%%", backgroundBlur * 100.0];
    self.glassBlurValueLabel.text = [NSString stringWithFormat:@"%.0f%%", glassBlur * 100.0];
    self.glassTransparencyValueLabel.text = [NSString stringWithFormat:@"%.0f%%", transparency * 100.0];
    self.glassTintValueLabel.text = [NSString stringWithFormat:@"%.0f%%", (tintAlpha / 0.16) * 100.0];
}

- (void)restoreRecommendedAppearanceValues
{
    self.glassAppearanceControl.selectedSegmentIndex = 0;
    self.backgroundBlurSlider.value = 0.10;
    self.glassBlurSlider.value = 0.85;
    self.glassTransparencySlider.value = 0.70;
    self.glassTintSlider.value = 0.05;
    if (self.wallpaperPlaybackRateControl)
        self.wallpaperPlaybackRateControl.selectedSegmentIndex = 1;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:DOCustomGlassAppearanceLight forKey:DOCustomGlassAppearanceKey];
    [self.navigationController customGlassSetWallpaperPlaybackRate:DOCustomGlassWallpaperPlaybackRateDefault];

    [self applyAppearancePreviewAndPersist:YES];
}

- (void)handleEdgeBackGesture:(UIScreenEdgePanGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded)
        return;

    CGPoint translation = [gesture translationInView:self.view];
    CGPoint velocity = [gesture velocityInView:self.view];
    if (translation.x > 70.0 && velocity.x > 100.0)
        [self.navigationController popViewControllerAnimated:YES];
}

- (void)dealloc
{
}

@end

@interface DOMainViewController () <PHPickerViewControllerDelegate>

@property DOJailbreakButton *jailbreakBtn;
@property NSArray<NSLayoutConstraint *> *jailbreakButtonConstraints;
@property DOActionMenuButton *updateButton;
@property NSLayoutConstraint *customGlassJailbreakCenterYConstraint;
@property UIImageView *customGlassBackgroundImageView;
@property DOCustomWallpaperBlurView *customGlassBackgroundBlurView;
@property UIImageView *customGlassAvatarPhotoView;
@property(nonatomic, strong) UIView *customGlassAvatarContainerView;
@property(nonatomic, strong) DOCustomLiquidGlassView *customGlassAvatarMaterialView;
@property(nonatomic, strong) UIImageView *customGlassAvatarFallbackIconView;
@property(nonatomic, strong) NSArray<UILabel *> *customGlassHeaderSubtitleLabels;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarIconWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarIconHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarCenterXConstraint;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarLeadingDockConstraint;
@property(nonatomic, strong) NSLayoutConstraint *customGlassAvatarTrailingDockConstraint;
@property(nonatomic, assign) CGFloat customGlassAvatarNormalSize;
@property(nonatomic, assign) CGFloat customGlassAvatarFocusSize;
@property(nonatomic, assign) BOOL customGlassProfileFocusEnabled;
@property(nonatomic, assign) BOOL customGlassProfileFocusDockRight;
@property UILabel *customGlassUsernameLabel;
@property UIAlertController *customGlassUsernameEditor;
@property UILabel *customGlassMottoLabel;
@property UIAlertController *customGlassMottoEditor;
@property DOCustomLiquidGlassView *customGlassThemeCard;
@property DOCustomGlassRefractionView *customGlassJailbreakRefractionView;
@property UILabel *customGlassSystemLabel;
@property UIView *supporterOnlyHintView;
@property UITapGestureRecognizer *supporterOnlyDismissTapGesture;
@property(nonatomic) BOOL hideStatusBar;
@property(nonatomic) BOOL hideHomeIndicator;

@end

@implementation DOMainViewController

- (void)applyCustomGlassHomeAppearance
{
    // The navigation controller owns wallpaper source + blur. Home only updates
    // its local Glass materials from the persisted Glass controls.
    // Every home Glass surface is already mounted in self.view. Walking that
    // hierarchy makes Settings / About / Theme Settings / restart pills / the
    // restart shell / jailbreak emphasis all consume the same persisted values.
    [self refreshCustomGlassMaterialInView:self.view];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];

    // G02.R2A identity gate: reproduce the exact Navigation backdrop inside the
    // Metal capsule before any refraction is reintroduced. Pull the real scrim
    // layer state instead of duplicating its luminance/alpha algorithm.
    if (self.customGlassJailbreakRefractionView) {
        self.customGlassJailbreakRefractionView.wallpaperSamplingView =
            [self.navigationController customGlassBackgroundSamplingView];
        self.customGlassJailbreakRefractionView.wallpaperScrimSamplingView =
            [self.navigationController customGlassWallpaperScrimSamplingView];
        [self.customGlassJailbreakRefractionView
            setWallpaperScrimLocations:[self.navigationController customGlassCurrentWallpaperScrimLocations]
            alphas:[self.navigationController customGlassCurrentWallpaperScrimAlphas]];
        [self.customGlassJailbreakRefractionView
            setWallpaperImage:[self.navigationController customGlassCurrentDisplayedBackgroundImage]];
        [self.customGlassJailbreakRefractionView refreshRefraction];
    }

    DOCustomGlassApplyAdaptiveForeground(self.navigationController, self.view);
}

- (void)customGlassThemeDidChange:(NSNotification *)notification
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf customGlassThemeDidChange:notification];
        });
        return;
    }

    [self applyCustomGlassHomeAppearance];
}

- (void)refreshSupporterState
{
    BOOL verified = DORHSupporterIsVerified();
    if (self.customGlassThemeCard)
        self.customGlassThemeCard.alpha = verified ? 1.0 : 0.44;

    if (self.customGlassSystemLabel)
        self.customGlassSystemLabel.text = verified
            ? [NSString stringWithFormat:@"iOS %@ · Supporter", UIDevice.currentDevice.systemVersion]
            : [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
}

- (void)supporterLicenseDidChange:(NSNotification *)notification
{
    (void)notification;
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refreshSupporterState];
        });
        return;
    }
    [self refreshSupporterState];
}

- (void)dismissSupporterOnlyHint
{
    [self.supporterOnlyHintView removeFromSuperview];
    self.supporterOnlyHintView = nil;

    if (self.supporterOnlyDismissTapGesture) {
        [self.view removeGestureRecognizer:self.supporterOnlyDismissTapGesture];
        self.supporterOnlyDismissTapGesture = nil;
    }
}

- (void)supporterOnlyDismissTapped:(UITapGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateEnded)
        [self dismissSupporterOnlyHint];
}

- (void)showSupporterOnlyHint
{
    [self dismissSupporterOnlyHint];

    DOCustomLiquidGlassView *hint = [self customGlassViewWithCornerRadius:15.0 tintAlpha:0.070];
    hint.materialScale = 0.80;
    hint.userInteractionEnabled = NO;
    [hint reloadMaterial];
    [self.view addSubview:hint];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Supporter Only";
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    [hint.contentView addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [hint.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [hint.heightAnchor constraintEqualToConstant:46.0],
        [label.leadingAnchor constraintEqualToAnchor:hint.contentView.leadingAnchor constant:18.0],
        [label.trailingAnchor constraintEqualToAnchor:hint.contentView.trailingAnchor constant:-18.0],
        [label.centerYAnchor constraintEqualToAnchor:hint.contentView.centerYAnchor],
    ]];

    self.supporterOnlyHintView = hint;
    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(supporterOnlyDismissTapped:)];
    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];
    self.supporterOnlyDismissTapGesture = dismissTap;
}

- (void)presentCustomGlassAvatarPicker
{
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter imagesFilter];
    configuration.selectionLimit = 1;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    [picker dismissViewControllerAnimated:YES completion:nil];

    PHPickerResult *result = results.firstObject;
    if (!result)
        return;

    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class])
        return;

    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:UIImage.class
              completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        if (error || ![object isKindOfClass:UIImage.class])
            return;

        UIImage *image = (UIImage *)object;
        UIImage *persistedAvatar = nil;
        BOOL saved = DOCustomGlassMediaStoreSaveAvatar(image, &persistedAvatar);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!saved)
                return;

            // Show the exact object decoded back from the committed media file.
            weakSelf.customGlassAvatarPhotoView.image = persistedAvatar;
            weakSelf.customGlassAvatarPhotoView.hidden = NO;
        });
    }];
}

- (void)presentCustomGlassUsernameEditor
{
    NSString *currentUsername = self.customGlassUsernameLabel.text ?: @"";

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"用户名"
                                            message:[NSString stringWithFormat:@"%lu / %lu",
                                                     (unsigned long)currentUsername.length,
                                                     (unsigned long)DOCustomGlassUsernameCharacterLimit]
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentUsername;
        textField.placeholder = @"输入用户名";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        [textField addTarget:self
                      action:@selector(customGlassUsernameTextChanged:)
            forControlEvents:UIControlEventEditingChanged];
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__kindof UIAlertAction * _Nonnull action) {
        NSString *username = alert.textFields.firstObject.text ?: @"";
        if (username.length > DOCustomGlassUsernameCharacterLimit)
            username = [username substringToIndex:DOCustomGlassUsernameCharacterLimit];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:username forKey:DOCustomGlassUsernameKey];
        weakSelf.customGlassUsernameLabel.text = username.length > 0 ? username : @"RootHide User";
        weakSelf.customGlassUsernameEditor = nil;
    }]];

    self.customGlassUsernameEditor = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)customGlassUsernameTextChanged:(UITextField *)textField
{
    NSString *text = textField.text ?: @"";
    if (text.length > DOCustomGlassUsernameCharacterLimit) {
        text = [text substringToIndex:DOCustomGlassUsernameCharacterLimit];
        textField.text = text;
    }

    self.customGlassUsernameEditor.message =
        [NSString stringWithFormat:@"%lu / %lu",
         (unsigned long)text.length,
         (unsigned long)DOCustomGlassUsernameCharacterLimit];
}

- (void)presentCustomGlassMottoEditor
{
    NSString *currentMotto = self.customGlassMottoLabel.text ?: @"";

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"个性签名"
                                            message:[NSString stringWithFormat:@"%lu / %lu",
                                                     (unsigned long)currentMotto.length,
                                                     (unsigned long)DOCustomGlassMottoCharacterLimit]
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentMotto;
        textField.placeholder = @"输入个性签名";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        [textField addTarget:self
                      action:@selector(customGlassMottoTextChanged:)
            forControlEvents:UIControlEventEditingChanged];
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__kindof UIAlertAction * _Nonnull action) {
        NSString *motto = alert.textFields.firstObject.text ?: @"";
        if (motto.length > DOCustomGlassMottoCharacterLimit)
            motto = [motto substringToIndex:DOCustomGlassMottoCharacterLimit];

        [[NSUserDefaults standardUserDefaults] setObject:motto forKey:DOCustomGlassMottoKey];
        weakSelf.customGlassMottoLabel.text = motto.length > 0 ? motto : @"motto";
        weakSelf.customGlassMottoEditor = nil;
    }]];

    self.customGlassMottoEditor = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)customGlassMottoTextChanged:(UITextField *)textField
{
    NSString *text = textField.text ?: @"";
    if (text.length > DOCustomGlassMottoCharacterLimit) {
        text = [text substringToIndex:DOCustomGlassMottoCharacterLimit];
        textField.text = text;
    }

    self.customGlassMottoEditor.message =
        [NSString stringWithFormat:@"%lu / %lu",
         (unsigned long)text.length,
         (unsigned long)DOCustomGlassMottoCharacterLimit];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (DORHSupporterIsVerified())
        [self setupCustomGlassHome];
    else
        [self setupStack];
}

-(void)setupStack
{
    UIStackView *stackView = [[UIStackView alloc] init];
    [stackView setAxis:UILayoutConstraintAxisVertical];
    [stackView setAlignment:UIStackViewAlignmentTrailing];
    [stackView setDistribution:UIStackViewDistributionEqualSpacing];
    [stackView setTranslatesAutoresizingMaskIntoConstraints:NO];

    [self.view addSubview:stackView];


    int statusBarHeight = fmax(15, [[UIApplication sharedApplication] keyWindow].safeAreaInsets.top - 20);

    [NSLayoutConstraint activateConstraints:@[
        [stackView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:statusBarHeight],//-35
        [stackView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:[DOGlobalAppearance isHomeButtonDevice] ? 0.78 : 0.73]
    ]];

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
    {
        NSLayoutConstraint *relativeWidthConstraint = [stackView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8];
        relativeWidthConstraint.priority = UILayoutPriorityDefaultHigh;
        NSLayoutConstraint *maxWidthConstraint = [stackView.widthAnchor constraintLessThanOrEqualToConstant:UI_IPAD_MAX_WIDTH];
        maxWidthConstraint.priority = UILayoutPriorityRequired;

        [NSLayoutConstraint activateConstraints:@[
            relativeWidthConstraint,
            maxWidthConstraint,
            [stackView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor]
        ]];
    }
    else
    {
        [NSLayoutConstraint activateConstraints:@[
            [stackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:UI_PADDING],
            [stackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-UI_PADDING],
        ]];
    }

    //Header
    DOHeaderView *headerView = [[DOHeaderView alloc] initWithImage: [UIImage imageNamed:@"Dopamine"] subtitles: @[
        [DOGlobalAppearance mainSubtitleString:[[DOEnvironmentManager sharedManager] versionSupportString]],
        [DOGlobalAppearance secondarySubtitleString:DOLocalizedString(@"Credits_Made_By") withAlpha:0.8],
        [DOGlobalAppearance secondarySubtitleString:@" " withAlpha:0.8]
    ]];
    
    [stackView addArrangedSubview:headerView];

    [NSLayoutConstraint activateConstraints:@[
        [headerView.leadingAnchor constraintEqualToAnchor:stackView.leadingAnchor constant:5],
        [headerView.trailingAnchor constraintEqualToAnchor:stackView.trailingAnchor]
    ]];
    
    //Action Menu
    DOActionMenuView *actionView = [[DOActionMenuView alloc] initWithActions:@[
        [UIAction actionWithTitle:DOLocalizedString(@"Menu_Settings_Title") image:[UIImage systemImageNamed:@"gearshape" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"settings" handler:^(__kindof UIAction * _Nonnull action) {
            [self.navigationController pushViewController:[[DOSettingsController alloc] init] animated:YES];
        }],
        [UIAction actionWithTitle:DOLocalizedString(@"Menu_Restart_SpringBoard_Title") image:[UIImage systemImageNamed:@"arrow.clockwise" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"respring" handler:^(__kindof UIAction * _Nonnull action) {
            [self fadeToBlack:^{
                [[DOEnvironmentManager sharedManager] respring];
            }];
        }],
        [UIAction actionWithTitle:DOLocalizedString(@"Menu_Reboot_Userspace_Title") image:[UIImage systemImageNamed:@"arrow.clockwise.circle" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"reboot-userspace" handler:^(__kindof UIAction * _Nonnull action) {
            [self fadeToBlack:^{
                [[DOEnvironmentManager sharedManager] rebootUserspace];
            }];
        }],
        [UIAction actionWithTitle:DOLocalizedString(@"Menu_Reboot_Device_Title") image:[UIImage systemImageNamed:@"power" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"reboot-device" handler:^(__kindof UIAction * _Nonnull action) {
            UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Menu_Reboot_Device_Title") message:DOLocalizedString(@"Alert_Reboot_Device_Body") preferredStyle:UIAlertControllerStyleAlert];
            [confirmation addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
            [confirmation addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Reboot") style:UIAlertActionStyleDestructive handler:^(__kindof UIAlertAction * _Nonnull alertAction) {
                [self fadeToBlack:^{
                    [[DOEnvironmentManager sharedManager] reboot];
                }];
            }]];
            [self presentViewController:confirmation animated:YES completion:nil];
        }],
        [UIAction actionWithTitle:DOLocalizedString(@"Menu_Credits_Title") image:[UIImage systemImageNamed:@"info.circle" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"credits" handler:^(__kindof UIAction * _Nonnull action) {
            [self.navigationController pushViewController:[[DOCreditsViewController alloc] init] animated:YES];
        }]
    ] delegate:self];
    
    [stackView addArrangedSubview: actionView];

    [NSLayoutConstraint activateConstraints:@[
        [actionView.leadingAnchor constraintEqualToAnchor:stackView.leadingAnchor],
        [actionView.trailingAnchor constraintEqualToAnchor:stackView.trailingAnchor],
    ]];
    
    
    UIView *buttonPlaceHolder = [[UIView alloc] init];
    [buttonPlaceHolder setTranslatesAutoresizingMaskIntoConstraints:NO];
    [stackView addArrangedSubview:buttonPlaceHolder];
    [NSLayoutConstraint activateConstraints:@[
        [buttonPlaceHolder.heightAnchor constraintEqualToConstant:60]
    ]];
    
    //Jailbreak Button
    BOOL isJailbroken = [[DOEnvironmentManager sharedManager] isJailbroken] || [[DOEnvironmentManager sharedManager] isJailbrokenWithOtherJailbreak];
    BOOL isSupported = [[DOEnvironmentManager sharedManager] isSupported];

    NSString *jailbreakButtonTitle = [self jailbreakButtonTitle];
        
    UIImage *jailbreakButtonImage;
    if (isSupported)
        jailbreakButtonImage = [UIImage systemImageNamed:@"lock.open" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]];
    else
        jailbreakButtonImage = [UIImage systemImageNamed:@"lock.slash" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]];
    
    self.jailbreakBtn = [[DOJailbreakButton alloc] initWithAction: [UIAction actionWithTitle:jailbreakButtonTitle image:jailbreakButtonImage identifier:@"jailbreak" handler:^(__kindof UIAction * _Nonnull action) {


/********************************** roothide specific ************************************/
        if(otherJailbreakActived(false)) {
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Error") message:DOLocalizedString(@"Your device currently has another jailbreak activated, please reboot device.") preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *rebootAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Close") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                //exit(0);
            }];
            [alertController addAction:rebootAction];
            [self presentViewController:alertController animated:YES completion:nil];
            return;
        }
/********************************** roothide specific ************************************/


        [actionView hide];
        [self.jailbreakBtn expandButton: self.jailbreakButtonConstraints];

        self.updateButton.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.75 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0  options: UIViewAnimationOptionCurveEaseInOut animations:^{
            [headerView setTransform:CGAffineTransformMakeTranslation(0, -25)];
            self.updateButton.alpha = 0;
        } completion:nil];
        
        [self startJailbreak];
        
    }]];
    self.jailbreakBtn.enabled = !isJailbroken && isSupported;

    [self.view addSubview:self.jailbreakBtn];

    [NSLayoutConstraint activateConstraints:(self.jailbreakButtonConstraints = @[
        [self.jailbreakBtn.leadingAnchor constraintEqualToAnchor:stackView.leadingAnchor],
        [self.jailbreakBtn.trailingAnchor constraintEqualToAnchor:stackView.trailingAnchor],
        [self.jailbreakBtn.heightAnchor constraintEqualToAnchor:buttonPlaceHolder.heightAnchor],
        [self.jailbreakBtn.centerYAnchor constraintEqualToAnchor:buttonPlaceHolder.centerYAnchor]
    ])];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        if ([[DOUIManager sharedInstance] environmentUpdateAvailable])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setupUpdateAvailable:YES];
            });
        }
        else if ([[DOUIManager sharedInstance] isUpdateAvailable])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setupUpdateAvailable:NO];
            });
        }
    });
}

#pragma mark - Custom Glass Home Prototype

- (DOCustomLiquidGlassView *)customGlassViewWithCornerRadius:(CGFloat)cornerRadius tintAlpha:(CGFloat)tintAlpha
{
    DOCustomLiquidGlassView *glassView =
        [[DOCustomLiquidGlassView alloc] initWithCornerRadius:cornerRadius baseTintAlpha:tintAlpha];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    return glassView;
}

- (void)refreshCustomGlassMaterialInView:(UIView *)view
{
    if ([view isKindOfClass:[DOCustomLiquidGlassView class]])
        [(DOCustomLiquidGlassView *)view reloadMaterial];

    for (UIView *subview in view.subviews)
        [self refreshCustomGlassMaterialInView:subview];
}

- (UIButton *)customGlassButtonWithTitle:(NSString *)title imageName:(NSString *)imageName action:(UIAction *)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;

    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    CGFloat symbolPointSize = isPad ? 21.0 : 19.0;
    UIImageSymbolConfiguration *symbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:symbolPointSize
                                                        weight:UIImageSymbolWeightMedium
                                                         scale:UIImageSymbolScaleMedium];
    configuration.image = [UIImage systemImageNamed:imageName withConfiguration:symbolConfiguration];
    configuration.imagePadding = 8;
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *incoming) {
        NSMutableDictionary *attributes = [incoming mutableCopy];
        attributes[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return attributes;
    };
    button.configuration = configuration;
    [button addAction:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (DOCustomLiquidGlassView *)customGlassCardWithTitle:(NSString *)title imageName:(NSString *)imageName action:(UIAction *)action
{
    DOCustomLiquidGlassView *card = [self customGlassViewWithCornerRadius:24 tintAlpha:0.05];
    // Settings / About / Theme Settings consume the same Main Glass profile
    // used by the Theme Settings preview and the compact jailbreak bar.
    DOCustomGlassApplyMainMaterialProfile(card);
    [card reloadMaterial];
    UIButton *button = [self customGlassButtonWithTitle:title imageName:imageName action:action];
    [card.contentView addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor]
    ]];
    return card;
}

- (DOCustomLiquidGlassView *)customGlassRestartButtonWithTitle:(NSString *)title imageName:(NSString *)imageName action:(UIAction *)action enabled:(BOOL)enabled cornerRadius:(CGFloat)cornerRadius
{
    DOCustomLiquidGlassView *innerGlass = [self customGlassViewWithCornerRadius:cornerRadius tintAlpha:0.0];
    // Inset Glass role. The restart platter owns the only real backdrop pass;
    // each action is just a shallow local surface on that shared glass plane.
    // Keep a small body/contour for touch hierarchy, but intentionally avoid the
    // second full-strength rim that previously made these read as three separate lenses.
    innerGlass.materialScale = 0.70;
    innerGlass.materialBodyScale = 0.24;
    innerGlass.materialOpticalScale = 0.36;
    innerGlass.materialBackdropScale = 0.0;
    innerGlass.materialSpecularScale = 0.48;
    innerGlass.materialEdgeDarkScale = 0.58;
    innerGlass.suppressBackdrop = YES;
    [innerGlass reloadMaterial];

    // Keep all restart actions on one shared icon/text grid. On iPhone the
    // content uses almost the full pill width so the longest localized title
    // does not get squeezed by the old 72% centered content constraint.
    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    CGFloat iconSize = isPad ? 24.0 : 21.0;
    CGFloat iconToTitleSpacing = isPad ? 10.0 : 8.0;

    UIView *contentRow = [[UIView alloc] init];
    contentRow.translatesAutoresizingMaskIntoConstraints = NO;
    [innerGlass.contentView addSubview:contentRow];

    CGFloat restartSymbolPointSize = isPad ? 23.0 : 20.0;
    UIImageSymbolConfiguration *restartSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:restartSymbolPointSize
                                                        weight:UIImageSymbolWeightMedium
                                                         scale:UIImageSymbolScaleMedium];

    // SF Symbols have different intrinsic visual mass even inside identical
    // image-view frames. Apply tiny optical corrections so the three restart
    // glyphs read as the same apparent size without changing their alignment.
    CGFloat restartIconOpticalScale = 1.0;
    if ([imageName isEqualToString:@"arrow.clockwise"]) {
        restartIconOpticalScale = 1.04;
    }
    else if ([imageName isEqualToString:@"arrow.clockwise.circle"]) {
        restartIconOpticalScale = 1.06;
    }
    else if ([imageName isEqualToString:@"power"]) {
        restartIconOpticalScale = 0.96;
    }

    UIImageView *iconView = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:imageName withConfiguration:restartSymbolConfiguration]];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tintColor = UIColor.whiteColor;
    iconView.alpha = enabled ? 1.0 : 0.46;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.transform = CGAffineTransformMakeScale(restartIconOpticalScale, restartIconOpticalScale);
    [contentRow addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.alpha = enabled ? 1.0 : 0.46;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    titleLabel.numberOfLines = 1;
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.94;
    titleLabel.allowsDefaultTighteningForTruncation = YES;
    [contentRow addSubview:titleLabel];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.enabled = enabled;
    button.accessibilityLabel = title;
    [button addAction:action forControlEvents:UIControlEventTouchUpInside];
    [innerGlass.contentView addSubview:button];

    NSMutableArray<NSLayoutConstraint *> *contentConstraints = [NSMutableArray arrayWithArray:@[
        [contentRow.centerYAnchor constraintEqualToAnchor:innerGlass.contentView.centerYAnchor],
        [contentRow.heightAnchor constraintEqualToConstant:28],

        [iconView.leadingAnchor constraintEqualToAnchor:contentRow.leadingAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:contentRow.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:iconSize],
        [iconView.heightAnchor constraintEqualToConstant:iconSize],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:iconToTitleSpacing],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:contentRow.trailingAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:contentRow.centerYAnchor],

        [button.leadingAnchor constraintEqualToAnchor:innerGlass.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:innerGlass.contentView.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:innerGlass.contentView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:innerGlass.contentView.bottomAnchor]
    ]];

    if (isPad) {
        [contentConstraints addObjectsFromArray:@[
            [contentRow.centerXAnchor constraintEqualToAnchor:innerGlass.contentView.centerXAnchor],
            [contentRow.widthAnchor constraintEqualToAnchor:innerGlass.contentView.widthAnchor multiplier:0.72]
        ]];
    }
    else {
        [contentConstraints addObjectsFromArray:@[
            [contentRow.leadingAnchor constraintEqualToAnchor:innerGlass.contentView.leadingAnchor constant:18.0],
            [contentRow.trailingAnchor constraintEqualToAnchor:innerGlass.contentView.trailingAnchor constant:-12.0]
        ]];
    }

    [NSLayoutConstraint activateConstraints:contentConstraints];
    return innerGlass;
}

- (void)setCustomGlassProfileFocusEnabled:(BOOL)enabled
                                 dockRight:(BOOL)dockRight
                                  animated:(BOOL)animated
                                   persist:(BOOL)persist
{
    if (!self.customGlassAvatarContainerView)
        return;

    self.customGlassProfileFocusEnabled = enabled;
    self.customGlassProfileFocusDockRight = dockRight;

    if (persist) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:enabled forKey:DOCustomGlassProfileFocusEnabledKey];
        [defaults setBool:dockRight forKey:DOCustomGlassProfileFocusDockRightKey];
    }

    [self.view layoutIfNeeded];

    if (enabled) {
        self.customGlassAvatarCenterXConstraint.active = NO;
        self.customGlassAvatarLeadingDockConstraint.active = !dockRight;
        self.customGlassAvatarTrailingDockConstraint.active = dockRight;
    }
    else {
        self.customGlassAvatarLeadingDockConstraint.active = NO;
        self.customGlassAvatarTrailingDockConstraint.active = NO;
        self.customGlassAvatarCenterXConstraint.active = YES;
    }

    CGFloat avatarSize = enabled ? self.customGlassAvatarFocusSize : self.customGlassAvatarNormalSize;
    CGFloat avatarIconSize = avatarSize * 0.62;
    self.customGlassAvatarWidthConstraint.constant = avatarSize;
    self.customGlassAvatarHeightConstraint.constant = avatarSize;
    self.customGlassAvatarIconWidthConstraint.constant = avatarIconSize;
    self.customGlassAvatarIconHeightConstraint.constant = avatarIconSize;

    // Focus mode is a small translucent Liquid Glass lens instead of an opaque
    // profile sticker. Keep the photo readable, but let the live wallpaper/video
    // transmit through it so the docked avatar belongs to the same material family.
    DOCustomLiquidGlassView *avatarMaterial = self.customGlassAvatarMaterialView;
    if (avatarMaterial) {
        avatarMaterial.preferredCornerRadius = avatarSize / 2.0;
        avatarMaterial.materialScale = enabled ? 0.70 : 0.46;
        avatarMaterial.materialBodyScale = enabled ? 0.68 : 0.34;
        avatarMaterial.materialOpticalScale = enabled ? 0.82 : 0.52;
        avatarMaterial.materialBackdropScale = enabled ? 0.78 : 0.34;
        avatarMaterial.materialSpecularScale = enabled ? 1.00 : 0.54;
        avatarMaterial.materialEdgeDarkScale = enabled ? 0.38 : 0.42;
        avatarMaterial.suppressBackdrop = NO;
        [avatarMaterial reloadMaterial];
    }

    self.customGlassAvatarContainerView.accessibilityLabel = enabled ? @"恢复个人资料" : @"更换头像";
    self.customGlassUsernameLabel.userInteractionEnabled = !enabled;
    self.customGlassMottoLabel.userInteractionEnabled = !enabled;

    void (^updates)(void) = ^{
        self.customGlassAvatarContainerView.transform = CGAffineTransformIdentity;
        self.customGlassAvatarContainerView.layer.cornerRadius = avatarSize / 2.0;
        self.customGlassAvatarContainerView.layer.shadowOpacity = enabled ? 0.035 : 0.16;
        self.customGlassAvatarContainerView.layer.shadowRadius = enabled ? 4.0 : 6.0;
        self.customGlassAvatarPhotoView.layer.cornerRadius = MAX(0.0, (avatarSize - 2.0) / 2.0);
        self.customGlassAvatarPhotoView.alpha = enabled ? 0.34 : 1.0;
        self.customGlassAvatarFallbackIconView.alpha = enabled ? 0.44 : 1.0;

        CGFloat detailAlpha = enabled ? 0.0 : 1.0;
        self.customGlassUsernameLabel.alpha = detailAlpha;
        self.customGlassSystemLabel.alpha = detailAlpha;
        self.customGlassMottoLabel.alpha = detailAlpha;
        for (UILabel *label in self.customGlassHeaderSubtitleLabels)
            label.alpha = detailAlpha;

        [self.view layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.26
                              delay:0.0
             usingSpringWithDamping:0.88
              initialSpringVelocity:0.35
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:updates
                         completion:nil];
    }
    else {
        updates();
    }
}

- (void)customGlassAvatarTapped:(UITapGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded)
        return;

    if (self.customGlassProfileFocusEnabled) {
        [self setCustomGlassProfileFocusEnabled:NO
                                      dockRight:self.customGlassProfileFocusDockRight
                                       animated:YES
                                        persist:YES];
        return;
    }

    [self presentCustomGlassAvatarPicker];
}

- (void)customGlassAvatarPanned:(UIPanGestureRecognizer *)gesture
{
    UIView *avatarView = self.customGlassAvatarContainerView;
    if (!avatarView)
        return;

    CGPoint translation = [gesture translationInView:self.view];
    CGPoint velocity = [gesture velocityInView:self.view];

    // Docking is deliberately edge-gated: the avatar follows the finger all the
    // way to a real screen edge, and only becomes Focus when it actually reaches
    // the magnetic edge zone. A quick short flick near the center never docks.
    CGRect screenFrame = self.view.bounds;
    CGPoint avatarCenter = [avatarView.superview convertPoint:avatarView.center toView:self.view];
    // Dock by the avatar's *center* against the physical view edge. Roughly 30%
    // of the compact Focus avatar is allowed to sit outside the screen so it reads
    // as an edge tab instead of a floating badge with an inset margin.
    CGFloat focusPeekCenter = MAX(8.0, self.customGlassAvatarFocusSize * 0.20);
    CGFloat leftTargetX = CGRectGetMinX(screenFrame) + focusPeekCenter;
    CGFloat rightTargetX = CGRectGetMaxX(screenFrame) - focusPeekCenter;
    CGFloat leftTravel = leftTargetX - avatarCenter.x;
    CGFloat rightTravel = rightTargetX - avatarCenter.x;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat drag = translation.x;
        if (self.customGlassProfileFocusEnabled) {
            BOOL towardCenter = self.customGlassProfileFocusDockRight ? (drag < 0.0) : (drag > 0.0);
            drag *= towardCenter ? 0.72 : 0.10;
        }
        else {
            drag = MAX(leftTravel, MIN(rightTravel, drag));
        }
        avatarView.transform = CGAffineTransformMakeTranslation(drag, 0.0);
        return;
    }

    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled &&
        gesture.state != UIGestureRecognizerStateFailed)
        return;

    if (self.customGlassProfileFocusEnabled) {
        BOOL towardCenter = self.customGlassProfileFocusDockRight ?
            (translation.x < 0.0) : (translation.x > 0.0);
        BOOL shouldRestore = towardCenter &&
            (fabs(translation.x) >= 28.0 || fabs(velocity.x) >= 360.0);
        if (shouldRestore) {
            [self setCustomGlassProfileFocusEnabled:NO
                                          dockRight:self.customGlassProfileFocusDockRight
                                           animated:YES
                                            persist:YES];
        }
        else {
            [UIView animateWithDuration:0.20
                             animations:^{ avatarView.transform = CGAffineTransformIdentity; }];
        }
        return;
    }

    CGFloat edgeMagnet = 14.0;
    BOOL reachedLeftEdge = translation.x <= (leftTravel + edgeMagnet);
    BOOL reachedRightEdge = translation.x >= (rightTravel - edgeMagnet);
    if (!reachedLeftEdge && !reachedRightEdge) {
        [UIView animateWithDuration:0.22
                              delay:0.0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.25
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ avatarView.transform = CGAffineTransformIdentity; }
                         completion:nil];
        return;
    }

    [self setCustomGlassProfileFocusEnabled:YES
                                  dockRight:reachedRightEdge
                                   animated:YES
                                    persist:YES];
}

- (void)configureCustomGlassHeaderView:(DOHeaderView *)headerView logoHeight:(CGFloat)logoHeight subtitleScale:(CGFloat)subtitleScale
{
    // Keep the Dopamine logo centered, but present version / author / uptime as
    // one compact left-aligned information block centered beneath the logo.
    UIStackView *headerStack = nil;
    for (UIView *subview in headerView.subviews) {
        if ([subview isKindOfClass:[UIStackView class]]) {
            headerStack = (UIStackView *)subview;
            break;
        }
    }

    if (!headerStack)
        return;

    headerStack.alignment = UIStackViewAlignmentCenter;
    headerStack.spacing = 2.0;

    NSMutableArray<UILabel *> *subtitleLabels = [NSMutableArray array];
    CGFloat subtitleWidth = 0.0;

    for (UIView *arrangedSubview in headerStack.arrangedSubviews) {
        if ([arrangedSubview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)arrangedSubview;
            label.textAlignment = NSTextAlignmentLeft;
            if (subtitleScale != 1.0) {
                label.font = [label.font fontWithSize:(label.font.pointSize * subtitleScale)];
            }
            [subtitleLabels addObject:label];
            subtitleWidth = MAX(subtitleWidth, ceil(label.intrinsicContentSize.width));
        }
        else if ([arrangedSubview isKindOfClass:[UIImageView class]]) {
            UIImageView *logoView = (UIImageView *)arrangedSubview;
            for (NSLayoutConstraint *constraint in logoView.constraints) {
                if (constraint.firstAttribute == NSLayoutAttributeHeight &&
                    constraint.relation == NSLayoutRelationEqual) {
                    constraint.constant = logoHeight;
                    break;
                }
            }
        }
    }

    // Giving all subtitle labels the width of the widest line keeps their left
    // edges on the same vertical axis while the block itself stays centered.
    if (subtitleWidth > 0.0) {
        for (UILabel *label in subtitleLabels) {
            [label.widthAnchor constraintEqualToConstant:subtitleWidth].active = YES;
        }
    }
}

- (void)setupCustomGlassHome
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(customGlassThemeDidChange:)
                                                 name:DOCustomGlassThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(supporterLicenseDidChange:)
                                                 name:DORHSupporterLicenseDidChangeNotification
                                               object:nil];

    // Shared wallpaper/blur lives below the navigation transition container.
    // Home only owns foreground content and Glass surfaces.

    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    CGFloat availableHeight = CGRectGetHeight(self.view.bounds);
    BOOL compactLayout = !isPad && availableHeight < 720.0;

    // Keep one visual structure on every device. Only dimensions change so the
    // reference layout remains intact on compact iPhones, regular iPhones and iPad.
    CGFloat mainSpacing = compactLayout ? 8.0 : 12.0;
    CGFloat topInset = isPad ? 24.0 : (compactLayout ? 6.0 : 10.0);
    CGFloat horizontalInset = compactLayout ? 20.0 : 25.0;
    CGFloat headerToProfileSpacing = isPad ? 29.0 : (compactLayout ? 14.0 : 18.0);
    CGFloat logoHeight = isPad ? 55.0 : (compactLayout ? 39.0 : 40.0);
    CGFloat headerSubtitleScale = isPad ? 1.09 : (compactLayout ? 0.93 : 0.95);
    CGFloat avatarSize = isPad ? 104.0 : (compactLayout ? 72.0 : 84.0);
    CGFloat avatarIconSize = avatarSize * 0.62;
    CGFloat gridDrop = isPad ? 14.0 : (compactLayout ? 6.0 : 8.0);
    CGFloat profileToGridSpacing = (isPad ? 15.0 : (compactLayout ? 15.0 : 18.0)) + gridDrop;
    CGFloat gridHeight = isPad ? 300.0 : (compactLayout ? 214.0 : 250.0);
    CGFloat themeCardHeight = isPad ? 60.0 : (compactLayout ? 48.0 : 52.0);
    CGFloat restartPadding = isPad ? 14.0 : (compactLayout ? 10.0 : 12.0);
    CGFloat restartSpacing = isPad ? 12.0 : (compactLayout ? 8.0 : 10.0);
    CGFloat restartContainerHeight = gridHeight - themeCardHeight - mainSpacing;
    CGFloat restartButtonHeight = (restartContainerHeight - (restartPadding * 2.0) - (restartSpacing * 2.0)) / 3.0;
    CGFloat restartCornerRadius = restartButtonHeight / 2.0;
    CGFloat usernameFontSize = isPad ? 24.0 : (compactLayout ? 16.0 : 19.0);
    CGFloat systemFontSize = isPad ? 18.0 : (compactLayout ? 12.0 : 15.0);
    CGFloat mottoFontSize = isPad ? 21.0 : (compactLayout ? 13.0 : 16.0);
    CGFloat avatarToUsernameSpacing = isPad ? 12.0 : (compactLayout ? 9.0 : 10.0);
    CGFloat usernameToSystemSpacing = isPad ? 4.0 : (compactLayout ? 2.0 : 3.0);
    CGFloat systemToMottoSpacing = isPad ? 12.0 : (compactLayout ? 9.0 : 10.0);
    CGFloat leftColumnWidthMultiplier = isPad ? 0.34 : 0.35;
    CGFloat jailbreakButtonHeight = isPad ? 60.0 : (compactLayout ? 44.0 : 48.0);
    CGFloat jailbreakVerticalOffset = isPad ? -12.0 : (compactLayout ? -24.0 : -30.0);
    CGFloat jailbreakHorizontalInset = isPad ? 0.0 : 4.0;

    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.alignment = UIStackViewAlignmentFill;
    mainStack.distribution = UIStackViewDistributionFill;
    mainStack.spacing = mainSpacing;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:mainStack];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    if (isPad) {
        NSLayoutConstraint *relativeWidthConstraint = [mainStack.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8];
        relativeWidthConstraint.priority = UILayoutPriorityDefaultHigh;
        NSLayoutConstraint *maxWidthConstraint = [mainStack.widthAnchor constraintLessThanOrEqualToConstant:UI_IPAD_MAX_WIDTH];
        maxWidthConstraint.priority = UILayoutPriorityRequired;

        NSLayoutConstraint *verticalPositionConstraint = [mainStack.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor constant:-10.0];
        verticalPositionConstraint.priority = UILayoutPriorityDefaultHigh;

        [NSLayoutConstraint activateConstraints:@[
            [mainStack.topAnchor constraintGreaterThanOrEqualToAnchor:safeArea.topAnchor constant:topInset],
            [mainStack.bottomAnchor constraintLessThanOrEqualToAnchor:safeArea.bottomAnchor constant:-12],
            [mainStack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            verticalPositionConstraint,
            relativeWidthConstraint,
            maxWidthConstraint
        ]];
    }
    else {
        NSLayoutConstraint *verticalPositionConstraint = [mainStack.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor];
        verticalPositionConstraint.priority = UILayoutPriorityDefaultHigh;

        [NSLayoutConstraint activateConstraints:@[
            [mainStack.topAnchor constraintGreaterThanOrEqualToAnchor:safeArea.topAnchor constant:topInset],
            [mainStack.bottomAnchor constraintLessThanOrEqualToAnchor:safeArea.bottomAnchor constant:-8],
            [mainStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:horizontalInset],
            [mainStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-horizontalInset],
            verticalPositionConstraint
        ]];
    }

    // Keep the original DOHeaderView so version/author/uptime retain Dopamine's
    // existing internal spacing and behavior. Custom Home only centers that stack
    // and gives the Dopamine logo slightly more visual weight.
    DOHeaderView *headerView = [[DOHeaderView alloc] initWithImage:[UIImage imageNamed:@"Dopamine"] subtitles:@[
        [DOGlobalAppearance mainSubtitleString:[[DOEnvironmentManager sharedManager] versionSupportString]],
        [DOGlobalAppearance secondarySubtitleString:DOLocalizedString(@"Credits_Made_By") withAlpha:0.8],
        [DOGlobalAppearance secondarySubtitleString:@" " withAlpha:0.8]
    ]];
    [self configureCustomGlassHeaderView:headerView logoHeight:logoHeight subtitleScale:headerSubtitleScale];

    NSMutableArray<UILabel *> *headerSubtitleLabels = [NSMutableArray array];
    for (UIView *subview in headerView.subviews) {
        if (![subview isKindOfClass:[UIStackView class]])
            continue;
        for (UIView *arrangedSubview in ((UIStackView *)subview).arrangedSubviews) {
            if ([arrangedSubview isKindOfClass:[UILabel class]])
                [headerSubtitleLabels addObject:(UILabel *)arrangedSubview];
        }
    }
    self.customGlassHeaderSubtitleLabels = headerSubtitleLabels;

    [mainStack addArrangedSubview:headerView];
    [mainStack setCustomSpacing:headerToProfileSpacing afterView:headerView];

    UIView *profileView = [[UIView alloc] init];
    profileView.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:profileView];
    [mainStack setCustomSpacing:profileToGridSpacing afterView:profileView];

    UIView *avatarGlass = [[UIView alloc] init];
    avatarGlass.translatesAutoresizingMaskIntoConstraints = NO;
    avatarGlass.backgroundColor = UIColor.clearColor;
    avatarGlass.layer.cornerRadius = avatarSize / 2.0;
    avatarGlass.layer.cornerCurve = kCACornerCurveContinuous;
    avatarGlass.layer.shadowColor = UIColor.blackColor.CGColor;
    avatarGlass.layer.shadowOpacity = 0.16;
    avatarGlass.layer.shadowRadius = 6.0;
    avatarGlass.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    // Keep the avatar as a root-view overlay rather than a child of profileView.
    // A subview outside profileView's bounds cannot reliably receive hit-testing;
    // placing it here lets the pan gesture reach and remain interactive at the
    // physical left/right screen edges while its Y position still follows profileView.
    [self.view addSubview:avatarGlass];
    self.customGlassAvatarContainerView = avatarGlass;
    self.customGlassAvatarNormalSize = avatarSize;
    self.customGlassAvatarFocusSize = isPad ? 58.0 : (compactLayout ? 46.0 : 50.0);

    self.customGlassAvatarWidthConstraint = [avatarGlass.widthAnchor constraintEqualToConstant:avatarSize];
    self.customGlassAvatarHeightConstraint = [avatarGlass.heightAnchor constraintEqualToConstant:avatarSize];
    self.customGlassAvatarCenterXConstraint = [avatarGlass.centerXAnchor constraintEqualToAnchor:profileView.centerXAnchor];
    // Focus is an edge tab: anchor the avatar center close to the physical screen
    // edge so part of the circle intentionally peeks offscreen. This is visually
    // quieter over video/Live Photo and removes the previous floating inset.
    CGFloat focusPeekCenter = MAX(8.0, self.customGlassAvatarFocusSize * 0.20);
    self.customGlassAvatarLeadingDockConstraint =
        [avatarGlass.centerXAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:focusPeekCenter];
    self.customGlassAvatarTrailingDockConstraint =
        [avatarGlass.centerXAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-focusPeekCenter];

    [NSLayoutConstraint activateConstraints:@[
        self.customGlassAvatarWidthConstraint,
        self.customGlassAvatarHeightConstraint,
        self.customGlassAvatarCenterXConstraint,
        [avatarGlass.topAnchor constraintEqualToAnchor:profileView.topAnchor]
    ]];

    DOCustomLiquidGlassView *avatarMaterial =
        [[DOCustomLiquidGlassView alloc] initWithCornerRadius:(avatarSize / 2.0) baseTintAlpha:0.03];
    avatarMaterial.translatesAutoresizingMaskIntoConstraints = NO;
    avatarMaterial.userInteractionEnabled = NO;
    avatarMaterial.materialScale = 0.46;
    avatarMaterial.materialBodyScale = 0.34;
    avatarMaterial.materialOpticalScale = 0.52;
    avatarMaterial.materialBackdropScale = 0.34;
    avatarMaterial.materialSpecularScale = 0.54;
    avatarMaterial.materialEdgeDarkScale = 0.42;
    [avatarGlass addSubview:avatarMaterial];
    self.customGlassAvatarMaterialView = avatarMaterial;
    [NSLayoutConstraint activateConstraints:@[
        [avatarMaterial.leadingAnchor constraintEqualToAnchor:avatarGlass.leadingAnchor],
        [avatarMaterial.trailingAnchor constraintEqualToAnchor:avatarGlass.trailingAnchor],
        [avatarMaterial.topAnchor constraintEqualToAnchor:avatarGlass.topAnchor],
        [avatarMaterial.bottomAnchor constraintEqualToAnchor:avatarGlass.bottomAnchor]
    ]];

    UIImageView *avatarImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.crop.circle.fill"]];
    avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    avatarImageView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    [avatarGlass addSubview:avatarImageView];
    self.customGlassAvatarFallbackIconView = avatarImageView;
    self.customGlassAvatarIconWidthConstraint = [avatarImageView.widthAnchor constraintEqualToConstant:avatarIconSize];
    self.customGlassAvatarIconHeightConstraint = [avatarImageView.heightAnchor constraintEqualToConstant:avatarIconSize];
    [NSLayoutConstraint activateConstraints:@[
        [avatarImageView.centerXAnchor constraintEqualToAnchor:avatarGlass.centerXAnchor],
        [avatarImageView.centerYAnchor constraintEqualToAnchor:avatarGlass.centerYAnchor],
        self.customGlassAvatarIconWidthConstraint,
        self.customGlassAvatarIconHeightConstraint
    ]];

    self.customGlassAvatarPhotoView = [[UIImageView alloc] init];
    self.customGlassAvatarPhotoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassAvatarPhotoView.contentMode = UIViewContentModeScaleAspectFill;
    self.customGlassAvatarPhotoView.clipsToBounds = YES;
    self.customGlassAvatarPhotoView.layer.cornerRadius = (avatarSize - 2.0) / 2.0;
    self.customGlassAvatarPhotoView.hidden = YES;
    [avatarGlass addSubview:self.customGlassAvatarPhotoView];

    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassAvatarPhotoView.leadingAnchor constraintEqualToAnchor:avatarGlass.leadingAnchor constant:1.0],
        [self.customGlassAvatarPhotoView.trailingAnchor constraintEqualToAnchor:avatarGlass.trailingAnchor constant:-1.0],
        [self.customGlassAvatarPhotoView.topAnchor constraintEqualToAnchor:avatarGlass.topAnchor constant:1.0],
        [self.customGlassAvatarPhotoView.bottomAnchor constraintEqualToAnchor:avatarGlass.bottomAnchor constant:-1.0]
    ]];

    UIImage *savedAvatar = DOCustomGlassMediaStoreLoadAvatar();
    if (savedAvatar) {
        self.customGlassAvatarPhotoView.image = savedAvatar;
        self.customGlassAvatarPhotoView.hidden = NO;
    }

    avatarGlass.userInteractionEnabled = YES;
    avatarGlass.isAccessibilityElement = YES;
    avatarGlass.accessibilityLabel = @"更换头像";
    [avatarGlass addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(customGlassAvatarTapped:)]];
    [avatarGlass addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(customGlassAvatarPanned:)]];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *username = [defaults stringForKey:DOCustomGlassUsernameKey];
    if (username.length == 0)
        username = @"RootHide User";
    NSString *motto = [defaults stringForKey:DOCustomGlassMottoKey];
    if (motto.length == 0)
        motto = @"motto";

    UILabel *usernameLabel = [[UILabel alloc] init];
    usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    usernameLabel.text = username;
    usernameLabel.textColor = UIColor.whiteColor;
    usernameLabel.textAlignment = NSTextAlignmentCenter;
    usernameLabel.font = [UIFont systemFontOfSize:usernameFontSize weight:UIFontWeightSemibold];
    usernameLabel.userInteractionEnabled = YES;
    usernameLabel.isAccessibilityElement = YES;
    usernameLabel.accessibilityLabel = @"编辑用户名";
    [usernameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(presentCustomGlassUsernameEditor)]];
    [profileView addSubview:usernameLabel];
    self.customGlassUsernameLabel = usernameLabel;

    UILabel *systemLabel = [[UILabel alloc] init];
    systemLabel.translatesAutoresizingMaskIntoConstraints = NO;
    systemLabel.text = [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
    systemLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    systemLabel.textAlignment = NSTextAlignmentCenter;
    systemLabel.font = [UIFont systemFontOfSize:systemFontSize weight:UIFontWeightMedium];
    [profileView addSubview:systemLabel];
    self.customGlassSystemLabel = systemLabel;

    UILabel *mottoLabel = [[UILabel alloc] init];
    mottoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    mottoLabel.text = motto;
    mottoLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    mottoLabel.textAlignment = NSTextAlignmentCenter;
    mottoLabel.font = [UIFont systemFontOfSize:mottoFontSize weight:UIFontWeightRegular];
    mottoLabel.numberOfLines = 2;
    mottoLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    mottoLabel.userInteractionEnabled = YES;
    mottoLabel.isAccessibilityElement = YES;
    mottoLabel.accessibilityLabel = @"编辑个性签名";
    [mottoLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(presentCustomGlassMottoEditor)]];
    [profileView addSubview:mottoLabel];
    self.customGlassMottoLabel = mottoLabel;

    NSLayoutConstraint *mottoMaxWidth = [mottoLabel.widthAnchor constraintLessThanOrEqualToAnchor:profileView.widthAnchor multiplier:0.78];
    mottoMaxWidth.priority = UILayoutPriorityRequired;

    [NSLayoutConstraint activateConstraints:@[
        [usernameLabel.topAnchor constraintEqualToAnchor:avatarGlass.bottomAnchor constant:avatarToUsernameSpacing],
        [usernameLabel.leadingAnchor constraintEqualToAnchor:profileView.leadingAnchor constant:12],
        [usernameLabel.trailingAnchor constraintEqualToAnchor:profileView.trailingAnchor constant:-12],
        [systemLabel.topAnchor constraintEqualToAnchor:usernameLabel.bottomAnchor constant:usernameToSystemSpacing],
        [systemLabel.leadingAnchor constraintEqualToAnchor:profileView.leadingAnchor constant:12],
        [systemLabel.trailingAnchor constraintEqualToAnchor:profileView.trailingAnchor constant:-12],
        [mottoLabel.topAnchor constraintEqualToAnchor:systemLabel.bottomAnchor constant:systemToMottoSpacing],
        [mottoLabel.centerXAnchor constraintEqualToAnchor:profileView.centerXAnchor],
        [mottoLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:profileView.leadingAnchor constant:18],
        [mottoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:profileView.trailingAnchor constant:-18],
        [mottoLabel.bottomAnchor constraintEqualToAnchor:profileView.bottomAnchor],
        mottoMaxWidth
    ]];

    UIView *actionGrid = [[UIView alloc] init];
    actionGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:actionGrid];
    NSLayoutConstraint *gridHeightConstraint = [actionGrid.heightAnchor constraintEqualToConstant:gridHeight];
    gridHeightConstraint.priority = UILayoutPriorityRequired;
    gridHeightConstraint.active = YES;

    UIStackView *leftColumn = [[UIStackView alloc] init];
    leftColumn.axis = UILayoutConstraintAxisVertical;
    leftColumn.alignment = UIStackViewAlignmentFill;
    leftColumn.distribution = UIStackViewDistributionFillEqually;
    leftColumn.spacing = mainSpacing;
    leftColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [actionGrid addSubview:leftColumn];

    UIStackView *rightColumn = [[UIStackView alloc] init];
    rightColumn.axis = UILayoutConstraintAxisVertical;
    rightColumn.alignment = UIStackViewAlignmentFill;
    rightColumn.distribution = UIStackViewDistributionFill;
    rightColumn.spacing = mainSpacing;
    rightColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [actionGrid addSubview:rightColumn];

    [NSLayoutConstraint activateConstraints:@[
        [leftColumn.leadingAnchor constraintEqualToAnchor:actionGrid.leadingAnchor],
        [leftColumn.topAnchor constraintEqualToAnchor:actionGrid.topAnchor],
        [leftColumn.bottomAnchor constraintEqualToAnchor:actionGrid.bottomAnchor],
        [leftColumn.widthAnchor constraintEqualToAnchor:actionGrid.widthAnchor multiplier:leftColumnWidthMultiplier],
        [rightColumn.leadingAnchor constraintEqualToAnchor:leftColumn.trailingAnchor constant:mainSpacing],
        [rightColumn.trailingAnchor constraintEqualToAnchor:actionGrid.trailingAnchor],
        [rightColumn.topAnchor constraintEqualToAnchor:actionGrid.topAnchor],
        [rightColumn.bottomAnchor constraintEqualToAnchor:actionGrid.bottomAnchor]
    ]];

    UIAction *settingsAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [self.navigationController pushViewController:[[DOSettingsController alloc] init] animated:YES];
    }];
    UIAction *creditsAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [self.navigationController pushViewController:[[DOCreditsViewController alloc] init] animated:YES];
    }];

    DOCustomLiquidGlassView *settingsCard = [self customGlassCardWithTitle:DOLocalizedString(@"Menu_Settings_Title") imageName:@"gearshape" action:settingsAction];
    DOCustomLiquidGlassView *creditsCard = [self customGlassCardWithTitle:DOLocalizedString(@"Menu_Credits_Title") imageName:@"info.circle" action:creditsAction];
    [leftColumn addArrangedSubview:settingsCard];
    [leftColumn addArrangedSubview:creditsCard];

    UIAction *themeAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        if (!DORHSupporterIsVerified()) {
            [self showSupporterOnlyHint];
            return;
        }

        DOCustomGlassThemeSettingsViewController *themeSettingsController =
            [[DOCustomGlassThemeSettingsViewController alloc] init];
        [themeSettingsController prepareForPresentation];
        [self.navigationController pushViewController:themeSettingsController animated:YES];
    }];
    DOCustomLiquidGlassView *themeCard = [self customGlassCardWithTitle:@"主题设置" imageName:@"slider.horizontal.3" action:themeAction];
    self.customGlassThemeCard = themeCard;
    themeCard.preferredCornerRadius = themeCardHeight / 2.0;
    themeCard.layer.cornerRadius = themeCard.preferredCornerRadius;
    [rightColumn addArrangedSubview:themeCard];
    [themeCard.heightAnchor constraintEqualToConstant:themeCardHeight].active = YES;
    [self refreshSupporterState];

    DOCustomLiquidGlassView *restartContainer = [self customGlassViewWithCornerRadius:24 tintAlpha:0.05];
    // Restart Outer is a true Main Glass surface. The three nested actions keep
    // their suppressBackdrop Inset role, so this does not introduce double blur.
    DOCustomGlassApplyMainMaterialProfile(restartContainer);
    [restartContainer reloadMaterial];
    [rightColumn addArrangedSubview:restartContainer];

    UIStackView *restartStack = [[UIStackView alloc] init];
    restartStack.axis = UILayoutConstraintAxisVertical;
    restartStack.alignment = UIStackViewAlignmentFill;
    restartStack.distribution = UIStackViewDistributionFillEqually;
    restartStack.spacing = restartSpacing;
    restartStack.translatesAutoresizingMaskIntoConstraints = NO;
    [restartContainer.contentView addSubview:restartStack];
    [NSLayoutConstraint activateConstraints:@[
        [restartStack.leadingAnchor constraintEqualToAnchor:restartContainer.contentView.leadingAnchor constant:restartPadding],
        [restartStack.trailingAnchor constraintEqualToAnchor:restartContainer.contentView.trailingAnchor constant:-restartPadding],
        [restartStack.topAnchor constraintEqualToAnchor:restartContainer.contentView.topAnchor constant:restartPadding],
        [restartStack.bottomAnchor constraintEqualToAnchor:restartContainer.contentView.bottomAnchor constant:-restartPadding]
    ]];

    BOOL isJailbroken = [[DOEnvironmentManager sharedManager] isJailbroken] || [[DOEnvironmentManager sharedManager] isJailbrokenWithOtherJailbreak];
    BOOL isSupported = [[DOEnvironmentManager sharedManager] isSupported];

    UIAction *respringAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [self fadeToBlack:^{
            [[DOEnvironmentManager sharedManager] respring];
        }];
    }];
    UIAction *userspaceAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [self fadeToBlack:^{
            [[DOEnvironmentManager sharedManager] rebootUserspace];
        }];
    }];
    UIAction *rebootAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Menu_Reboot_Device_Title") message:DOLocalizedString(@"Alert_Reboot_Device_Body") preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [confirmation addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Reboot") style:UIAlertActionStyleDestructive handler:^(__kindof UIAlertAction * _Nonnull alertAction) {
            [self fadeToBlack:^{
                [[DOEnvironmentManager sharedManager] reboot];
            }];
        }]];
        [self presentViewController:confirmation animated:YES completion:nil];
    }];

    [restartStack addArrangedSubview:[self customGlassRestartButtonWithTitle:DOLocalizedString(@"Menu_Restart_SpringBoard_Title") imageName:@"arrow.clockwise" action:respringAction enabled:isJailbroken cornerRadius:restartCornerRadius]];
    [restartStack addArrangedSubview:[self customGlassRestartButtonWithTitle:DOLocalizedString(@"Menu_Reboot_Userspace_Title") imageName:@"arrow.clockwise.circle" action:userspaceAction enabled:isJailbroken cornerRadius:restartCornerRadius]];
    [restartStack addArrangedSubview:[self customGlassRestartButtonWithTitle:DOLocalizedString(@"Menu_Reboot_Device_Title") imageName:@"power" action:rebootAction enabled:YES cornerRadius:restartCornerRadius]];

    // Keep a dedicated gap for the optional update button. setupUpdateAvailable:
    // positions that button above jailbreakBtn, so without this reserve it can overlap
    // the lower edge of the glass action grid.
    UIView *updateReserve = [[UIView alloc] init];
    updateReserve.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:updateReserve];
    // Move only the Glass Grid down while preserving the jailbreak bar position:
    // the extra gap above the grid is taken back from the reserve below it.
    CGFloat updateReserveHeight = ([DOGlobalAppearance isHomeButtonDevice] ? 42.0 : 52.0) - gridDrop;
    [updateReserve.heightAnchor constraintEqualToConstant:updateReserveHeight].active = YES;

    UIView *buttonPlaceHolder = [[UIView alloc] init];
    buttonPlaceHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:buttonPlaceHolder];
    [buttonPlaceHolder.heightAnchor constraintEqualToConstant:jailbreakButtonHeight].active = YES;

    NSString *jailbreakButtonTitle = [self jailbreakButtonTitle];
    UIImage *jailbreakButtonImage = isSupported ?
        [UIImage systemImageNamed:@"lock.open" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] :
        [UIImage systemImageNamed:@"lock.slash" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]];

    __block UIColor *jailbreakExpandedBackgroundColor = nil;
    __block DOCustomLiquidGlassView *jailbreakMaterialGlass = nil;

    self.jailbreakBtn = [[DOJailbreakButton alloc] initWithAction:[UIAction actionWithTitle:jailbreakButtonTitle image:jailbreakButtonImage identifier:@"jailbreak" handler:^(__kindof UIAction * _Nonnull action) {
/********************************** roothide specific ************************************/
        if (otherJailbreakActived(false)) {
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Error") message:DOLocalizedString(@"Your device currently has another jailbreak activated, please reboot device.") preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *closeAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Close") style:UIAlertActionStyleDefault handler:nil];
            [alertController addAction:closeAction];
            [self presentViewController:alertController animated:YES completion:nil];
            return;
        }
/********************************** roothide specific ************************************/

        actionGrid.userInteractionEnabled = NO;
        self.updateButton.userInteractionEnabled = NO;

        // Compact state uses the unified app-side Glass material plus a transparent
        // Metal edge-optics overlay. Before expansion, hide both so the stock
        // jailbreak/progress interface keeps the author's intended opaque treatment.
        jailbreakMaterialGlass.hidden = YES;
        self.jailbreakBtn.backgroundColor = jailbreakExpandedBackgroundColor;
        [self.jailbreakBtn expandButton:self.jailbreakButtonConstraints];

        [UIView animateWithDuration:0.75 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            actionGrid.alpha = 0.0;
            actionGrid.transform = CGAffineTransformMakeTranslation(0, 20);
            headerView.transform = CGAffineTransformMakeTranslation(0, -20);
            self.updateButton.alpha = 0.0;
        } completion:nil];

        [self startJailbreak];
    }]];
    self.jailbreakBtn.enabled = !isJailbroken && isSupported;

    // DOJailbreakButton dims its whole view to 70% when disabled. When the Glass
    // layer lives inside that view, the disabled "Jailbroken" state therefore
    // fades the blur/body/specular together and no longer matches Main Glass.
    // Keep the material itself at full opacity and dim only the button content.
    CGFloat jailbreakContentAlpha = self.jailbreakBtn.enabled ? 1.0 : 0.70;
    self.jailbreakBtn.alpha = 1.0;
    self.jailbreakBtn.button.alpha = jailbreakContentAlpha;

    // Preserve the original DOJailbreakButton color for expanded/progress mode.
    jailbreakExpandedBackgroundColor = self.jailbreakBtn.backgroundColor;

    // Glass V2.2: CTA uses the same single Liquid Glass material as the surrounding
    // Main surfaces. Directional perimeter optics are now produced by
    // DOCustomLiquidGlassView itself, so no second Metal edge pass is layered above it.
    jailbreakMaterialGlass = [self customGlassViewWithCornerRadius:14.0 tintAlpha:0.05];
    jailbreakMaterialGlass.userInteractionEnabled = NO;
    DOCustomGlassApplyMainMaterialProfile(jailbreakMaterialGlass);
    [jailbreakMaterialGlass reloadMaterial];

    // Keep the legacy property nil so existing refresh plumbing remains a safe no-op.
    self.customGlassJailbreakRefractionView = nil;

    self.jailbreakBtn.backgroundColor = UIColor.clearColor;
    [self.jailbreakBtn insertSubview:jailbreakMaterialGlass atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [jailbreakMaterialGlass.leadingAnchor constraintEqualToAnchor:self.jailbreakBtn.leadingAnchor],
        [jailbreakMaterialGlass.trailingAnchor constraintEqualToAnchor:self.jailbreakBtn.trailingAnchor],
        [jailbreakMaterialGlass.topAnchor constraintEqualToAnchor:self.jailbreakBtn.topAnchor],
        [jailbreakMaterialGlass.bottomAnchor constraintEqualToAnchor:self.jailbreakBtn.bottomAnchor]
    ]];

    [self.view addSubview:self.jailbreakBtn];

    self.customGlassJailbreakCenterYConstraint =
        [self.jailbreakBtn.centerYAnchor constraintEqualToAnchor:buttonPlaceHolder.centerYAnchor constant:jailbreakVerticalOffset];

    [NSLayoutConstraint activateConstraints:(self.jailbreakButtonConstraints = @[
        [self.jailbreakBtn.leadingAnchor constraintEqualToAnchor:buttonPlaceHolder.leadingAnchor constant:jailbreakHorizontalInset],
        [self.jailbreakBtn.trailingAnchor constraintEqualToAnchor:buttonPlaceHolder.trailingAnchor constant:-jailbreakHorizontalInset],
        [self.jailbreakBtn.heightAnchor constraintEqualToAnchor:buttonPlaceHolder.heightAnchor],
        self.customGlassJailbreakCenterYConstraint
    ])];

    NSUserDefaults *profileDefaults = NSUserDefaults.standardUserDefaults;
    BOOL focusEnabled = [profileDefaults boolForKey:DOCustomGlassProfileFocusEnabledKey];
    BOOL focusDockRight = [profileDefaults objectForKey:DOCustomGlassProfileFocusDockRightKey]
        ? [profileDefaults boolForKey:DOCustomGlassProfileFocusDockRightKey]
        : YES;
    [self setCustomGlassProfileFocusEnabled:focusEnabled
                                  dockRight:focusDockRight
                                   animated:NO
                                    persist:NO];

    [self applyCustomGlassHomeAppearance];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        if ([[DOUIManager sharedInstance] environmentUpdateAvailable]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setupUpdateAvailable:YES];
            });
        }
        else if ([[DOUIManager sharedInstance] isUpdateAvailable]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setupUpdateAvailable:NO];
            });
        }
    });
}

- (NSString *)jailbreakButtonTitle
{
    BOOL isJailbroken = [[DOEnvironmentManager sharedManager] isJailbroken];
    BOOL isSupported = [[DOEnvironmentManager sharedManager] isSupported];
    BOOL removeJailbreakEnabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"removeJailbreakEnabled" fallback:NO];

    NSString *jailbreakButtonTitle = DOLocalizedString(@"Button_Jailbreak_Title");
    if (!isSupported)
        jailbreakButtonTitle = DOLocalizedString(@"Unsupported");
    else if (isJailbroken)
        jailbreakButtonTitle = DOLocalizedString(@"Status_Title_Jailbroken");
    else if (removeJailbreakEnabled)
        jailbreakButtonTitle = DOLocalizedString(@"Button_Remove_Jailbreak");
    
    return jailbreakButtonTitle;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (DORHSupporterIsVerified()) {
        [self applyCustomGlassHomeAppearance];
        [self refreshSupporterState];
    }
    [self.jailbreakBtn.button setTitle:[self jailbreakButtonTitle] forState:UIControlStateNormal];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DOCustomGlassThemeDidChangeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DORHSupporterLicenseDidChangeNotification
                                                  object:nil];
}

- (void)startJailbreak
{
    DOJailbreaker *jailbreaker = [[DOJailbreaker alloc] init];

    [[DOUIManager sharedInstance] startLogCapture];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if ([jailbreaker contiguousMappingWorkaroundNeeded]) {
            
            cpu_subtype_t cpuFamily = 0;
            size_t cpuFamilySize = sizeof(cpuFamily);
            sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
            NSString *workaroundMessage = DOLocalizedString(@"Respring_Required_Message");
            if (cpuFamily == CPUFAMILY_ARM_TYPHOON) {
                workaroundMessage = [workaroundMessage stringByAppendingString:[NSString stringWithFormat:@"\n\n%@", DOLocalizedString(@"Respring_Required_Notice_A8")]];
            }

            UIAlertController *contiguousMappingWorkaroundAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Respring_Required") message:workaroundMessage preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Respring_Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
                exit(0);
            }];
            
            UIAlertAction *workaroundAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Apply_Workaround") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [jailbreaker applyContiguousMappingWorkaround];
            }];
            
            [contiguousMappingWorkaroundAlertController addAction:cancelAction];
            [contiguousMappingWorkaroundAlertController addAction:workaroundAction];
            contiguousMappingWorkaroundAlertController.preferredAction = workaroundAction;

            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:contiguousMappingWorkaroundAlertController animated:YES completion:nil];
            });
            return;
        }

        //We need to get the preconfig mutex to start the jailbreak (self.jailbreakBtn.canStartJailbreak)
        [self.jailbreakBtn lockMutex];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hideHomeIndicator = YES;
        });

        NSError *error;
        BOOL didRemove = NO;
        BOOL showLogs = YES;
        [jailbreaker runWithError:&error didRemoveJailbreak:&didRemove showLogs:&showLogs];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error && showLogs) {
                [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Jailbreak failed with error: %@", error] debug:NO];
                [self.navigationController pushViewController:[[DOLogCrashViewController alloc] initWithTitle:[error localizedDescription]] animated:YES];
            }
            else if (error && !showLogs) {
                // Used when there is an error that is explainable in such detail that additional logs are not needed
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Log_Error") message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *rebootAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Reboot") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                    exec_cmd_trusted(JBROOT_PATH("/sbin/reboot"), NULL);
                }];
                [alertController addAction:rebootAction];
                [self presentViewController:alertController animated:YES completion:nil];
            }
            else if (didRemove) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Removed_Jailbreak_Alert_Title") message:DOLocalizedString(@"Removed_Jailbreak_Alert_Message") preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *rebootAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Close") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                    exit(0);
                }];
                [alertController addAction:rebootAction];
                [self presentViewController:alertController animated:YES completion:nil];
            }
            else {
                // No errors
                [[DOUIManager sharedInstance] completeJailbreak];
                [self fadeToBlack: ^{
                    [jailbreaker finalize];
                }];
            }
        });
        [self.jailbreakBtn unlockMutex];
    });
}

-(void)setupUpdateAvailable:(BOOL)environmentUpdate
{
    if (self.jailbreakBtn.didExpand)
        return;

    if (self.customGlassJailbreakCenterYConstraint &&
        self.customGlassJailbreakCenterYConstraint.constant != 0.0) {
        self.customGlassJailbreakCenterYConstraint.constant = 0.0;
        [self.view layoutIfNeeded];
    }

    NSString *title = environmentUpdate ? DOLocalizedString(@"Button_Update_Environment") : DOLocalizedString(@"Button_Update_Available");
    
    NSString *releaseFrom = [[DOUIManager sharedInstance] getLaunchedReleaseTag];
    NSString *releaseTo = [[DOUIManager sharedInstance] getLatestReleaseTag];

    if (environmentUpdate)
    {
        releaseFrom = [[DOEnvironmentManager sharedManager] jailbrokenVersion];
        releaseTo = [[DOUIManager sharedInstance] getLaunchedReleaseTag];
    }

    self.updateButton = [DOActionMenuButton buttonWithAction:[UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] identifier:@"update-available" handler:^(__kindof UIAction * _Nonnull action) {
        [self.navigationController pushViewController:[[DOUpdateViewController alloc] initFromTag:releaseFrom toTag:releaseTo] animated:YES];
    }] chevron:NO];

    self.updateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.updateButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.updateButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.updateButton.heightAnchor constraintEqualToConstant:30],
        [self.updateButton.bottomAnchor constraintEqualToAnchor:self.jailbreakBtn.topAnchor constant:[DOGlobalAppearance isHomeButtonDevice] ? -10 : -20]
    ]];

    [self.updateButton setTransform:CGAffineTransformMakeTranslation(0, 25)];
    [self.updateButton setAlpha:0];
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0  options: UIViewAnimationOptionCurveEaseInOut animations:^{
        [self.updateButton setTransform:CGAffineTransformIdentity];
        [self.updateButton setAlpha:1];
    } completion:nil];
}

-(void)simulateJailbreak
{
    // Let's simulate a "jailbreak" using grand central dispatch

    DOUIManager *uiManager = [DOUIManager sharedInstance];

    static BOOL didFinish = NO; //not thread safe lol
    

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [uiManager completeJailbreak];
        [uiManager sendLog:@"Rebooting Userspace" debug: NO];
        didFinish = YES;
        [self fadeToBlack: ^{

        }];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [NSThread sleepForTimeInterval:0.2];
        [uiManager sendLog:@"Launching kexploitd" debug: NO];
        [NSThread sleepForTimeInterval:0.5];
        [uiManager sendLog:@"Launching oobPCI" debug: NO];
        [NSThread sleepForTimeInterval:0.15];
        [uiManager sendLog:@"Gaining r/w" debug: NO];
        [NSThread sleepForTimeInterval:0.8];
        [uiManager sendLog:@"Patchfinding" debug: NO];
        NSArray *types = @[@"AMFI", @"PAC", @"KTRR", @"KPP", @"PPL", @"KPF", @"APRR", @"AMCC", @"PAN", @"PXN", @"ASLR", @"OPA"]; //Ever heard of the legendary opa bypass
        while (true)
        {
            [NSThread sleepForTimeInterval:0.6 * rand() / RAND_MAX];
            if (didFinish) break;
            NSString *type = types[arc4random_uniform((uint32_t)types.count)];
            [uiManager sendLog:[NSString stringWithFormat:@"Bypassing %@", type] debug: NO];
        }
    });
}

- (void)fadeToBlack:(void (^)(void))completion
{
    static bool didFade = false;
    if (didFade)
        return;
    didFade = true;
    UIView *mainView = self.parentViewController.view;
    float deviceCornerRadius = [[[UIScreen mainScreen] valueForKey:@"_displayCornerRadius"] floatValue];

    mainView.layer.cornerRadius = deviceCornerRadius;
    mainView.layer.cornerCurve = kCACornerCurveContinuous;
    mainView.layer.masksToBounds = YES;
    
    self.hideStatusBar = YES;

    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0 options: UIViewAnimationOptionCurveEaseInOut animations:^{
        mainView.transform = CGAffineTransformMakeScale(0.9, 0.9);
        mainView.alpha = 0.0;
    } completion:^(BOOL success) {
        completion();
    }];
}

#pragma mark - Action Menu Delegate

- (BOOL)actionMenuShowsChevronForAction:(UIAction *)action
{
    if ([action.identifier isEqualToString:@"settings"] || [action.identifier isEqualToString:@"credits"]) return YES;
    return NO;
}

- (BOOL)actionMenuActionIsEnabled:(UIAction *)action
{
    if ([action.identifier isEqualToString:@"respring"] || [action.identifier isEqualToString:@"reboot-userspace"]) {
        return [[DOEnvironmentManager sharedManager] isJailbroken];
    }
    return YES;
}

#pragma mark - Status Bar

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

- (BOOL)prefersStatusBarHidden
{
    return self.hideStatusBar;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return self.hideHomeIndicator;
}

- (void)setHideStatusBar:(BOOL)hideStatusBar
{
    _hideStatusBar = hideStatusBar;
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)setHideHomeIndicator:(BOOL)hideHomeIndicator
{
    _hideHomeIndicator = hideHomeIndicator;
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}

@end
