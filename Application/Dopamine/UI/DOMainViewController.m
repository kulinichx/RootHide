//
//  DOMainViewController.m
//  Dopamine
//
//  Created by tomt000 on 08/01/2024.
//

#import "DOMainViewController.h"
#import "DOUIManager.h"
#import "DOEnvironmentManager.h"
#import "DOJailbreaker.h"
#import "DOGlobalAppearance.h"
#import "DOActionMenuButton.h"
#import "DOUpdateViewController.h"
#import "DOLogCrashViewController.h"
#import <pthread.h>
#import <sys/sysctl.h>
#import <libjailbreak/libjailbreak.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#pragma mark - Custom Glass Theme Settings V1

static NSString * const DOCustomGlassBackgroundBlurKey = @"DOCustomGlassTheme.BackgroundBlur";
static NSString * const DOCustomGlassBlurIntensityKey = @"DOCustomGlassTheme.GlassBlurIntensity";
static NSString * const DOCustomGlassTransparencyKey = @"DOCustomGlassTheme.GlassTransparency";
static NSString * const DOCustomGlassTintAlphaKey = @"DOCustomGlassTheme.GlassTintAlpha";
static NSString * const DOCustomGlassUsernameKey = @"DOCustomGlassTheme.Username";
static NSString * const DOCustomGlassMottoKey = @"DOCustomGlassTheme.Motto";
static NSString * const DOCustomGlassThemeDidChangeNotification = @"DOCustomGlassTheme.DidChange";
static NSUInteger const DOCustomGlassUsernameCharacterLimit = 20;
static NSUInteger const DOCustomGlassMottoCharacterLimit = 32;

static NSString *DOCustomGlassAvatarFilePath(void)
{
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (applicationSupport.length == 0)
        return nil;

    NSString *directory = [applicationSupport stringByAppendingPathComponent:@"CustomGlass"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [directory stringByAppendingPathComponent:@"avatar.jpg"];
}

static NSString *DOCustomGlassBackgroundFilePath(void)
{
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (applicationSupport.length == 0)
        return nil;

    NSString *directory = [applicationSupport stringByAppendingPathComponent:@"CustomGlass"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [directory stringByAppendingPathComponent:@"background.jpg"];
}

static inline CGFloat DOCustomGlassClamp01(CGFloat value)
{
    return MIN(1.0, MAX(0.0, value));
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

@interface DOCustomLiquidGlassView : UIView

@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UIView *neutralTintView;
@property(nonatomic, strong) UIVisualEffectView *fallbackBlurView;
@property(nonatomic, strong) CAGradientLayer *shoulderGradientLayer;
@property(nonatomic, strong) CAShapeLayer *shoulderMaskLayer;
@property(nonatomic, strong) CAGradientLayer *specularGradientLayer;
@property(nonatomic, strong) CAShapeLayer *specularMaskLayer;
@property(nonatomic, assign) CGFloat preferredCornerRadius;
@property(nonatomic, assign) CGFloat baseTintAlpha;
@property(nonatomic, assign) CGFloat materialScale;
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
        [self addSubview:_contentView];
        [NSLayoutConstraint activateConstraints:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
        ]];

        _shoulderGradientLayer = [CAGradientLayer layer];
        _shoulderGradientLayer.startPoint = CGPointMake(0.02, 0.02);
        _shoulderGradientLayer.endPoint = CGPointMake(0.98, 0.98);
        _shoulderGradientLayer.locations = @[@0.0, @0.30, @0.58, @0.82, @1.0];
        _shoulderGradientLayer.zPosition = 900.0;
        _shoulderMaskLayer = [CAShapeLayer layer];
        _shoulderMaskLayer.fillColor = UIColor.clearColor.CGColor;
        _shoulderMaskLayer.strokeColor = UIColor.whiteColor.CGColor;
        _shoulderMaskLayer.lineWidth = 5.0;
        _shoulderGradientLayer.mask = _shoulderMaskLayer;
        [self.layer addSublayer:_shoulderGradientLayer];

        _specularGradientLayer = [CAGradientLayer layer];
        _specularGradientLayer.startPoint = CGPointMake(0.0, 0.0);
        _specularGradientLayer.endPoint = CGPointMake(1.0, 1.0);
        _specularGradientLayer.locations = @[@0.0, @0.24, @0.56, @0.82, @1.0];
        _specularGradientLayer.zPosition = 901.0;
        _specularMaskLayer = [CAShapeLayer layer];
        _specularMaskLayer.fillColor = UIColor.clearColor.CGColor;
        _specularMaskLayer.strokeColor = UIColor.whiteColor.CGColor;
        _specularMaskLayer.lineWidth = 1.05;
        _specularGradientLayer.mask = _specularMaskLayer;
        [self.layer addSublayer:_specularGradientLayer];

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
    CGFloat materialScale = MAX(0.0, self.materialScale);

    // Keep the three controls independent:
    // Glass blur owns the local backdrop kernel; transparency owns only the
    // neutral transmission/body lift; highlight owns the optical rim. This
    // avoids the old grey-material behaviour where every slider changed alpha.
    CGFloat blurResponse = pow(blurStrength, 1.10);
    CGFloat opticalInput = DOCustomGlassClamp01((0.68 * blurStrength) + (0.32 * highlightResponse));
    CGFloat opticalResponse = 0.12 * opticalInput + 0.88 * pow(opticalInput, 1.80);
    BOOL darkAppearance = [self usesDarkAppearance];

    BOOL isBackdropLayer = [NSStringFromClass(self.layer.class) containsString:@"Backdrop"];
    if (isBackdropLayer && !self.suppressBackdrop) {
        CGFloat blurRadius = (1.0 + (10.5 * blurResponse)) * materialScale;
        CGFloat saturation = 1.04 + (0.24 * blurResponse * MIN(1.0, materialScale));
        CGFloat brightness = darkAppearance ?
            (0.004 + (0.012 * blurResponse)) :
            (0.001 + (0.005 * blurResponse));

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
        // Used by the restart-group shell: keep only the optical boundary and
        // do not blur a second time underneath the three real glass pills.
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
            MIN(0.62, 0.16 + (0.46 * blurResponse * MIN(1.0, materialScale)));
    }

    // Transparency changes only the amount of neutral lift. At 100% the
    // wallpaper remains almost untouched; at lower values the glass becomes
    // slightly more substantial without acquiring a grey/brown body tint.
    CGFloat bodyAuthority = 1.0 - transparency;
    CGFloat tintAlpha =
        0.003 +
        (0.042 * bodyAuthority * MIN(1.0, materialScale)) +
        (0.028 * self.baseTintAlpha);
    if (darkAppearance)
        tintAlpha += 0.003 * bodyAuthority;
    if (self.suppressBackdrop)
        tintAlpha *= 0.32;
    self.neutralTintView.backgroundColor = UIColor.whiteColor;
    self.neutralTintView.alpha = MIN(0.055, tintAlpha);

    CGFloat geometryScale = [self surfaceGeometryScale];
    CGFloat opticalScale = self.suppressBackdrop ?
        MIN(0.20, 0.24 * geometryScale * MAX(0.25, materialScale)) :
        MIN(0.90, geometryScale * (0.80 + (0.20 * MIN(1.0, materialScale))));

    // The optical rail is deliberately directional rather than a full white
    // outline: upper/leading light carries the read, lower/trailing light is a
    // faint secondary reflection, and the long side walls stay quiet.
    CGFloat upperRailAlpha = MIN(0.31,
        (0.085 + (0.14 * opticalResponse) + (0.075 * highlightResponse)) * opticalScale);
    CGFloat secondaryRailAlpha = MIN(0.12,
        (0.020 + (0.070 * opticalResponse) + (0.022 * highlightResponse)) * opticalScale);
    CGFloat shoulderAlpha = MIN(0.095,
        (0.016 + (0.052 * opticalResponse) + (0.020 * highlightResponse)) * opticalScale);

    self.shoulderGradientLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:shoulderAlpha].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:shoulderAlpha * 0.78].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:secondaryRailAlpha * 0.24].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:secondaryRailAlpha * 0.54].CGColor
    ];
    self.specularGradientLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:upperRailAlpha].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:upperRailAlpha * 0.84].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.018 * opticalScale].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:secondaryRailAlpha * 0.55].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:secondaryRailAlpha].CGColor
    ];

    CGFloat shoulderWidth = self.suppressBackdrop ?
        (0.72 + (0.48 * geometryScale)) :
        (1.10 + (1.35 * geometryScale));
    CGFloat specularWidth = self.suppressBackdrop ?
        (0.24 + (0.10 * geometryScale)) :
        (0.28 + (0.34 * geometryScale));
    self.shoulderMaskLayer.lineWidth = shoulderWidth;
    self.specularMaskLayer.lineWidth = specularWidth;

    self.layer.borderWidth = self.suppressBackdrop ?
        (0.10 + (0.05 * geometryScale)) :
        (0.12 + (0.10 * geometryScale));
    self.layer.borderColor = [UIColor colorWithWhite:1.0
                                             alpha:(0.018 + (0.040 * opticalResponse)) * opticalScale].CGColor;
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

    self.shoulderGradientLayer.frame = self.bounds;
    self.shoulderMaskLayer.frame = self.bounds;
    self.shoulderMaskLayer.path = rimPath.CGPath;

    self.specularGradientLayer.frame = self.bounds;
    self.specularMaskLayer.frame = self.bounds;
    self.specularMaskLayer.path = rimPath.CGPath;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle)
        [self reloadMaterial];
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
@property UIVisualEffectView *backgroundBlurView;
@property DOCustomLiquidGlassView *previewGlassView;
@property UIViewPropertyAnimator *backgroundBlurAnimator;

@property UISlider *backgroundBlurSlider;
@property UISlider *glassBlurSlider;
@property UISlider *glassTransparencySlider;
@property UISlider *glassTintSlider;

@property UILabel *backgroundBlurValueLabel;
@property UILabel *glassBlurValueLabel;
@property UILabel *glassTransparencyValueLabel;
@property UILabel *glassTintValueLabel;

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
    DOCustomLiquidGlassView *row = [self themeGlassViewWithCornerRadius:22.0 tintAlpha:0.045];

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

- (void)reloadCustomGlassBackground
{
    NSString *backgroundPath = DOCustomGlassBackgroundFilePath();
    UIImage *backgroundImage = backgroundPath.length > 0 ? [UIImage imageWithContentsOfFile:backgroundPath] : nil;
    self.customGlassBackgroundImageView.image = backgroundImage;
    self.customGlassBackgroundImageView.hidden = backgroundImage == nil;
}

- (void)presentCustomGlassBackgroundPicker
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
        NSData *imageData = UIImageJPEGRepresentation(image, 0.92);
        NSString *backgroundPath = DOCustomGlassBackgroundFilePath();
        BOOL saved = imageData.length > 0 &&
                     backgroundPath.length > 0 &&
                     [imageData writeToFile:backgroundPath atomically:YES];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!saved)
                return;

            weakSelf.customGlassBackgroundImageView.image = image;
            weakSelf.customGlassBackgroundImageView.hidden = NO;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:DOCustomGlassThemeDidChangeNotification object:nil];
        });
    }];
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

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"主题设置";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.clearColor;

    self.customGlassBackgroundImageView = [[UIImageView alloc] init];
    self.customGlassBackgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassBackgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.customGlassBackgroundImageView.clipsToBounds = YES;
    self.customGlassBackgroundImageView.userInteractionEnabled = NO;
    self.customGlassBackgroundImageView.hidden = YES;
    [self.view addSubview:self.customGlassBackgroundImageView];
    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassBackgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.customGlassBackgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.customGlassBackgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.customGlassBackgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self reloadCustomGlassBackground];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DOCustomGlassBackgroundBlurKey : @0.10,
        DOCustomGlassBlurIntensityKey : @0.85,
        DOCustomGlassTransparencyKey : @0.70,
        DOCustomGlassTintAlphaKey : @0.05,
        DOCustomGlassUsernameKey : @"",
        DOCustomGlassMottoKey : @""
    }];

    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;

    // Wallpaper blur stays below every control and below the back button, so
    // changing wallpaper blur can never blur the navigation affordance itself.
    self.backgroundBlurView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.backgroundBlurView.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundBlurView.userInteractionEnabled = NO;
    [self.view addSubview:self.backgroundBlurView];
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundBlurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundBlurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backgroundBlurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backgroundBlurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.showsVerticalScrollIndicator = NO;
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
                                                    subtitle:@"选择首页背景图片"
                                                   imageName:@"photo"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf presentCustomGlassBackgroundPicker];
    }]]];

    UIView *appearanceSpacer = [[UIView alloc] init];
    [contentStack addArrangedSubview:appearanceSpacer];
    [appearanceSpacer.heightAnchor constraintEqualToConstant:7.0].active = YES;

    UILabel *appearanceLabel = [self themeSectionLabelWithText:@"外观效果"];
    [contentStack addArrangedSubview:appearanceLabel];

    // The control panel is the actual Liquid Glass renderer used by the home
    // cards. Slider changes therefore preview the same material rather than an
    // unrelated UIVisualEffectView approximation.
    self.previewGlassView = [self themeGlassViewWithCornerRadius:26.0 tintAlpha:0.05];
    self.previewGlassView.materialScale = 0.92;
    [self.previewGlassView reloadMaterial];
    [contentStack addArrangedSubview:self.previewGlassView];
    // This panel previously collapsed to zero height because the Glass content
    // surface was frame-driven. Keep a safety floor even though contentView is
    // now Auto Layout driven, so all four sliders remain visible on every iOS 16
    // device and Dynamic Type configuration.
    [self.previewGlassView.heightAnchor constraintGreaterThanOrEqualToConstant:(isPad ? 420.0 : 404.0)].active = YES;

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

    self.backgroundBlurSlider = [self appearanceSlider];
    self.backgroundBlurSlider.minimumValue = 0.0;
    self.backgroundBlurSlider.maximumValue = 1.0;
    self.backgroundBlurSlider.value = [defaults floatForKey:DOCustomGlassBackgroundBlurKey];
    self.backgroundBlurValueLabel = [self appearanceValueLabel];
    [controlsStack addArrangedSubview:[self appearanceControlRowWithTitle:@"壁纸模糊"
                                                                 subtitle:@"整张背景的模糊程度"
                                                                   slider:self.backgroundBlurSlider
                                                               valueLabel:self.backgroundBlurValueLabel]];

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

    UIBlurEffect *backgroundBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
    self.backgroundBlurAnimator =
        [[UIViewPropertyAnimator alloc] initWithDuration:1.0 curve:UIViewAnimationCurveLinear animations:^{
            weakSelf.backgroundBlurView.effect = backgroundBlur;
        }];
    [self.backgroundBlurAnimator startAnimation];
    [self.backgroundBlurAnimator pauseAnimation];

    UIScreenEdgePanGestureRecognizer *edgeBackGesture =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdgeBackGesture:)];
    edgeBackGesture.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edgeBackGesture];

    [self applyAppearancePreviewAndPersist:NO];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadCustomGlassBackground];
    [self applyAppearancePreviewAndPersist:NO];
}

- (void)appearanceSliderChanged:(UISlider *)slider
{
    [self applyAppearancePreviewAndPersist:YES];
}

- (void)applyAppearancePreviewAndPersist:(BOOL)persist
{
    CGFloat backgroundBlur = self.backgroundBlurSlider.value;
    CGFloat glassBlur = self.glassBlurSlider.value;
    CGFloat transparency = self.glassTransparencySlider.value;
    CGFloat tintAlpha = self.glassTintSlider.value;

    self.backgroundBlurAnimator.fractionComplete = backgroundBlur;

    if (persist) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setFloat:backgroundBlur forKey:DOCustomGlassBackgroundBlurKey];
        [defaults setFloat:glassBlur forKey:DOCustomGlassBlurIntensityKey];
        [defaults setFloat:transparency forKey:DOCustomGlassTransparencyKey];
        [defaults setFloat:tintAlpha forKey:DOCustomGlassTintAlphaKey];

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

    self.backgroundBlurValueLabel.text = [NSString stringWithFormat:@"%.0f%%", backgroundBlur * 100.0];
    self.glassBlurValueLabel.text = [NSString stringWithFormat:@"%.0f%%", glassBlur * 100.0];
    self.glassTransparencyValueLabel.text = [NSString stringWithFormat:@"%.0f%%", transparency * 100.0];
    self.glassTintValueLabel.text = [NSString stringWithFormat:@"%.0f%%", (tintAlpha / 0.16) * 100.0];
}

- (void)restoreRecommendedAppearanceValues
{
    self.backgroundBlurSlider.value = 0.10;
    self.glassBlurSlider.value = 0.85;
    self.glassTransparencySlider.value = 0.70;
    self.glassTintSlider.value = 0.05;
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
    [self.backgroundBlurAnimator stopAnimation:YES];
}

@end

@interface DOMainViewController () <PHPickerViewControllerDelegate>

@property DOJailbreakButton *jailbreakBtn;
@property NSArray<NSLayoutConstraint *> *jailbreakButtonConstraints;
@property DOActionMenuButton *updateButton;
@property NSLayoutConstraint *customGlassJailbreakCenterYConstraint;
@property UIImageView *customGlassBackgroundImageView;
@property UIVisualEffectView *customGlassBackgroundBlurView;
@property UIViewPropertyAnimator *customGlassBackgroundBlurAnimator;
@property UIImageView *customGlassAvatarPhotoView;
@property UILabel *customGlassUsernameLabel;
@property UIAlertController *customGlassUsernameEditor;
@property UILabel *customGlassMottoLabel;
@property UIAlertController *customGlassMottoEditor;
@property(nonatomic) BOOL hideStatusBar;
@property(nonatomic) BOOL hideHomeIndicator;

@end

@implementation DOMainViewController

- (void)reloadCustomGlassBackground
{
    NSString *backgroundPath = DOCustomGlassBackgroundFilePath();
    UIImage *backgroundImage = backgroundPath.length > 0 ? [UIImage imageWithContentsOfFile:backgroundPath] : nil;
    self.customGlassBackgroundImageView.image = backgroundImage;
    self.customGlassBackgroundImageView.hidden = backgroundImage == nil;
}

- (void)applyCustomGlassHomeAppearance
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat backgroundBlur = [defaults objectForKey:DOCustomGlassBackgroundBlurKey] ?
        [defaults floatForKey:DOCustomGlassBackgroundBlurKey] : 0.10;
    backgroundBlur = DOCustomGlassClamp01(backgroundBlur);

    if (self.customGlassBackgroundBlurAnimator)
        self.customGlassBackgroundBlurAnimator.fractionComplete = backgroundBlur;

    // Every home Glass surface is already mounted in self.view. Walking that
    // hierarchy makes Settings / About / Theme Settings / restart pills / the
    // restart shell / jailbreak emphasis all consume the same persisted values.
    [self refreshCustomGlassMaterialInView:self.view];
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

    [self reloadCustomGlassBackground];
    [self applyCustomGlassHomeAppearance];
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
        NSData *imageData = UIImageJPEGRepresentation(image, 0.92);
        NSString *avatarPath = DOCustomGlassAvatarFilePath();
        BOOL saved = imageData.length > 0 &&
                     avatarPath.length > 0 &&
                     [imageData writeToFile:avatarPath atomically:YES];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!saved)
                return;

            weakSelf.customGlassAvatarPhotoView.image = image;
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
        [defaults setObject:username forKey:@"RootHideCustomHomeUsername"];
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
        [[NSUserDefaults standardUserDefaults] setObject:motto forKey:@"RootHideCustomHomeMotto"];
        weakSelf.customGlassMottoLabel.text = motto;
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
    [self setupCustomGlassHome];
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
    card.materialScale = 0.86;
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
    DOCustomLiquidGlassView *innerGlass = [self customGlassViewWithCornerRadius:cornerRadius tintAlpha:0.040];
    // Small pills use a deliberately lighter optical recipe than folder-sized
    // panels; the body still samples the wallpaper, but the edge stays hairline.
    innerGlass.materialScale = 0.72;
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

    self.customGlassBackgroundImageView = [[UIImageView alloc] init];
    self.customGlassBackgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassBackgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.customGlassBackgroundImageView.clipsToBounds = YES;
    self.customGlassBackgroundImageView.userInteractionEnabled = NO;
    self.customGlassBackgroundImageView.hidden = YES;
    [self.view addSubview:self.customGlassBackgroundImageView];
    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassBackgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.customGlassBackgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.customGlassBackgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.customGlassBackgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self reloadCustomGlassBackground];

    // Wallpaper blur is a page-level effect shared with Theme Settings. It sits
    // above either the Custom Glass background.jpg or the untouched Dopamine
    // theme background, and below every card/content layer.
    self.customGlassBackgroundBlurView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.customGlassBackgroundBlurView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassBackgroundBlurView.userInteractionEnabled = NO;
    [self.view addSubview:self.customGlassBackgroundBlurView];
    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassBackgroundBlurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.customGlassBackgroundBlurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.customGlassBackgroundBlurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.customGlassBackgroundBlurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    __weak typeof(self) weakSelfForBackgroundBlur = self;
    UIBlurEffect *homeBackgroundBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
    self.customGlassBackgroundBlurAnimator =
        [[UIViewPropertyAnimator alloc] initWithDuration:1.0 curve:UIViewAnimationCurveLinear animations:^{
            weakSelfForBackgroundBlur.customGlassBackgroundBlurView.effect = homeBackgroundBlur;
        }];
    [self.customGlassBackgroundBlurAnimator startAnimation];
    [self.customGlassBackgroundBlurAnimator pauseAnimation];

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
    avatarGlass.layer.borderWidth = 1.0;
    avatarGlass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    avatarGlass.layer.shadowColor = UIColor.blackColor.CGColor;
    avatarGlass.layer.shadowOpacity = 0.16;
    avatarGlass.layer.shadowRadius = 6.0;
    avatarGlass.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [profileView addSubview:avatarGlass];

    [NSLayoutConstraint activateConstraints:@[
        [avatarGlass.widthAnchor constraintEqualToConstant:avatarSize],
        [avatarGlass.heightAnchor constraintEqualToConstant:avatarSize],
        [avatarGlass.centerXAnchor constraintEqualToAnchor:profileView.centerXAnchor],
        [avatarGlass.topAnchor constraintEqualToAnchor:profileView.topAnchor]
    ]];

    UIImageView *avatarImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.crop.circle.fill"]];
    avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    avatarImageView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    [avatarGlass addSubview:avatarImageView];
    [NSLayoutConstraint activateConstraints:@[
        [avatarImageView.centerXAnchor constraintEqualToAnchor:avatarGlass.centerXAnchor],
        [avatarImageView.centerYAnchor constraintEqualToAnchor:avatarGlass.centerYAnchor],
        [avatarImageView.widthAnchor constraintEqualToConstant:avatarIconSize],
        [avatarImageView.heightAnchor constraintEqualToConstant:avatarIconSize]
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

    NSString *avatarPath = DOCustomGlassAvatarFilePath();
    UIImage *savedAvatar = avatarPath.length > 0 ? [UIImage imageWithContentsOfFile:avatarPath] : nil;
    if (savedAvatar) {
        self.customGlassAvatarPhotoView.image = savedAvatar;
        self.customGlassAvatarPhotoView.hidden = NO;
    }

    avatarGlass.userInteractionEnabled = YES;
    avatarGlass.isAccessibilityElement = YES;
    avatarGlass.accessibilityLabel = @"更换头像";
    [avatarGlass addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(presentCustomGlassAvatarPicker)]];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *username = [defaults stringForKey:DOCustomGlassUsernameKey];
    if (username.length == 0)
        username = [defaults stringForKey:@"RootHideCustomHomeUsername"];
    if (username.length == 0)
        username = @"RootHide User";
    NSString *motto = [defaults stringForKey:DOCustomGlassMottoKey];
    if (motto.length == 0)
        motto = [defaults stringForKey:@"RootHideCustomHomeMotto"] ?: @"Your motto";

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
        DOCustomGlassThemeSettingsViewController *themeSettingsController =
            [[DOCustomGlassThemeSettingsViewController alloc] init];
        [self.navigationController pushViewController:themeSettingsController animated:YES];
    }];
    DOCustomLiquidGlassView *themeCard = [self customGlassCardWithTitle:@"主题设置" imageName:@"slider.horizontal.3" action:themeAction];
    themeCard.preferredCornerRadius = themeCardHeight / 2.0;
    themeCard.layer.cornerRadius = themeCard.preferredCornerRadius;
    [rightColumn addArrangedSubview:themeCard];
    [themeCard.heightAnchor constraintEqualToConstant:themeCardHeight].active = YES;

    DOCustomLiquidGlassView *restartContainer = [self customGlassViewWithCornerRadius:24 tintAlpha:0.004];
    // Grouping shell only: no second backdrop blur and almost no optical rail.
    // The three inner pills are the actual Glass surfaces.
    restartContainer.materialScale = 0.18;
    restartContainer.suppressBackdrop = YES;
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
    __block DOCustomLiquidGlassView *jailbreakEmphasisGlass = nil;

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

        // Compact state uses an emphasized glass material. Before expansion,
        // restore DOJailbreakButton's original opaque theme color so the stock
        // jailbreak/progress interface keeps the author's intended treatment.
        jailbreakEmphasisGlass.hidden = YES;
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

    // Preserve the original DOJailbreakButton color for expanded/progress mode.
    // On the home screen, use the same blur/border language as the other cards
    // but with a stronger tint (0.10 vs 0.05) to keep the jailbreak CTA visually
    // more important without looking like a separate solid-blue material.
    jailbreakExpandedBackgroundColor = self.jailbreakBtn.backgroundColor;
    jailbreakEmphasisGlass = [self customGlassViewWithCornerRadius:14.0 tintAlpha:0.075];
    jailbreakEmphasisGlass.materialScale = 0.82;
    [jailbreakEmphasisGlass reloadMaterial];
    jailbreakEmphasisGlass.userInteractionEnabled = NO;
    self.jailbreakBtn.backgroundColor = UIColor.clearColor;
    [self.jailbreakBtn insertSubview:jailbreakEmphasisGlass atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [jailbreakEmphasisGlass.leadingAnchor constraintEqualToAnchor:self.jailbreakBtn.leadingAnchor],
        [jailbreakEmphasisGlass.trailingAnchor constraintEqualToAnchor:self.jailbreakBtn.trailingAnchor],
        [jailbreakEmphasisGlass.topAnchor constraintEqualToAnchor:self.jailbreakBtn.topAnchor],
        [jailbreakEmphasisGlass.bottomAnchor constraintEqualToAnchor:self.jailbreakBtn.bottomAnchor]
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
    [self reloadCustomGlassBackground];
    [self applyCustomGlassHomeAppearance];
    [self.jailbreakBtn.button setTitle:[self jailbreakButtonTitle] forState:UIControlStateNormal];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DOCustomGlassThemeDidChangeNotification
                                                  object:nil];
    [self.customGlassBackgroundBlurAnimator stopAnimation:YES];
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
