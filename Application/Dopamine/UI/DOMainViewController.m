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

#pragma mark - Custom Glass Theme Settings V1

static NSString * const DOCustomGlassBackgroundBlurKey = @"DOCustomGlassTheme.BackgroundBlur";
static NSString * const DOCustomGlassBlurIntensityKey = @"DOCustomGlassTheme.GlassBlurIntensity";
static NSString * const DOCustomGlassTransparencyKey = @"DOCustomGlassTheme.GlassTransparency";
static NSString * const DOCustomGlassTintAlphaKey = @"DOCustomGlassTheme.GlassTintAlpha";
static NSString * const DOCustomGlassUsernameKey = @"DOCustomGlassTheme.Username";
static NSString * const DOCustomGlassMottoKey = @"DOCustomGlassTheme.Motto";

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

@interface DOCustomGlassAppearanceViewController : UIViewController

@property UIVisualEffectView *backgroundBlurView;
@property UIVisualEffectView *previewGlassView;
@property UIView *previewShadeView;
@property UIView *previewTintView;
@property UIViewPropertyAnimator *backgroundBlurAnimator;
@property UIViewPropertyAnimator *glassBlurAnimator;

@property UISlider *backgroundBlurSlider;
@property UISlider *glassBlurSlider;
@property UISlider *glassTransparencySlider;
@property UISlider *glassTintSlider;

@property UILabel *backgroundBlurValueLabel;
@property UILabel *glassBlurValueLabel;
@property UILabel *glassTransparencyValueLabel;
@property UILabel *glassTintValueLabel;

@end

@implementation DOCustomGlassAppearanceViewController

- (UIVisualEffectView *)fixedGlassViewWithCornerRadius:(CGFloat)cornerRadius tintAlpha:(CGFloat)tintAlpha
{
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:blur];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    glassView.layer.cornerRadius = cornerRadius;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.layer.masksToBounds = YES;
    glassView.layer.borderWidth = 0.7;
    glassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    glassView.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha];
    return glassView;
}

- (UILabel *)valueLabel
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

- (UIView *)controlRowWithTitle:(NSString *)title
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

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"外观效果";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.clearColor;

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DOCustomGlassBackgroundBlurKey : @0.10,
        DOCustomGlassBlurIntensityKey : @0.85,
        DOCustomGlassTransparencyKey : @0.70,
        DOCustomGlassTintAlphaKey : @0.05
    }];

    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;

    UIButton *backButton = DOCustomGlassBackButton(self);
    [self.view addSubview:backButton];
    [NSLayoutConstraint activateConstraints:@[
        [backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
        [backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4.0],
        [backButton.widthAnchor constraintEqualToConstant:44.0],
        [backButton.heightAnchor constraintEqualToConstant:40.0]
    ]];

    // This view stays transparent so the currently active app wallpaper remains
    // visible across the entire editor. The first visual-effect view applies
    // only the user-selected wallpaper blur.
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
    contentStack.alignment = UIStackViewAlignmentCenter;
    contentStack.spacing = isPad ? 18.0 : 14.0;
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [contentStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:(isPad ? 18.0 : 12.0)],
        [contentStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-34.0],
        [contentStack.centerXAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.centerXAnchor],
        [contentStack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor]
    ]];

    // The adjustment panel is also the live Glass preview, so wallpaper and
    // material changes can be judged together without a redundant preview card.
    self.previewGlassView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.previewGlassView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewGlassView.layer.cornerRadius = 26.0;
    self.previewGlassView.layer.cornerCurve = kCACornerCurveContinuous;
    self.previewGlassView.layer.masksToBounds = YES;
    self.previewGlassView.layer.borderWidth = 0.7;
    [contentStack addArrangedSubview:self.previewGlassView];

    NSLayoutConstraint *controlsWidth =
        [self.previewGlassView.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor
                                                          constant:(isPad ? -80.0 : -40.0)];
    controlsWidth.priority = UILayoutPriorityDefaultHigh;
    controlsWidth.active = YES;
    [self.previewGlassView.widthAnchor constraintLessThanOrEqualToConstant:560.0].active = YES;

    self.previewShadeView = [[UIView alloc] init];
    self.previewShadeView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewShadeView.userInteractionEnabled = NO;
    [self.previewGlassView.contentView addSubview:self.previewShadeView];

    self.previewTintView = [[UIView alloc] init];
    self.previewTintView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewTintView.userInteractionEnabled = NO;
    [self.previewGlassView.contentView addSubview:self.previewTintView];

    [NSLayoutConstraint activateConstraints:@[
        [self.previewShadeView.leadingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.leadingAnchor],
        [self.previewShadeView.trailingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.trailingAnchor],
        [self.previewShadeView.topAnchor constraintEqualToAnchor:self.previewGlassView.contentView.topAnchor],
        [self.previewShadeView.bottomAnchor constraintEqualToAnchor:self.previewGlassView.contentView.bottomAnchor],

        [self.previewTintView.leadingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.leadingAnchor],
        [self.previewTintView.trailingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.trailingAnchor],
        [self.previewTintView.topAnchor constraintEqualToAnchor:self.previewGlassView.contentView.topAnchor],
        [self.previewTintView.bottomAnchor constraintEqualToAnchor:self.previewGlassView.contentView.bottomAnchor]
    ]];

    UIStackView *controlsStack = [[UIStackView alloc] init];
    controlsStack.translatesAutoresizingMaskIntoConstraints = NO;
    controlsStack.axis = UILayoutConstraintAxisVertical;
    controlsStack.spacing = 17.0;
    [self.previewGlassView.contentView addSubview:controlsStack];

    [NSLayoutConstraint activateConstraints:@[
        [controlsStack.leadingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.leadingAnchor constant:20.0],
        [controlsStack.trailingAnchor constraintEqualToAnchor:self.previewGlassView.contentView.trailingAnchor constant:-20.0],
        [controlsStack.topAnchor constraintEqualToAnchor:self.previewGlassView.contentView.topAnchor constant:20.0],
        [controlsStack.bottomAnchor constraintEqualToAnchor:self.previewGlassView.contentView.bottomAnchor constant:-18.0]
    ]];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    self.backgroundBlurSlider = [self appearanceSlider];
    self.backgroundBlurSlider.minimumValue = 0.0;
    self.backgroundBlurSlider.maximumValue = 1.0;
    self.backgroundBlurSlider.value = [defaults floatForKey:DOCustomGlassBackgroundBlurKey];
    self.backgroundBlurValueLabel = [self valueLabel];
    [controlsStack addArrangedSubview:[self controlRowWithTitle:@"壁纸模糊"
                                                       subtitle:@"整张背景的模糊程度"
                                                         slider:self.backgroundBlurSlider
                                                     valueLabel:self.backgroundBlurValueLabel]];

    self.glassBlurSlider = [self appearanceSlider];
    self.glassBlurSlider.minimumValue = 0.0;
    self.glassBlurSlider.maximumValue = 1.0;
    self.glassBlurSlider.value = [defaults floatForKey:DOCustomGlassBlurIntensityKey];
    self.glassBlurValueLabel = [self valueLabel];
    [controlsStack addArrangedSubview:[self controlRowWithTitle:@"Glass 模糊"
                                                       subtitle:@"预览玻璃自身的模糊强度"
                                                         slider:self.glassBlurSlider
                                                     valueLabel:self.glassBlurValueLabel]];

    self.glassTransparencySlider = [self appearanceSlider];
    self.glassTransparencySlider.minimumValue = 0.0;
    self.glassTransparencySlider.maximumValue = 1.0;
    self.glassTransparencySlider.value = [defaults floatForKey:DOCustomGlassTransparencyKey];
    self.glassTransparencyValueLabel = [self valueLabel];
    [controlsStack addArrangedSubview:[self controlRowWithTitle:@"Glass 透明度"
                                                       subtitle:@"越高越通透"
                                                         slider:self.glassTransparencySlider
                                                     valueLabel:self.glassTransparencyValueLabel]];

    self.glassTintSlider = [self appearanceSlider];
    self.glassTintSlider.minimumValue = 0.0;
    self.glassTintSlider.maximumValue = 0.16;
    self.glassTintSlider.value = [defaults floatForKey:DOCustomGlassTintAlphaKey];
    self.glassTintValueLabel = [self valueLabel];
    [controlsStack addArrangedSubview:[self controlRowWithTitle:@"Glass 高光"
                                                       subtitle:@"玻璃表面的白色高光强度"
                                                         slider:self.glassTintSlider
                                                     valueLabel:self.glassTintValueLabel]];

    UIButtonConfiguration *resetConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    resetConfiguration.title = @"恢复推荐值";
    resetConfiguration.image = [UIImage systemImageNamed:@"arrow.counterclockwise"];
    resetConfiguration.imagePadding = 7.0;
    resetConfiguration.baseForegroundColor = [UIColor colorWithWhite:1.0 alpha:0.86];

    UIButton *resetButton = [UIButton buttonWithConfiguration:resetConfiguration primaryAction:
        [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            [self restoreRecommendedAppearanceValues];
        }]];
    [controlsStack addArrangedSubview:resetButton];
    [resetButton.heightAnchor constraintEqualToConstant:38.0].active = YES;

    __weak typeof(self) weakSelf = self;
    UIBlurEffect *backgroundBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
    self.backgroundBlurAnimator =
        [[UIViewPropertyAnimator alloc] initWithDuration:1.0 curve:UIViewAnimationCurveLinear animations:^{
            weakSelf.backgroundBlurView.effect = backgroundBlur;
        }];
    [self.backgroundBlurAnimator pauseAnimation];

    UIBlurEffect *glassBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self.glassBlurAnimator =
        [[UIViewPropertyAnimator alloc] initWithDuration:1.0 curve:UIViewAnimationCurveLinear animations:^{
            weakSelf.previewGlassView.effect = glassBlur;
        }];
    [self.glassBlurAnimator pauseAnimation];

    [self applyAppearancePreviewAndPersist:NO];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
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
    self.glassBlurAnimator.fractionComplete = glassBlur;

    // Transparency changes the dark density independently from blur. This gives
    // the preview a useful "more solid <-> more transparent" control.
    CGFloat shadeAlpha = 0.20 * (1.0 - transparency);
    self.previewShadeView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:shadeAlpha];
    self.previewTintView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha];

    CGFloat borderAlpha = 0.12 + ((1.0 - transparency) * 0.16);
    self.previewGlassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:borderAlpha].CGColor;

    self.backgroundBlurValueLabel.text = [NSString stringWithFormat:@"%.0f%%", backgroundBlur * 100.0];
    self.glassBlurValueLabel.text = [NSString stringWithFormat:@"%.0f%%", glassBlur * 100.0];
    self.glassTransparencyValueLabel.text = [NSString stringWithFormat:@"%.0f%%", transparency * 100.0];
    self.glassTintValueLabel.text = [NSString stringWithFormat:@"%.0f%%", (tintAlpha / 0.16) * 100.0];

    if (persist) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setFloat:backgroundBlur forKey:DOCustomGlassBackgroundBlurKey];
        [defaults setFloat:glassBlur forKey:DOCustomGlassBlurIntensityKey];
        [defaults setFloat:transparency forKey:DOCustomGlassTransparencyKey];
        [defaults setFloat:tintAlpha forKey:DOCustomGlassTintAlphaKey];
    }
}

- (void)restoreRecommendedAppearanceValues
{
    self.backgroundBlurSlider.value = 0.10;
    self.glassBlurSlider.value = 0.85;
    self.glassTransparencySlider.value = 0.70;
    self.glassTintSlider.value = 0.05;
    [self applyAppearancePreviewAndPersist:YES];
}

- (void)dealloc
{
    [self.backgroundBlurAnimator stopAnimation:YES];
    [self.glassBlurAnimator stopAnimation:YES];
}

@end

@interface DOCustomGlassThemeSettingsViewController : UIViewController
@end

@implementation DOCustomGlassThemeSettingsViewController

- (UIVisualEffectView *)themeGlassViewWithCornerRadius:(CGFloat)cornerRadius tintAlpha:(CGFloat)tintAlpha
{
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:blur];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    glassView.layer.cornerRadius = cornerRadius;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.layer.masksToBounds = YES;
    glassView.layer.borderWidth = 0.7;
    glassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    glassView.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha];
    return glassView;
}

- (UILabel *)themeSectionLabelWithText:(NSString *)text
{
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    return label;
}

- (UIVisualEffectView *)themeRowWithTitle:(NSString *)title
                                 subtitle:(NSString *)subtitle
                                imageName:(NSString *)imageName
                                   action:(UIAction *)action
{
    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    UIVisualEffectView *row = [self themeGlassViewWithCornerRadius:22.0 tintAlpha:0.045];

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

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DOCustomGlassBackgroundBlurKey : @0.10,
        DOCustomGlassBlurIntensityKey : @0.85,
        DOCustomGlassTransparencyKey : @0.70,
        DOCustomGlassTintAlphaKey : @0.05,
        DOCustomGlassUsernameKey : @"",
        DOCustomGlassMottoKey : @""
    }];

    BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;

    UIButton *backButton = DOCustomGlassBackButton(self);
    [self.view addSubview:backButton];
    [NSLayoutConstraint activateConstraints:@[
        [backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
        [backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4.0],
        [backButton.widthAnchor constraintEqualToConstant:44.0],
        [backButton.heightAnchor constraintEqualToConstant:40.0]
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

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [contentStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:(isPad ? 12.0 : 8.0)],
        [contentStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-32.0],
        [contentStack.centerXAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.centerXAnchor],
        [contentStack.widthAnchor constraintLessThanOrEqualToConstant:620.0]
    ]];

    NSLayoutConstraint *responsiveWidth =
        [contentStack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:(isPad ? -56.0 : -40.0)];
    responsiveWidth.priority = UILayoutPriorityDefaultHigh;
    responsiveWidth.active = YES;

    UILabel *appearanceLabel = [self themeSectionLabelWithText:@"外观"];
    [contentStack addArrangedSubview:appearanceLabel];

    __weak typeof(self) weakSelf = self;
    [contentStack addArrangedSubview:[self themeRowWithTitle:@"背景"
                                                    subtitle:@"选择首页背景图片"
                                                   imageName:@"photo"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf showThemePlaceholderForTitle:@"背景"];
    }]]];

    [contentStack addArrangedSubview:[self themeRowWithTitle:@"外观效果"
                                                    subtitle:@"实时调整壁纸模糊与 Glass"
                                                   imageName:@"slider.horizontal.3"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        DOCustomGlassAppearanceViewController *appearanceController =
            [[DOCustomGlassAppearanceViewController alloc] init];
        [weakSelf.navigationController pushViewController:appearanceController animated:YES];
    }]]];

    UIView *profileSpacer = [[UIView alloc] init];
    [contentStack addArrangedSubview:profileSpacer];
    [profileSpacer.heightAnchor constraintEqualToConstant:8.0].active = YES;

    UILabel *profileLabel = [self themeSectionLabelWithText:@"个人资料"];
    [contentStack addArrangedSubview:profileLabel];

    [contentStack addArrangedSubview:[self themeRowWithTitle:@"头像"
                                                    subtitle:@"选择个人头像"
                                                   imageName:@"person.crop.circle"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf showThemePlaceholderForTitle:@"头像"];
    }]]];

    [contentStack addArrangedSubview:[self themeRowWithTitle:@"用户名与个性签名"
                                                    subtitle:@"编辑首页显示的文字"
                                                   imageName:@"textformat"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf showThemePlaceholderForTitle:@"个人资料"];
    }]]];

    UIView *manageSpacer = [[UIView alloc] init];
    [contentStack addArrangedSubview:manageSpacer];
    [manageSpacer.heightAnchor constraintEqualToConstant:8.0].active = YES;

    UILabel *manageLabel = [self themeSectionLabelWithText:@"管理"];
    [contentStack addArrangedSubview:manageLabel];

    [contentStack addArrangedSubview:[self themeRowWithTitle:@"恢复默认"
                                                    subtitle:@"恢复 Custom Glass 默认配置"
                                                   imageName:@"arrow.counterclockwise"
                                                      action:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [weakSelf showThemePlaceholderForTitle:@"恢复默认"];
    }]]];
}

@end

@interface DOMainViewController ()

@property DOJailbreakButton *jailbreakBtn;
@property NSArray<NSLayoutConstraint *> *jailbreakButtonConstraints;
@property DOActionMenuButton *updateButton;
@property NSLayoutConstraint *customGlassJailbreakCenterYConstraint;
@property(nonatomic) BOOL hideStatusBar;
@property(nonatomic) BOOL hideHomeIndicator;

@end

@implementation DOMainViewController

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

- (UIVisualEffectView *)customGlassViewWithCornerRadius:(CGFloat)cornerRadius tintAlpha:(CGFloat)tintAlpha
{
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:blur];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    glassView.layer.cornerRadius = cornerRadius;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.layer.masksToBounds = YES;
    glassView.layer.borderWidth = 0.7;
    glassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    glassView.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha];
    return glassView;
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

- (UIVisualEffectView *)customGlassCardWithTitle:(NSString *)title imageName:(NSString *)imageName action:(UIAction *)action
{
    UIVisualEffectView *card = [self customGlassViewWithCornerRadius:24 tintAlpha:0.05];
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

- (UIVisualEffectView *)customGlassRestartButtonWithTitle:(NSString *)title imageName:(NSString *)imageName action:(UIAction *)action enabled:(BOOL)enabled cornerRadius:(CGFloat)cornerRadius
{
    UIVisualEffectView *innerGlass = [self customGlassViewWithCornerRadius:cornerRadius tintAlpha:0.08];
    innerGlass.alpha = enabled ? 1.0 : 0.45;

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
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.transform = CGAffineTransformMakeScale(restartIconOpticalScale, restartIconOpticalScale);
    [contentRow addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
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

    UIVisualEffectView *avatarGlass = [self customGlassViewWithCornerRadius:(avatarSize / 2.0) tintAlpha:0.06];
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
    [avatarGlass.contentView addSubview:avatarImageView];
    [NSLayoutConstraint activateConstraints:@[
        [avatarImageView.centerXAnchor constraintEqualToAnchor:avatarGlass.contentView.centerXAnchor],
        [avatarImageView.centerYAnchor constraintEqualToAnchor:avatarGlass.contentView.centerYAnchor],
        [avatarImageView.widthAnchor constraintEqualToConstant:avatarIconSize],
        [avatarImageView.heightAnchor constraintEqualToConstant:avatarIconSize]
    ]];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *username = [defaults stringForKey:@"RootHideCustomHomeUsername"] ?: @"RootHide User";
    NSString *motto = [defaults stringForKey:@"RootHideCustomHomeMotto"] ?: @"Your motto";

    UILabel *usernameLabel = [[UILabel alloc] init];
    usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    usernameLabel.text = username;
    usernameLabel.textColor = UIColor.whiteColor;
    usernameLabel.textAlignment = NSTextAlignmentCenter;
    usernameLabel.font = [UIFont systemFontOfSize:usernameFontSize weight:UIFontWeightSemibold];
    [profileView addSubview:usernameLabel];

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
    [profileView addSubview:mottoLabel];

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

    UIVisualEffectView *settingsCard = [self customGlassCardWithTitle:DOLocalizedString(@"Menu_Settings_Title") imageName:@"gearshape" action:settingsAction];
    UIVisualEffectView *creditsCard = [self customGlassCardWithTitle:DOLocalizedString(@"Menu_Credits_Title") imageName:@"info.circle" action:creditsAction];
    [leftColumn addArrangedSubview:settingsCard];
    [leftColumn addArrangedSubview:creditsCard];

    UIAction *themeAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        DOCustomGlassThemeSettingsViewController *themeSettingsController =
            [[DOCustomGlassThemeSettingsViewController alloc] init];
        [self.navigationController pushViewController:themeSettingsController animated:YES];
    }];
    UIVisualEffectView *themeCard = [self customGlassCardWithTitle:@"主题设置" imageName:@"slider.horizontal.3" action:themeAction];
    themeCard.layer.cornerRadius = themeCardHeight / 2.0;
    [rightColumn addArrangedSubview:themeCard];
    [themeCard.heightAnchor constraintEqualToConstant:themeCardHeight].active = YES;

    UIVisualEffectView *restartContainer = [self customGlassViewWithCornerRadius:24 tintAlpha:0.035];
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
    __block UIVisualEffectView *jailbreakEmphasisGlass = nil;

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
    jailbreakEmphasisGlass = [self customGlassViewWithCornerRadius:14.0 tintAlpha:0.10];
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
    [self.jailbreakBtn.button setTitle:[self jailbreakButtonTitle] forState:UIControlStateNormal];
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
