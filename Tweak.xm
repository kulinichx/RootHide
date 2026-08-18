#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <string.h>

static CFStringRef const kB3MPrefsDomain = CFSTR("com.kulinichx.better3dmenus16rh");
static CFStringRef const kB3MNotification = CFSTR("com.kulinichx.better3dmenus16rh/preferences.changed");

static BOOL gB3MHideSeparators = YES;
static BOOL gB3MReduceBlur = YES;
static BOOL gB3MHideShareApp = YES;
static BOOL gB3MHideRemoveApp = YES;
static BOOL gB3MHideSectionGap = NO;
static BOOL gB3MGlassMenuTint = NO;
static BOOL gB3MGlassTextTint = NO;
static CGFloat gB3MBlurFactor = 0.55;
static UIColor *gB3MActiveIconColor = nil;

static char kB3MSeparatorCapturedKey;
static char kB3MSeparatorHiddenKey;
static char kB3MSeparatorAlphaKey;
static char kB3MBlurCapturedKey;
static char kB3MBlurAlphaKey;
static char kB3MTextCapturedKey;
static char kB3MTextColorKey;
static char kB3MGlassMaterialKey;
static char kB3MRootGlassMaterialKey;
static char kB3MStockSubviewWasHiddenKey;
static char kB3MStockSubviewOriginalHiddenKey;

static BOOL B3MReadBool(CFStringRef key, BOOL fallback)
{
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kB3MPrefsDomain);
    if (!value) return fallback;

    BOOL result = fallback;
    CFTypeID type = CFGetTypeID(value);

    if (type == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (type == CFNumberGetTypeID()) {
        int number = fallback ? 1 : 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
            result = (number != 0);
        }
    }

    CFRelease(value);
    return result;
}

static double B3MReadDouble(CFStringRef key, double fallback, double minimum, double maximum)
{
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kB3MPrefsDomain);
    if (!value) return fallback;

    double result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        double number = fallback;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number)) {
            if (number < minimum) number = minimum;
            if (number > maximum) number = maximum;
            result = number;
        }
    }

    CFRelease(value);
    return result;
}

static void B3MLoadPreferences(void)
{
    CFPreferencesAppSynchronize(kB3MPrefsDomain);

    gB3MHideSeparators = B3MReadBool(CFSTR("HideSeparators"), YES);
    gB3MReduceBlur = B3MReadBool(CFSTR("ReduceBlur"), YES);
    gB3MHideShareApp = B3MReadBool(CFSTR("HideShareApp"), YES);
    gB3MHideRemoveApp = B3MReadBool(CFSTR("HideRemoveApp"), YES);
    gB3MHideSectionGap = B3MReadBool(CFSTR("HideSectionGap"), NO);
    gB3MGlassMenuTint = B3MReadBool(CFSTR("GlassMenuTint"), NO);
    gB3MGlassTextTint = B3MReadBool(CFSTR("GlassTextTint"), NO);
    gB3MBlurFactor = (CGFloat)B3MReadDouble(CFSTR("BlurFactor"), 0.55, 0.20, 1.00);
}

static void B3MPreferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo)
{
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    B3MLoadPreferences();
}

static void B3MApplySeparatorState(UIView *view)
{
    if (!view) return;

    NSNumber *captured = objc_getAssociatedObject(view, &kB3MSeparatorCapturedKey);

    if (gB3MHideSeparators) {
        if (![captured boolValue]) {
            objc_setAssociatedObject(view, &kB3MSeparatorHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kB3MSeparatorAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kB3MSeparatorCapturedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        if (!view.hidden) view.hidden = YES;
        if (view.alpha != 0.0) view.alpha = 0.0;
    } else if ([captured boolValue]) {
        NSNumber *oldHidden = objc_getAssociatedObject(view, &kB3MSeparatorHiddenKey);
        NSNumber *oldAlpha = objc_getAssociatedObject(view, &kB3MSeparatorAlphaKey);

        if (oldHidden) view.hidden = oldHidden.boolValue;
        if (oldAlpha) view.alpha = oldAlpha.doubleValue;

        objc_setAssociatedObject(view, &kB3MSeparatorCapturedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kB3MSeparatorHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kB3MSeparatorAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL B3MClassNameLooksLikeBackground(UIView *view)
{
    NSString *name = NSStringFromClass(view.class);
    return [name rangeOfString:@"Background" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void B3MApplyBlurRecursively(UIView *view, BOOL backgroundAncestor)
{
    if (!view) return;

    BOOL isBackgroundBranch = backgroundAncestor || B3MClassNameLooksLikeBackground(view);

    if ([view isKindOfClass:UIVisualEffectView.class] && isBackgroundBranch) {
        NSNumber *captured = objc_getAssociatedObject(view, &kB3MBlurCapturedKey);

        if (gB3MReduceBlur) {
            if (![captured boolValue]) {
                objc_setAssociatedObject(view, &kB3MBlurAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(view, &kB3MBlurCapturedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            NSNumber *original = objc_getAssociatedObject(view, &kB3MBlurAlphaKey);
            CGFloat originalAlpha = original ? original.doubleValue : 1.0;
            CGFloat wanted = originalAlpha * gB3MBlurFactor;

            if (fabs(view.alpha - wanted) > 0.001) {
                view.alpha = wanted;
            }
        } else if ([captured boolValue]) {
            NSNumber *original = objc_getAssociatedObject(view, &kB3MBlurAlphaKey);
            if (original) view.alpha = original.doubleValue;

            objc_setAssociatedObject(view, &kB3MBlurCapturedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kB3MBlurAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    for (UIView *subview in view.subviews) {
        B3MApplyBlurRecursively(subview, isBackgroundBranch);
    }
}


static inline CGFloat B3MClamp01(CGFloat value)
{
    return MIN(1.0, MAX(0.0, value));
}

/*
 * GlassFolders 1.0 response curves, kept separate on purpose:
 * - Material rises slightly slower than linear.
 * - Specular rises faster so edges read without an opaque body.
 * - Tint rises slower so high strength does not become a milky card.
 * - Edge has its own optical authority curve.
 */
static inline CGFloat B3MMaterialResponse(CGFloat strength)
{
    return pow(B3MClamp01(strength), 1.10);
}

static inline CGFloat B3MSpecularResponse(CGFloat strength)
{
    return pow(B3MClamp01(strength), 0.80);
}

static inline CGFloat B3MTintResponse(CGFloat strength)
{
    return pow(B3MClamp01(strength), 1.35);
}

static inline CGFloat B3MEdgeResponse(CGFloat strength)
{
    CGFloat s = B3MClamp01(strength);
    return 0.12 * s + 0.88 * pow(s, 1.80);
}

static BOOL B3MUsesDarkAppearance(UIView *view)
{
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;

    if (view) {
        style = view.traitCollection.userInterfaceStyle;
    }

    if (style == UIUserInterfaceStyleUnspecified) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }

    return style == UIUserInterfaceStyleDark;
}

/*
 * Resolve CAFilter at runtime exactly like GlassFolders.
 * This avoids linking private QuartzCore classes directly.
 */
static id B3MCreateCAFilter(NSString *type)
{
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL selector = NSSelectorFromString(@"filterWithType:");

    if (!filterClass || ![filterClass respondsToSelector:selector]) {
        return nil;
    }

    IMP imp = [filterClass methodForSelector:selector];
    typedef id (*B3MFilterFactoryIMP)(id, SEL, id);
    B3MFilterFactoryIMP func = (B3MFilterFactoryIMP)imp;

    return func(filterClass, selector, type);
}

static UIColor *B3MFallbackIconColor(void)
{
    // Neutral cool fallback only when the current icon cannot be sampled.
    return [UIColor colorWithHue:0.58 saturation:0.42 brightness:0.72 alpha:1.0];
}

static UIImage *B3MImageSnapshotFromIconView(UIView *view)
{
    if (!view) return nil;

    BOOL active = NO;

    SEL showingSEL = NSSelectorFromString(@"isShowingContextMenu");
    if ([view respondsToSelector:showingSEL]) {
        BOOL (*msgBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        active = msgBool(view, showingSEL);
    }

    if (!active) {
        SEL activeSEL =
            NSSelectorFromString(@"isContextMenuInteractionActiveOrPending");

        if ([view respondsToSelector:activeSEL]) {
            BOOL (*msgBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            active = msgBool(view, activeSEL);
        }
    }

    if (!active) return nil;

    SEL snapshotSEL = NSSelectorFromString(@"iconImageSnapshot");
    if (![view respondsToSelector:snapshotSEL]) return nil;

    id (*msgObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id snapshot = msgObject(view, snapshotSEL);

    return [snapshot isKindOfClass:UIImage.class] ? (UIImage *)snapshot : nil;
}

static UIImage *B3MFindActiveIconSnapshotInView(UIView *view)
{
    if (!view) return nil;

    Class iconViewClass = NSClassFromString(@"SBIconView");

    if (iconViewClass && [view isKindOfClass:iconViewClass]) {
        UIImage *snapshot = B3MImageSnapshotFromIconView(view);
        if (snapshot) return snapshot;
    }

    for (UIView *subview in view.subviews) {
        UIImage *snapshot = B3MFindActiveIconSnapshotInView(subview);
        if (snapshot) return snapshot;
    }

    return nil;
}

static UIImage *B3MFindActiveIconSnapshot(void)
{
    UIApplication *application = UIApplication.sharedApplication;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        if (windowScene.activationState != UISceneActivationStateForegroundActive &&
            windowScene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }

        for (UIWindow *window in windowScene.windows.reverseObjectEnumerator) {
            UIImage *snapshot = B3MFindActiveIconSnapshotInView(window);
            if (snapshot) return snapshot;
        }
    }

    return nil;
}

static UIColor *B3MDominantColorFromImage(UIImage *image)
{
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return B3MFallbackIconColor();

    const size_t width = 24;
    const size_t height = 24;
    const size_t bytesPerPixel = 4;
    const size_t bytesPerRow = width * bytesPerPixel;

    unsigned char pixels[width * height * bytesPerPixel];
    memset(pixels, 0, sizeof(pixels));

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );

    CGColorSpaceRelease(colorSpace);

    if (!context) return B3MFallbackIconColor();

    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    enum { kHueBins = 24 };

    CGFloat weights[kHueBins] = {0};
    CGFloat redSums[kHueBins] = {0};
    CGFloat greenSums[kHueBins] = {0};
    CGFloat blueSums[kHueBins] = {0};

    for (size_t i = 0; i < width * height; i++) {
        unsigned char *p = pixels + i * 4;

        CGFloat r = p[0] / 255.0;
        CGFloat g = p[1] / 255.0;
        CGFloat b = p[2] / 255.0;
        CGFloat a = p[3] / 255.0;

        if (a < 0.18) continue;

        CGFloat maxC = MAX(r, MAX(g, b));
        CGFloat minC = MIN(r, MIN(g, b));
        CGFloat delta = maxC - minC;
        CGFloat brightness = maxC;
        CGFloat saturation = maxC > 0.001 ? delta / maxC : 0.0;

        if (saturation < 0.16 || brightness < 0.12 || brightness > 0.97) {
            continue;
        }

        CGFloat hue = 0.0;

        if (delta > 0.0001) {
            if (maxC == r) {
                hue = fmod((g - b) / delta, 6.0);
            } else if (maxC == g) {
                hue = ((b - r) / delta) + 2.0;
            } else {
                hue = ((r - g) / delta) + 4.0;
            }

            hue /= 6.0;
            if (hue < 0.0) hue += 1.0;
        }

        NSInteger bin = (NSInteger)floor(hue * kHueBins) % kHueBins;

        CGFloat middlePreference =
            1.0 - MIN(1.0, fabs(brightness - 0.58) / 0.58);

        CGFloat weight =
            a *
            (0.28 + 0.72 * saturation) *
            (0.72 + 0.28 * middlePreference);

        weights[bin] += weight;
        redSums[bin] += r * weight;
        greenSums[bin] += g * weight;
        blueSums[bin] += b * weight;
    }

    NSInteger bestBin = -1;
    CGFloat bestWeight = 0.0;

    for (NSInteger i = 0; i < kHueBins; i++) {
        if (weights[i] > bestWeight) {
            bestWeight = weights[i];
            bestBin = i;
        }
    }

    if (bestBin < 0 || bestWeight < 0.35) {
        return B3MFallbackIconColor();
    }

    CGFloat r = redSums[bestBin] / bestWeight;
    CGFloat g = greenSums[bestBin] / bestWeight;
    CGFloat b = blueSums[bestBin] / bestWeight;

    UIColor *raw = [UIColor colorWithRed:r green:g blue:b alpha:1.0];

    CGFloat h = 0.0, s = 0.0, v = 0.0, alpha = 0.0;

    if (![raw getHue:&h saturation:&s brightness:&v alpha:&alpha]) {
        return raw;
    }

    // Keep the sampled hue, but normalize extreme icon colors before glass use.
    s = MIN(0.86, MAX(0.34, s));
    v = MIN(0.86, MAX(0.46, v));

    return [UIColor colorWithHue:h saturation:s brightness:v alpha:1.0];
}

static void B3MRefreshActiveIconColor(void)
{
    UIImage *snapshot = B3MFindActiveIconSnapshot();

    gB3MActiveIconColor = snapshot
        ? B3MDominantColorFromImage(snapshot)
        : B3MFallbackIconColor();
}

static UIColor *B3MResolvedBaseIconColor(void)
{
    return gB3MActiveIconColor ?: B3MFallbackIconColor();
}

static UIColor *B3MGlassBodyTintColor(UIView *view)
{
    UIColor *base = B3MResolvedBaseIconColor();

    CGFloat h = 0.58, s = 0.42, v = 0.72, alpha = 1.0;
    [base getHue:&h saturation:&s brightness:&v alpha:&alpha];

    if (B3MUsesDarkAppearance(view)) {
        // Dark glass may retain more chroma without flattening contrast.
        s = MIN(0.58, MAX(0.22, s * 0.62));
        v = MIN(0.78, MAX(0.48, v * 0.88));
    } else {
        /*
         * Light mode needs a stable luminance floor for black text. Keep only
         * a trace of the active icon hue and move the body tint close to white.
         * The live backdrop still supplies the wallpaper/app colour.
         */
        s = MIN(0.10, MAX(0.035, s * 0.12));
        v = 0.985;
    }

    return [UIColor colorWithHue:h saturation:s brightness:v alpha:1.0];
}

static UIColor *B3MGlassTextColorForView(UIView *view)
{
    UIColor *base = B3MResolvedBaseIconColor();

    CGFloat h = 0.58, s = 0.42, v = 0.72, alpha = 1.0;
    [base getHue:&h saturation:&s brightness:&v alpha:&alpha];

    if (B3MUsesDarkAppearance(view)) {
        /*
         * Keep action labels neutral. Colour from the sampled backdrop should
         * read through the glass body, not through the glyphs themselves.
         */
        return [UIColor colorWithWhite:0.985 alpha:0.98];
    }

    // Stable high-contrast foreground for the brighter Light glass profile.
    return [UIColor colorWithWhite:0.075 alpha:0.96];
}

static BOOL B3MColorLooksDestructive(UIColor *color, UITraitCollection *traits)
{
    if (!color) return NO;

    UIColor *resolved = color;

    if ([color respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [color resolvedColorWithTraitCollection:traits];
    }

    CGFloat r = 0.0, g = 0.0, b = 0.0, alpha = 0.0;

    if (![resolved getRed:&r green:&g blue:&b alpha:&alpha]) {
        return NO;
    }

    return (r > 0.65 && r > (g * 1.45) && r > (b * 1.25));
}

@interface B3MMenuGlassView : UIView
@property (nonatomic, strong) UIView *b3mTintView;
@property (nonatomic, strong) UIVisualEffectView *b3mFallbackBlurView;
@property (nonatomic, assign) CGFloat b3mStrength;
@property (nonatomic, assign) CGFloat b3mPreferredRadius;
@property (nonatomic, assign) BOOL b3mLastDarkAppearance;
@property (nonatomic, assign) BOOL b3mHasAppearance;
- (void)b3mRefreshMaterial;
@end

@implementation B3MMenuGlassView

+ (Class)layerClass
{
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass ?: CALayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];

    if (self) {
        /*
         * 62% is deliberately close to GlassFolders' accepted mid-range:
         * enough authority to read as glass without whitening the menu.
         */
        _b3mStrength = 0.72;
        _b3mPreferredRadius = 0.0;

        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;

        _b3mTintView = [[UIView alloc] initWithFrame:self.bounds];
        _b3mTintView.userInteractionEnabled = NO;
        _b3mTintView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _b3mTintView.backgroundColor = UIColor.clearColor;

        [self addSubview:_b3mTintView];

        [self b3mRefreshMaterial];
    }

    return self;
}

- (void)b3mRefreshMaterial
{
    BOOL darkAppearance = B3MUsesDarkAppearance(self);

    self.b3mLastDarkAppearance = darkAppearance;
    self.b3mHasAppearance = YES;

    CGFloat materialResponse =
        B3MMaterialResponse(self.b3mStrength);
    CGFloat specularResponse =
        B3MSpecularResponse(self.b3mStrength);
    CGFloat tintResponse =
        B3MTintResponse(self.b3mStrength);
    CGFloat edgeResponse =
        B3MEdgeResponse(self.b3mStrength);

    BOOL isBackdropLayer =
        [NSStringFromClass(self.layer.class) containsString:@"Backdrop"];

    if (isBackdropLayer) {
        /*
         * GlassFolders Liquid Glass opened-panel recipe, adapted to the much
         * smaller Context Menu surface. The material remains wallpaper/backdrop
         * driven; the app icon color is applied separately as a weak tint.
         */
        CGFloat blurRadius = darkAppearance
            ? (4.6 + 4.8 * materialResponse)
            : (4.2 + 3.6 * materialResponse);

        CGFloat saturation = darkAppearance
            ? (1.070 + 0.120 * materialResponse)
            : (0.900 + 0.080 * materialResponse);

        CGFloat brightness = darkAppearance
            ? (0.015 + 0.025 * materialResponse)
            : (0.050 + 0.040 * materialResponse);

        CGFloat sampleAlpha = darkAppearance
            ? (0.90 + 0.08 * materialResponse)
            : (0.985 + 0.015 * materialResponse);

        id saturate = B3MCreateCAFilter(@"colorSaturate");
        id brighten = B3MCreateCAFilter(@"colorBrightness");
        id blur = B3MCreateCAFilter(@"gaussianBlur");

        NSMutableArray *filters = [NSMutableArray array];

        if (saturate) {
            [saturate setValue:@(saturation) forKey:@"inputAmount"];
            [filters addObject:saturate];
        }

        if (brighten && fabs(brightness) > 0.0001) {
            [brighten setValue:@(brightness) forKey:@"inputAmount"];
            [filters addObject:brighten];
        }

        if (blur && blurRadius > 0.001) {
            [blur setValue:@(blurRadius) forKey:@"inputRadius"];
            [blur setValue:@YES forKey:@"inputNormalizeEdges"];
            [filters addObject:blur];
        }

        [self.layer setValue:filters forKey:@"filters"];
        [self.layer setValue:@1.0 forKey:@"scale"];
        self.alpha = B3MClamp01(sampleAlpha);

        if (self.b3mFallbackBlurView) {
            [self.b3mFallbackBlurView removeFromSuperview];
            self.b3mFallbackBlurView = nil;
        }
    } else {
        if (!self.b3mFallbackBlurView) {
            UIBlurEffect *effect =
                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];

            self.b3mFallbackBlurView =
                [[UIVisualEffectView alloc] initWithEffect:effect];

            self.b3mFallbackBlurView.userInteractionEnabled = NO;
            self.b3mFallbackBlurView.autoresizingMask =
                UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

            [self insertSubview:self.b3mFallbackBlurView
                   belowSubview:self.b3mTintView];
        }

        self.b3mFallbackBlurView.frame = self.bounds;
        self.b3mFallbackBlurView.alpha = darkAppearance
            ? MIN(0.48, 0.20 + 0.30 * materialResponse)
            : MIN(0.28, 0.10 + 0.18 * materialResponse);

        self.alpha = 1.0;
    }

    /*
     * Unlike GlassFolders' colorless wallpaper glass, Better3DMenus adds a
     * deliberately weak app-icon chroma layer. It is never allowed to become
     * the body material itself.
     */
    self.b3mTintView.backgroundColor = B3MGlassBodyTintColor(self);

    CGFloat iconTintAlpha = darkAppearance
        ? (0.045 + 0.075 * tintResponse)
        : (0.085 + 0.055 * tintResponse);

    self.b3mTintView.alpha =
        MIN(darkAppearance ? 0.105 : 0.125, iconTintAlpha);

    /*
     * GlassFolders continuity-edge parameters. Specular and edge responses
     * both participate so the border remains visible at mid strength without
     * turning into a neon outline.
     */
    CGFloat continuityAlpha = darkAppearance
        ? (0.022 + 0.022 * edgeResponse + 0.012 * specularResponse)
        : (0.028 + 0.028 * edgeResponse + 0.014 * specularResponse);

    self.layer.borderWidth = darkAppearance ? 0.42 : 0.44;
    self.layer.borderColor =
        [UIColor colorWithWhite:1.0
                          alpha:B3MClamp01(continuityAlpha)].CGColor;

    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];

    UIUserInterfaceStyle previousStyle =
        previousTraitCollection
            ? previousTraitCollection.userInterfaceStyle
            : UIUserInterfaceStyleUnspecified;

    UIUserInterfaceStyle currentStyle =
        self.traitCollection.userInterfaceStyle;

    if (previousStyle != currentStyle) {
        [self b3mRefreshMaterial];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    self.b3mTintView.frame = self.bounds;
    self.b3mFallbackBlurView.frame = self.bounds;

    CGFloat radius = self.b3mPreferredRadius;

    if (radius <= 0.0) {
        radius = 14.0;
    }

    CGFloat maxRadius =
        MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.50;

    radius = MIN(radius, maxRadius);

    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    BOOL darkAppearance = B3MUsesDarkAppearance(self);

    if (!self.b3mHasAppearance ||
        self.b3mLastDarkAppearance != darkAppearance) {
        [self b3mRefreshMaterial];
    }
}

@end

static B3MMenuGlassView *B3MGlassMaterialForBackgroundView(
    UIView *backgroundView,
    BOOL create)
{
    if (!backgroundView) return nil;

    B3MMenuGlassView *material =
        objc_getAssociatedObject(backgroundView, &kB3MGlassMaterialKey);

    if (!material && create) {
        material =
            [[B3MMenuGlassView alloc] initWithFrame:backgroundView.bounds];

        material.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        /*
         * _UIElasticContextMenuBackgroundView is background-only. Add the
         * material as its top background child; menu labels/icons live in the
         * separate _UIContextMenuView hierarchy.
         */
        [backgroundView addSubview:material];

        objc_setAssociatedObject(
            backgroundView,
            &kB3MGlassMaterialKey,
            material,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    return material;
}


static void B3MSetStockBackgroundSubviewSuppressed(UIView *subview, BOOL suppressed)
{
    if (!subview || [subview isKindOfClass:B3MMenuGlassView.class]) return;

    NSNumber *marker = objc_getAssociatedObject(subview, &kB3MStockSubviewWasHiddenKey);

    if (suppressed) {
        if (![marker boolValue]) {
            objc_setAssociatedObject(subview, &kB3MStockSubviewOriginalHiddenKey, @(subview.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(subview, &kB3MStockSubviewWasHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        subview.hidden = YES;
    } else if ([marker boolValue]) {
        NSNumber *originalHidden = objc_getAssociatedObject(subview, &kB3MStockSubviewOriginalHiddenKey);
        subview.hidden = originalHidden ? originalHidden.boolValue : NO;
        objc_setAssociatedObject(subview, &kB3MStockSubviewWasHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(subview, &kB3MStockSubviewOriginalHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void B3MApplyGlassBackground(UIView *backgroundView)
{
    if (!backgroundView) return;

    B3MMenuGlassView *material = B3MGlassMaterialForBackgroundView(backgroundView, NO);

    if (!gB3MGlassMenuTint) {
        if (material) {
            [material removeFromSuperview];
            objc_setAssociatedObject(backgroundView, &kB3MGlassMaterialKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (UIView *subview in backgroundView.subviews) {
            B3MSetStockBackgroundSubviewSuppressed(subview, NO);
        }
        return;
    }

    /*
     * GlassFolders' important takeover step: keep Apple's private material
     * objects alive but hide their visual output. Without this, our glass sits
     * underneath the stock Context Menu material and looks almost unchanged.
     */
    backgroundView.backgroundColor = UIColor.clearColor;

    for (UIView *subview in backgroundView.subviews) {
        if (subview != material) {
            B3MSetStockBackgroundSubviewSuppressed(subview, YES);
        }
    }

    if (!material) {
        material = B3MGlassMaterialForBackgroundView(backgroundView, YES);
    } else if (material.superview != backgroundView) {
        [material removeFromSuperview];
        [backgroundView addSubview:material];
    }

    material.frame = backgroundView.bounds;
    CGFloat radius = backgroundView.layer.cornerRadius;
    if (radius <= 0.0) radius = 14.0;
    material.b3mPreferredRadius = radius;
    [material b3mRefreshMaterial];
    [backgroundView bringSubviewToFront:material];
}

static void B3MApplyGlassTextRecursively(UIView *view)
{
    if (!view) return;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;

        NSNumber *captured =
            objc_getAssociatedObject(label, &kB3MTextCapturedKey);

        id oldStored =
            objc_getAssociatedObject(label, &kB3MTextColorKey);

        UIColor *originalColor = nil;

        if ([captured boolValue]) {
            originalColor =
                (oldStored == [NSNull null]) ? nil : (UIColor *)oldStored;
        } else {
            originalColor = label.textColor;
        }

        if (gB3MGlassTextTint) {
            if (B3MColorLooksDestructive(originalColor, label.traitCollection)) {
                if ([captured boolValue]) {
                    label.textColor = originalColor;

                    objc_setAssociatedObject(
                        label,
                        &kB3MTextCapturedKey,
                        nil,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    );

                    objc_setAssociatedObject(
                        label,
                        &kB3MTextColorKey,
                        nil,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    );
                }
            } else {
                if (![captured boolValue]) {
                    objc_setAssociatedObject(
                        label,
                        &kB3MTextColorKey,
                        originalColor ?: (id)[NSNull null],
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    );

                    objc_setAssociatedObject(
                        label,
                        &kB3MTextCapturedKey,
                        @YES,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    );
                }

                label.textColor = B3MGlassTextColorForView(label);
            }
        } else if ([captured boolValue]) {
            label.textColor = originalColor;

            objc_setAssociatedObject(
                label,
                &kB3MTextCapturedKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            objc_setAssociatedObject(
                label,
                &kB3MTextColorKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    }

    for (UIView *subview in view.subviews) {
        B3MApplyGlassTextRecursively(subview);
    }
}

static BOOL B3MActionIdentifierLooksLikeShareApp(NSString *identifier)
{
    if (identifier.length == 0) return NO;

    NSString *lower = identifier.lowercaseString;

    if ([lower isEqualToString:@"com.apple.springboard.application-shortcut-item.share"] ||
        [lower isEqualToString:@"com.apple.springboardhome.application-shortcut-item.share"]) {
        return YES;
    }

    BOOL springBoardOwned = ([lower rangeOfString:@"springboard"].location != NSNotFound);
    BOOL shortcutItem = ([lower rangeOfString:@"application-shortcut-item"].location != NSNotFound);
    BOOL share = ([lower hasSuffix:@".share"] ||
                  [lower rangeOfString:@".share-"].location != NSNotFound);

    return springBoardOwned && shortcutItem && share;
}

static NSString *B3MNormalizeMenuTitle(NSString *title)
{
    if (title.length == 0) return @"";

    NSString *normalized = [title lowercaseString];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" " withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\u00a0" withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\t" withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\n" withString:@""];

    return normalized;
}

static BOOL B3MTitleLooksLikeShareApp(NSString *title)
{
    NSString *normalized = B3MNormalizeMenuTitle(title);
    if (normalized.length == 0) return NO;

    static NSSet<NSString *> *knownTitles;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        knownTitles = [NSSet setWithArray:@[
            @"shareapp",
            @"分享app",
            @"共享app",
            @"分享应用",
            @"共享应用"
        ]];
    });

    return [knownTitles containsObject:normalized];
}

static BOOL B3MIsShareAppElement(UIMenuElement *element)
{
    if (!gB3MHideShareApp || !element) {
        return NO;
    }

    NSString *identifier = nil;
    NSString *title = nil;
    id candidate = (id)element;

    if ([candidate respondsToSelector:@selector(identifier)]) {
        identifier = [candidate identifier];
    }

    if ([candidate respondsToSelector:@selector(title)]) {
        title = [candidate title];
    }

    if (B3MActionIdentifierLooksLikeShareApp(identifier)) {
        return YES;
    }

    return B3MTitleLooksLikeShareApp(title);
}


static BOOL B3MActionIdentifierLooksLikeRemoveApp(NSString *identifier)
{
    if (identifier.length == 0) return NO;

    NSString *lower = identifier.lowercaseString;

    static NSSet<NSString *> *knownIdentifiers;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        knownIdentifiers = [NSSet setWithArray:@[
            @"com.apple.springboard.application-shortcut-item.remove",
            @"com.apple.springboard.application-shortcut-item.remove-app",
            @"com.apple.springboard.application-shortcut-item.delete",
            @"com.apple.springboard.application-shortcut-item.delete-app",
            @"com.apple.springboardhome.application-shortcut-item.remove",
            @"com.apple.springboardhome.application-shortcut-item.remove-app",
            @"com.apple.springboardhome.application-shortcut-item.delete",
            @"com.apple.springboardhome.application-shortcut-item.delete-app"
        ]];
    });

    if ([knownIdentifiers containsObject:lower]) {
        return YES;
    }

    BOOL springBoardOwned =
        ([lower rangeOfString:@"springboard"].location != NSNotFound);
    BOOL shortcutItem =
        ([lower rangeOfString:@"application-shortcut-item"].location != NSNotFound);
    BOOL removeOrDelete =
        ([lower hasSuffix:@".remove"] ||
         [lower hasSuffix:@".remove-app"] ||
         [lower hasSuffix:@".delete"] ||
         [lower hasSuffix:@".delete-app"]);

    return springBoardOwned && shortcutItem && removeOrDelete;
}

static BOOL B3MTitleLooksLikeRemoveApp(NSString *title)
{
    NSString *normalized = B3MNormalizeMenuTitle(title);
    if (normalized.length == 0) return NO;

    static NSSet<NSString *> *knownTitles;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        knownTitles = [NSSet setWithArray:@[
            @"removeapp",
            @"移除app"
        ]];
    });

    return [knownTitles containsObject:normalized];
}

static BOOL B3MIsRemoveAppElement(UIMenuElement *element)
{
    if (!gB3MHideRemoveApp || !element) {
        return NO;
    }

    NSString *identifier = nil;
    NSString *title = nil;
    id candidate = (id)element;

    if ([candidate respondsToSelector:@selector(identifier)]) {
        identifier = [candidate identifier];
    }

    if ([candidate respondsToSelector:@selector(title)]) {
        title = [candidate title];
    }

    if (B3MActionIdentifierLooksLikeRemoveApp(identifier)) {
        return YES;
    }

    return B3MTitleLooksLikeRemoveApp(title);
}

static __thread BOOL gB3MInsideMenuRewrite = NO;

static NSArray<UIMenuElement *> *B3MFilterMenuElements(NSArray<UIMenuElement *> *children)
{
    if ((!gB3MHideShareApp && !gB3MHideRemoveApp && !gB3MHideSectionGap) || children.count == 0) {
        return children;
    }

    NSMutableArray<UIMenuElement *> *result =
        [NSMutableArray arrayWithCapacity:children.count];

    BOOL changed = NO;

    for (UIMenuElement *element in children) {
        if (B3MIsShareAppElement(element) ||
            B3MIsRemoveAppElement(element)) {
            changed = YES;
            continue;
        }

        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *menu = (UIMenu *)element;
            NSArray<UIMenuElement *> *originalChildren = menu.children;
            NSArray<UIMenuElement *> *filteredChildren =
                B3MFilterMenuElements(originalChildren);

            /*
             * iOS 16 experimental section-gap removal.
             *
             * Untitled UIMenuOptionsDisplayInline menus are commonly used as
             * visual groups. Flatten only these groups so UIKit no longer
             * creates the large inter-section gap.
             *
             * We deliberately do not touch gesture recognizers, frames,
             * constraints, or global UIKit views here.
             */
            if (gB3MHideSectionGap &&
                menu.title.length == 0 &&
                (menu.options & UIMenuOptionsDisplayInline) &&
                !(menu.options & UIMenuOptionsDestructive)) {

                [result addObjectsFromArray:filteredChildren];
                changed = YES;
                continue;
            }

            if (filteredChildren != originalChildren) {
                BOOL oldGuard = gB3MInsideMenuRewrite;
                gB3MInsideMenuRewrite = YES;

                UIMenu *replacement =
                    [menu menuByReplacingChildren:filteredChildren];

                gB3MInsideMenuRewrite = oldGuard;

                [result addObject:replacement ?: menu];
                changed = YES;
                continue;
            }
        }

        [result addObject:element];
    }

    return changed ? result.copy : children;
}


static BOOL B3MViewLooksLikeStockContextMenuMaterial(UIView *view,
                                                     UIView *root)
{
    if (!view || !root || [view isKindOfClass:B3MMenuGlassView.class]) {
        return NO;
    }

    NSString *name = NSStringFromClass(view.class);

    if ([name rangeOfString:@"Background" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [name rangeOfString:@"Backdrop" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [name rangeOfString:@"Material" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [name rangeOfString:@"Platter" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    if ([view isKindOfClass:UIVisualEffectView.class]) {
        CGRect frame = [view.superview convertRect:view.frame toView:root];
        CGFloat rootArea = MAX(1.0, CGRectGetWidth(root.bounds) * CGRectGetHeight(root.bounds));
        CGFloat area = MAX(0.0, CGRectGetWidth(frame) * CGRectGetHeight(frame));

        // Only suppress visual-effect views that materially cover the menu body.
        return area >= rootArea * 0.60;
    }

    return NO;
}

static void B3MSuppressStockContextMenuMaterialsRecursively(UIView *view,
                                                            UIView *root,
                                                            BOOL suppressed)
{
    if (!view || !root) return;

    NSArray<UIView *> *subviews = view.subviews.copy;

    for (UIView *subview in subviews) {
        if ([subview isKindOfClass:B3MMenuGlassView.class]) {
            continue;
        }

        if (B3MViewLooksLikeStockContextMenuMaterial(subview, root)) {
            B3MSetStockBackgroundSubviewSuppressed(subview, suppressed);
            // A hidden material node no longer needs descendant traversal.
            if (suppressed) continue;
        }

        B3MSuppressStockContextMenuMaterialsRecursively(subview, root, suppressed);
    }
}

static B3MMenuGlassView *B3MRootGlassForContextMenu(UIView *root,
                                                    BOOL create)
{
    if (!root) return nil;

    B3MMenuGlassView *glass =
        objc_getAssociatedObject(root, &kB3MRootGlassMaterialKey);

    if (!glass && create) {
        glass = [[B3MMenuGlassView alloc] initWithFrame:root.bounds];
        glass.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        objc_setAssociatedObject(
            root,
            &kB3MRootGlassMaterialKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );

        // _UIContextMenuView is known to be the live menu host on the tested
        // device because the text-color hook on this same class is observable.
        // Keep glass at index 0 so actions/icons remain above it.
        [root insertSubview:glass atIndex:0];
    }

    return glass;
}

static void B3MApplyGlassToContextMenuRoot(UIView *root)
{
    if (!root) return;

    B3MMenuGlassView *glass = B3MRootGlassForContextMenu(root, NO);

    if (!gB3MGlassMenuTint) {
        if (glass) {
            [glass removeFromSuperview];
            objc_setAssociatedObject(
                root,
                &kB3MRootGlassMaterialKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }

        B3MSuppressStockContextMenuMaterialsRecursively(root, root, NO);
        return;
    }

    root.backgroundColor = UIColor.clearColor;
    root.layer.backgroundColor = UIColor.clearColor.CGColor;

    // Hide the visible UIKit material wherever it sits inside the live menu
    // hierarchy. This is the key difference from the previous build, which
    // assumed _UIElasticContextMenuBackgroundView was the compositing owner.
    B3MSuppressStockContextMenuMaterialsRecursively(root, root, YES);

    if (!glass) {
        glass = B3MRootGlassForContextMenu(root, YES);
    } else if (glass.superview != root) {
        [glass removeFromSuperview];
        [root insertSubview:glass atIndex:0];
    }

    glass.frame = root.bounds;

    CGFloat radius = root.layer.cornerRadius;
    if (radius <= 0.0) radius = 14.0;

    glass.b3mPreferredRadius = radius;
    [glass b3mRefreshMaterial];

    // Keep the material below all action content even if UIKit reordered views.
    [root sendSubviewToBack:glass];
}


#pragma mark - Better3DMenus Context Menu Diagnostics

/*
 * Diagnostic-only code.
 *
 * Purpose:
 *   - Identify the actual iOS 16.6 Context Menu compositing/background host.
 *   - Verify the z-order of B3MMenuGlassView versus Apple's stock material.
 *   - Inspect CABackdropLayer / CAFilter state after the menu is on screen.
 *
 * This does NOT modify gesture recognizers, long-press duration, menu actions,
 * layout geometry, or material state.
 */

static char kB3MDiagnosticScheduledKey;
static NSUInteger gB3MDiagnosticPass = 0;

static id B3MDiagnosticSafeValue(id object, NSString *key)
{
    if (!object || key.length == 0) return nil;

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *B3MDiagnosticClassName(id object)
{
    return object ? NSStringFromClass([object class]) : @"(nil)";
}

static NSString *B3MDiagnosticObjectDescription(id object)
{
    if (!object) return @"(nil)";

    @try {
        return [object description] ?: @"(nil)";
    } @catch (__unused NSException *exception) {
        return @"<description threw exception>";
    }
}

static NSUInteger B3MDiagnosticSubviewIndex(UIView *view)
{
    UIView *superview = view.superview;
    if (!superview) return NSNotFound;

    return [superview.subviews indexOfObjectIdenticalTo:view];
}

static CGRect B3MDiagnosticFrameInWindow(UIView *view)
{
    if (!view || !view.window) return CGRectNull;

    @try {
        return [view convertRect:view.bounds toView:view.window];
    } @catch (__unused NSException *exception) {
        return CGRectNull;
    }
}

static NSInteger B3MDiagnosticMaterialScore(UIView *view, UIView *menuRoot)
{
    if (!view) return NSIntegerMin;

    NSInteger score = 0;

    NSString *viewClass = NSStringFromClass(view.class);
    NSString *layerClass = NSStringFromClass(view.layer.class);

    if ([view isKindOfClass:B3MMenuGlassView.class]) score += 100;
    if ([layerClass rangeOfString:@"Backdrop" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 45;
    if ([view isKindOfClass:UIVisualEffectView.class]) score += 30;

    if ([viewClass rangeOfString:@"Background" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 25;
    if ([viewClass rangeOfString:@"Backdrop" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 25;
    if ([viewClass rangeOfString:@"Material" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 25;
    if ([viewClass rangeOfString:@"Platter" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 20;
    if ([viewClass rangeOfString:@"ContextMenu" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 10;

    id filters = B3MDiagnosticSafeValue(view.layer, @"filters");
    id backgroundFilters = B3MDiagnosticSafeValue(view.layer, @"backgroundFilters");

    if ([filters respondsToSelector:@selector(count)] && [filters count] > 0) score += 20;
    if ([backgroundFilters respondsToSelector:@selector(count)] && [backgroundFilters count] > 0) score += 20;

    if (view.layer.cornerRadius > 0.0) score += 3;
    if (!view.hidden && view.alpha > 0.01 && view.layer.opacity > 0.01) score += 2;

    if (menuRoot && !CGRectIsEmpty(menuRoot.bounds)) {
        CGRect rootRect = B3MDiagnosticFrameInWindow(menuRoot);
        CGRect viewRect = B3MDiagnosticFrameInWindow(view);

        if (!CGRectIsNull(rootRect) && !CGRectIsNull(viewRect)) {
            CGFloat rootArea = MAX(1.0, CGRectGetWidth(rootRect) * CGRectGetHeight(rootRect));
            CGFloat viewArea = MAX(0.0, CGRectGetWidth(viewRect) * CGRectGetHeight(viewRect));
            CGFloat ratio = viewArea / rootArea;

            if (ratio >= 0.55 && ratio <= 1.40) score += 8;
        }
    }

    return score;
}

static void B3MDiagnosticDumpLayer(CALayer *layer, NSInteger depth)
{
    if (!layer || depth > 10) return;

    NSString *indent =
        [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                          withString:@" "
                     startingAtIndex:0];

    id filters = B3MDiagnosticSafeValue(layer, @"filters");
    id backgroundFilters = B3MDiagnosticSafeValue(layer, @"backgroundFilters");
    id compositingFilter = B3MDiagnosticSafeValue(layer, @"compositingFilter");
    id scale = B3MDiagnosticSafeValue(layer, @"scale");

    NSLog(@"[B3M-DIAG] %@LAYER %p <%@> frame=%@ bounds=%@ opacity=%.3f hidden=%d "
          @"corner=%.3f z=%.3f masks=%d scale=%@ filters=%@ backgroundFilters=%@ compositingFilter=%@",
          indent,
          layer,
          B3MDiagnosticClassName(layer),
          NSStringFromCGRect(layer.frame),
          NSStringFromCGRect(layer.bounds),
          layer.opacity,
          layer.hidden,
          layer.cornerRadius,
          layer.zPosition,
          layer.masksToBounds,
          B3MDiagnosticObjectDescription(scale),
          B3MDiagnosticObjectDescription(filters),
          B3MDiagnosticObjectDescription(backgroundFilters),
          B3MDiagnosticObjectDescription(compositingFilter));

    for (CALayer *sublayer in layer.sublayers) {
        B3MDiagnosticDumpLayer(sublayer, depth + 1);
    }
}

static void B3MDiagnosticDumpViewTree(UIView *view,
                                      UIView *menuRoot,
                                      NSInteger depth)
{
    if (!view || depth > 16) return;

    NSString *indent =
        [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                          withString:@" "
                     startingAtIndex:0];

    NSInteger score = B3MDiagnosticMaterialScore(view, menuRoot);
    NSUInteger index = B3MDiagnosticSubviewIndex(view);
    CGRect windowFrame = B3MDiagnosticFrameInWindow(view);

    BOOL wasSuppressed =
        [objc_getAssociatedObject(view, &kB3MStockSubviewWasHiddenKey) boolValue];

    NSLog(@"[B3M-DIAG] %@VIEW %p <%@> index=%@ frame=%@ windowFrame=%@ "
          @"alpha=%.3f hidden=%d clips=%d bg=%@ "
          @"layer=%p <%@> layerOpacity=%.3f corner=%.3f z=%.3f "
          @"suppressedByB3M=%d score=%ld",
          indent,
          view,
          NSStringFromClass(view.class),
          index == NSNotFound ? @"-" : [NSString stringWithFormat:@"%lu", (unsigned long)index],
          NSStringFromCGRect(view.frame),
          CGRectIsNull(windowFrame) ? @"(no-window)" : NSStringFromCGRect(windowFrame),
          view.alpha,
          view.hidden,
          view.clipsToBounds,
          B3MDiagnosticObjectDescription(view.backgroundColor),
          view.layer,
          NSStringFromClass(view.layer.class),
          view.layer.opacity,
          view.layer.cornerRadius,
          view.layer.zPosition,
          wasSuppressed,
          (long)score);

    if (score >= 20 || [view isKindOfClass:B3MMenuGlassView.class]) {
        id filters = B3MDiagnosticSafeValue(view.layer, @"filters");
        id backgroundFilters = B3MDiagnosticSafeValue(view.layer, @"backgroundFilters");
        id compositingFilter = B3MDiagnosticSafeValue(view.layer, @"compositingFilter");

        NSLog(@"[B3M-DIAG] %@>>> MATERIAL-CANDIDATE view=%p <%@> score=%ld "
              @"filters=%@ backgroundFilters=%@ compositingFilter=%@",
              indent,
              view,
              NSStringFromClass(view.class),
              (long)score,
              B3MDiagnosticObjectDescription(filters),
              B3MDiagnosticObjectDescription(backgroundFilters),
              B3MDiagnosticObjectDescription(compositingFilter));

        if ([view isKindOfClass:B3MMenuGlassView.class] ||
            [NSStringFromClass(view.layer.class)
                rangeOfString:@"Backdrop"
                      options:NSCaseInsensitiveSearch].location != NSNotFound) {
            B3MDiagnosticDumpLayer(view.layer, depth + 1);
        }
    }

    NSArray<UIView *> *children = view.subviews.copy;
    for (UIView *child in children) {
        B3MDiagnosticDumpViewTree(child, menuRoot, depth + 1);
    }
}

static void B3MDiagnosticScanWindowCandidates(UIView *view,
                                              UIView *menuRoot,
                                              NSInteger depth)
{
    if (!view || depth > 18) return;

    NSInteger score = B3MDiagnosticMaterialScore(view, menuRoot);

    if (score >= 20) {
        CGRect windowFrame = B3MDiagnosticFrameInWindow(view);
        NSUInteger index = B3MDiagnosticSubviewIndex(view);

        NSLog(@"[B3M-DIAG] WINDOW-CANDIDATE depth=%ld view=%p <%@> "
              @"parent=%p <%@> index=%@ windowFrame=%@ "
              @"alpha=%.3f hidden=%d layer=<%@> corner=%.3f z=%.3f score=%ld",
              (long)depth,
              view,
              NSStringFromClass(view.class),
              view.superview,
              B3MDiagnosticClassName(view.superview),
              index == NSNotFound ? @"-" : [NSString stringWithFormat:@"%lu", (unsigned long)index],
              CGRectIsNull(windowFrame) ? @"(no-window)" : NSStringFromCGRect(windowFrame),
              view.alpha,
              view.hidden,
              NSStringFromClass(view.layer.class),
              view.layer.cornerRadius,
              view.layer.zPosition,
              (long)score);
    }

    for (UIView *child in view.subviews.copy) {
        B3MDiagnosticScanWindowCandidates(child, menuRoot, depth + 1);
    }
}

static void B3MDiagnosticDumpAncestorChain(UIView *root)
{
    NSLog(@"[B3M-DIAG] ---- ANCESTOR CHAIN ----");

    UIView *cursor = root;
    NSInteger depth = 0;

    while (cursor && depth < 20) {
        NSUInteger index = B3MDiagnosticSubviewIndex(cursor);

        NSLog(@"[B3M-DIAG] ancestor[%ld] %p <%@> parent=%p <%@> index=%@ "
              @"frame=%@ windowFrame=%@ alpha=%.3f hidden=%d layer=<%@>",
              (long)depth,
              cursor,
              NSStringFromClass(cursor.class),
              cursor.superview,
              B3MDiagnosticClassName(cursor.superview),
              index == NSNotFound ? @"-" : [NSString stringWithFormat:@"%lu", (unsigned long)index],
              NSStringFromCGRect(cursor.frame),
              CGRectIsNull(B3MDiagnosticFrameInWindow(cursor))
                  ? @"(no-window)"
                  : NSStringFromCGRect(B3MDiagnosticFrameInWindow(cursor)),
              cursor.alpha,
              cursor.hidden,
              NSStringFromClass(cursor.layer.class));

        cursor = cursor.superview;
        depth++;
    }
}

static void B3MDiagnosticDumpContextMenu(UIView *root, NSString *phase)
{
    if (!root || !root.window) return;

    NSUInteger pass = ++gB3MDiagnosticPass;

    NSLog(@"");
    NSLog(@"[B3M-DIAG] ============================================================");
    NSLog(@"[B3M-DIAG] PASS=%lu PHASE=%@ root=%p <%@> window=%p <%@>",
          (unsigned long)pass,
          phase ?: @"(unknown)",
          root,
          NSStringFromClass(root.class),
          root.window,
          NSStringFromClass(root.window.class));

    NSLog(@"[B3M-DIAG] SETTINGS GlassMenuTint=%d GlassTextTint=%d ReduceBlur=%d "
          @"HideSeparators=%d HideShareApp=%d HideRemoveApp=%d HideSectionGap=%d BlurFactor=%.3f",
          gB3MGlassMenuTint,
          gB3MGlassTextTint,
          gB3MReduceBlur,
          gB3MHideSeparators,
          gB3MHideShareApp,
          gB3MHideRemoveApp,
          gB3MHideSectionGap,
          gB3MBlurFactor);

    B3MMenuGlassView *rootGlass =
        B3MRootGlassForContextMenu(root, NO);

    NSLog(@"[B3M-DIAG] ROOT-GLASS=%p superview=%p <%@> index=%@ frame=%@ "
          @"layer=%p <%@> filters=%@",
          rootGlass,
          rootGlass.superview,
          B3MDiagnosticClassName(rootGlass.superview),
          rootGlass
              ? (B3MDiagnosticSubviewIndex(rootGlass) == NSNotFound
                    ? @"-"
                    : [NSString stringWithFormat:@"%lu",
                       (unsigned long)B3MDiagnosticSubviewIndex(rootGlass)])
              : @"-",
          rootGlass ? NSStringFromCGRect(rootGlass.frame) : @"(nil)",
          rootGlass.layer,
          rootGlass ? NSStringFromClass(rootGlass.layer.class) : @"(nil)",
          rootGlass
              ? B3MDiagnosticObjectDescription(
                    B3MDiagnosticSafeValue(rootGlass.layer, @"filters"))
              : @"(nil)");

    B3MDiagnosticDumpAncestorChain(root);

    NSLog(@"[B3M-DIAG] ---- _UIContextMenuView FULL SUBTREE ----");
    B3MDiagnosticDumpViewTree(root, root, 0);

    NSLog(@"[B3M-DIAG] ---- WINDOW MATERIAL CANDIDATES ----");
    B3MDiagnosticScanWindowCandidates(root.window, root, 0);

    NSLog(@"[B3M-DIAG] END PASS=%lu PHASE=%@", (unsigned long)pass, phase ?: @"(unknown)");
    NSLog(@"[B3M-DIAG] ============================================================");
    NSLog(@"");
}

static void B3MScheduleContextMenuDiagnostics(UIView *root)
{
    if (!root || !root.window) return;

    NSNumber *alreadyScheduled =
        objc_getAssociatedObject(root, &kB3MDiagnosticScheduledKey);

    if ([alreadyScheduled boolValue]) return;

    objc_setAssociatedObject(root,
                             &kB3MDiagnosticScheduledKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (root.window) {
            B3MDiagnosticDumpContextMenu(root, @"next-runloop");
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (root.window) {
            B3MDiagnosticDumpContextMenu(root, @"150ms");
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (root.window) {
            B3MDiagnosticDumpContextMenu(root, @"400ms");
        }
    });
}


%hook _UIContextMenuActionsListSeparatorView

- (void)didMoveToWindow
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

- (void)layoutSubviews
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

%end

%hook _UIContextMenuReusableSeparatorView

- (void)didMoveToWindow
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

- (void)layoutSubviews
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

%end

%hook _UIContextMenuSeparatorView

- (void)didMoveToWindow
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

- (void)layoutSubviews
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

%end

%hook _UIInterfaceActionBlankSeparatorView

- (void)didMoveToWindow
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

- (void)layoutSubviews
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

%end

%hook _UIInterfaceActionVibrantSeparatorView

- (void)didMoveToWindow
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

- (void)layoutSubviews
{
    %orig;
    B3MApplySeparatorState((UIView *)self);
}

%end

%hook _UIElasticContextMenuBackgroundView

- (void)didAddSubview:(UIView *)subview
{
    %orig(subview);
    if (gB3MGlassMenuTint && ![subview isKindOfClass:B3MMenuGlassView.class]) {
        B3MSetStockBackgroundSubviewSuppressed(subview, YES);
    }
}

- (void)didMoveToWindow
{
    %orig;
    B3MApplyGlassBackground((UIView *)self);
}

- (void)layoutSubviews
{
    %orig;
    B3MApplyGlassBackground((UIView *)self);
}

- (void)setBackgroundColor:(UIColor *)color
{
    if (gB3MGlassMenuTint) {
        %orig(UIColor.clearColor);
    } else {
        %orig(color);
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    %orig(previousTraitCollection);
    B3MMenuGlassView *material = B3MGlassMaterialForBackgroundView((UIView *)self, NO);
    if (material) [material b3mRefreshMaterial];
    B3MApplyGlassBackground((UIView *)self);
}

%end

%hook _UIContextMenuView

- (void)didAddSubview:(UIView *)subview
{
    %orig(subview);

    if (gB3MGlassMenuTint &&
        ![subview isKindOfClass:B3MMenuGlassView.class]) {
        B3MApplyGlassToContextMenuRoot((UIView *)self);
    }
}

- (void)didMoveToWindow
{
    %orig;

    UIView *root = (UIView *)self;

    if (root.window) {
        B3MRefreshActiveIconColor();
    } else {
        /*
         * UIKit may reuse a context-menu view instance. Allow one fresh
         * diagnostic series the next time this root is attached.
         */
        objc_setAssociatedObject(root,
                                 &kB3MDiagnosticScheduledKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    B3MApplyGlassToContextMenuRoot(root);
    B3MApplyBlurRecursively(root, NO);
    B3MApplyGlassTextRecursively(root);

    if (root.window) {
        B3MScheduleContextMenuDiagnostics(root);
    }
}

- (void)layoutSubviews
{
    %orig;
    B3MApplyGlassToContextMenuRoot((UIView *)self);
    B3MApplyBlurRecursively((UIView *)self, NO);
    B3MApplyGlassTextRecursively((UIView *)self);
}

- (void)setBackgroundColor:(UIColor *)color
{
    if (gB3MGlassMenuTint) {
        %orig(UIColor.clearColor);
    } else {
        %orig(color);
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    %orig(previousTraitCollection);

    B3MMenuGlassView *glass =
        B3MRootGlassForContextMenu((UIView *)self, NO);

    if (glass) {
        [glass b3mRefreshMaterial];
    }

    B3MApplyGlassToContextMenuRoot((UIView *)self);
    B3MApplyGlassTextRecursively((UIView *)self);
}

%end

%hook UIMenu

+ (instancetype)menuWithChildren:(NSArray<UIMenuElement *> *)children
{
    if (gB3MInsideMenuRewrite ||
        (!gB3MHideShareApp && !gB3MHideRemoveApp && !gB3MHideSectionGap)) {
        return %orig;
    }

    NSArray<UIMenuElement *> *filtered =
        B3MFilterMenuElements(children);

    return %orig(filtered);
}

+ (instancetype)menuWithTitle:(NSString *)title
                     children:(NSArray<UIMenuElement *> *)children
{
    if (gB3MInsideMenuRewrite ||
        (!gB3MHideShareApp && !gB3MHideRemoveApp && !gB3MHideSectionGap)) {
        return %orig;
    }

    NSArray<UIMenuElement *> *filtered =
        B3MFilterMenuElements(children);

    return %orig(title, filtered);
}

+ (instancetype)menuWithTitle:(NSString *)title
                        image:(UIImage *)image
                   identifier:(UIMenuIdentifier)identifier
                      options:(UIMenuOptions)options
                     children:(NSArray<UIMenuElement *> *)children
{
    if (gB3MInsideMenuRewrite ||
        (!gB3MHideShareApp && !gB3MHideRemoveApp && !gB3MHideSectionGap)) {
        return %orig;
    }

    NSArray<UIMenuElement *> *filtered =
        B3MFilterMenuElements(children);

    return %orig(title, image, identifier, options, filtered);
}

- (instancetype)menuByReplacingChildren:(NSArray<UIMenuElement *> *)children
{
    if (gB3MInsideMenuRewrite ||
        (!gB3MHideShareApp && !gB3MHideRemoveApp && !gB3MHideSectionGap)) {
        return %orig;
    }

    NSArray<UIMenuElement *> *filtered =
        B3MFilterMenuElements(children);

    return %orig(filtered);
}

%end

%ctor
{
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier
              isEqualToString:@"com.apple.springboard"]) {
            return;
        }

        B3MLoadPreferences();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            B3MPreferencesChanged,
            kB3MNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        %init;
    }
}
