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

@interface DOMainViewController ()

@property DOJailbreakButton *jailbreakBtn;
@property NSArray<NSLayoutConstraint *> *jailbreakButtonConstraints;
@property DOActionMenuButton *updateButton;
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
    configuration.image = [UIImage systemImageNamed:imageName];
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

- (UIVisualEffectView *)customGlassRestartButtonWithTitle:(NSString *)title imageName:(NSString *)imageName action:(UIAction *)action enabled:(BOOL)enabled
{
    UIVisualEffectView *innerGlass = [self customGlassViewWithCornerRadius:18 tintAlpha:0.08];
    UIButton *button = [self customGlassButtonWithTitle:title imageName:imageName action:action];
    button.enabled = enabled;
    innerGlass.alpha = enabled ? 1.0 : 0.45;
    [innerGlass.contentView addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:innerGlass.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:innerGlass.contentView.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:innerGlass.contentView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:innerGlass.contentView.bottomAnchor]
    ]];
    return innerGlass;
}

- (void)setupCustomGlassHome
{
    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.alignment = UIStackViewAlignmentFill;
    mainStack.distribution = UIStackViewDistributionFill;
    mainStack.spacing = 12;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:mainStack];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        NSLayoutConstraint *relativeWidthConstraint = [mainStack.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8];
        relativeWidthConstraint.priority = UILayoutPriorityDefaultHigh;
        NSLayoutConstraint *maxWidthConstraint = [mainStack.widthAnchor constraintLessThanOrEqualToConstant:UI_IPAD_MAX_WIDTH];
        maxWidthConstraint.priority = UILayoutPriorityRequired;

        [NSLayoutConstraint activateConstraints:@[
            [mainStack.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8],
            [mainStack.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-8],
            [mainStack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            relativeWidthConstraint,
            maxWidthConstraint
        ]];
    }
    else {
        [NSLayoutConstraint activateConstraints:@[
            [mainStack.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8],
            [mainStack.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-8],
            [mainStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:UI_PADDING],
            [mainStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-UI_PADDING]
        ]];
    }

    DOHeaderView *headerView = [[DOHeaderView alloc] initWithImage:[UIImage imageNamed:@"Dopamine"] subtitles:@[
        [DOGlobalAppearance mainSubtitleString:[[DOEnvironmentManager sharedManager] versionSupportString]],
        [DOGlobalAppearance secondarySubtitleString:DOLocalizedString(@"Credits_Made_By") withAlpha:0.8],
        [DOGlobalAppearance secondarySubtitleString:@" " withAlpha:0.8]
    ]];
    [mainStack addArrangedSubview:headerView];

    UIView *profileView = [[UIView alloc] init];
    profileView.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:profileView];
    [profileView.heightAnchor constraintEqualToConstant:132].active = YES;

    UIVisualEffectView *avatarGlass = [self customGlassViewWithCornerRadius:34 tintAlpha:0.06];
    [profileView addSubview:avatarGlass];
    [NSLayoutConstraint activateConstraints:@[
        [avatarGlass.widthAnchor constraintEqualToConstant:68],
        [avatarGlass.heightAnchor constraintEqualToConstant:68],
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
        [avatarImageView.widthAnchor constraintEqualToConstant:42],
        [avatarImageView.heightAnchor constraintEqualToConstant:42]
    ]];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *username = [defaults stringForKey:@"RootHideCustomHomeUsername"] ?: @"RootHide User";
    NSString *motto = [defaults stringForKey:@"RootHideCustomHomeMotto"] ?: @"Your motto";

    UILabel *usernameLabel = [[UILabel alloc] init];
    usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    usernameLabel.text = username;
    usernameLabel.textColor = UIColor.whiteColor;
    usernameLabel.textAlignment = NSTextAlignmentCenter;
    usernameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [profileView addSubview:usernameLabel];

    UILabel *systemLabel = [[UILabel alloc] init];
    systemLabel.translatesAutoresizingMaskIntoConstraints = NO;
    systemLabel.text = [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
    systemLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    systemLabel.textAlignment = NSTextAlignmentCenter;
    systemLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [profileView addSubview:systemLabel];

    UILabel *mottoLabel = [[UILabel alloc] init];
    mottoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    mottoLabel.text = motto;
    mottoLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    mottoLabel.textAlignment = NSTextAlignmentCenter;
    mottoLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    mottoLabel.numberOfLines = 1;
    mottoLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [profileView addSubview:mottoLabel];

    [NSLayoutConstraint activateConstraints:@[
        [usernameLabel.topAnchor constraintEqualToAnchor:avatarGlass.bottomAnchor constant:5],
        [usernameLabel.leadingAnchor constraintEqualToAnchor:profileView.leadingAnchor constant:12],
        [usernameLabel.trailingAnchor constraintEqualToAnchor:profileView.trailingAnchor constant:-12],
        [systemLabel.topAnchor constraintEqualToAnchor:usernameLabel.bottomAnchor constant:1],
        [systemLabel.leadingAnchor constraintEqualToAnchor:profileView.leadingAnchor constant:12],
        [systemLabel.trailingAnchor constraintEqualToAnchor:profileView.trailingAnchor constant:-12],
        [mottoLabel.topAnchor constraintEqualToAnchor:systemLabel.bottomAnchor constant:3],
        [mottoLabel.leadingAnchor constraintEqualToAnchor:profileView.leadingAnchor constant:18],
        [mottoLabel.trailingAnchor constraintEqualToAnchor:profileView.trailingAnchor constant:-18]
    ]];

    UIView *actionGrid = [[UIView alloc] init];
    actionGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:actionGrid];
    NSLayoutConstraint *gridHeight = [actionGrid.heightAnchor constraintEqualToConstant:250];
    gridHeight.priority = UILayoutPriorityDefaultHigh;
    gridHeight.active = YES;

    UIStackView *leftColumn = [[UIStackView alloc] init];
    leftColumn.axis = UILayoutConstraintAxisVertical;
    leftColumn.alignment = UIStackViewAlignmentFill;
    leftColumn.distribution = UIStackViewDistributionFillEqually;
    leftColumn.spacing = 12;
    leftColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [actionGrid addSubview:leftColumn];

    UIStackView *rightColumn = [[UIStackView alloc] init];
    rightColumn.axis = UILayoutConstraintAxisVertical;
    rightColumn.alignment = UIStackViewAlignmentFill;
    rightColumn.distribution = UIStackViewDistributionFill;
    rightColumn.spacing = 12;
    rightColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [actionGrid addSubview:rightColumn];

    [NSLayoutConstraint activateConstraints:@[
        [leftColumn.leadingAnchor constraintEqualToAnchor:actionGrid.leadingAnchor],
        [leftColumn.topAnchor constraintEqualToAnchor:actionGrid.topAnchor],
        [leftColumn.bottomAnchor constraintEqualToAnchor:actionGrid.bottomAnchor],
        [leftColumn.widthAnchor constraintEqualToAnchor:actionGrid.widthAnchor multiplier:0.34],
        [rightColumn.leadingAnchor constraintEqualToAnchor:leftColumn.trailingAnchor constant:12],
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom Glass" message:@"Theme editor will be added in the next step." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Close") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    UIVisualEffectView *themeCard = [self customGlassCardWithTitle:@"Theme" imageName:@"photo.on.rectangle.angled" action:themeAction];
    [rightColumn addArrangedSubview:themeCard];
    [themeCard.heightAnchor constraintEqualToConstant:52].active = YES;

    UIVisualEffectView *restartContainer = [self customGlassViewWithCornerRadius:24 tintAlpha:0.035];
    [rightColumn addArrangedSubview:restartContainer];

    UIStackView *restartStack = [[UIStackView alloc] init];
    restartStack.axis = UILayoutConstraintAxisVertical;
    restartStack.alignment = UIStackViewAlignmentFill;
    restartStack.distribution = UIStackViewDistributionFillEqually;
    restartStack.spacing = 10;
    restartStack.translatesAutoresizingMaskIntoConstraints = NO;
    [restartContainer.contentView addSubview:restartStack];
    [NSLayoutConstraint activateConstraints:@[
        [restartStack.leadingAnchor constraintEqualToAnchor:restartContainer.contentView.leadingAnchor constant:12],
        [restartStack.trailingAnchor constraintEqualToAnchor:restartContainer.contentView.trailingAnchor constant:-12],
        [restartStack.topAnchor constraintEqualToAnchor:restartContainer.contentView.topAnchor constant:12],
        [restartStack.bottomAnchor constraintEqualToAnchor:restartContainer.contentView.bottomAnchor constant:-12]
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

    [restartStack addArrangedSubview:[self customGlassRestartButtonWithTitle:DOLocalizedString(@"Menu_Restart_SpringBoard_Title") imageName:@"arrow.clockwise" action:respringAction enabled:isJailbroken]];
    [restartStack addArrangedSubview:[self customGlassRestartButtonWithTitle:DOLocalizedString(@"Menu_Reboot_Userspace_Title") imageName:@"arrow.clockwise.circle" action:userspaceAction enabled:isJailbroken]];
    [restartStack addArrangedSubview:[self customGlassRestartButtonWithTitle:DOLocalizedString(@"Menu_Reboot_Device_Title") imageName:@"power" action:rebootAction enabled:YES]];

    // Keep a dedicated gap for the optional update button. setupUpdateAvailable:
    // positions that button above jailbreakBtn, so without this reserve it can overlap
    // the lower edge of the glass action grid.
    UIView *updateReserve = [[UIView alloc] init];
    updateReserve.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:updateReserve];
    CGFloat updateReserveHeight = [DOGlobalAppearance isHomeButtonDevice] ? 42.0 : 52.0;
    [updateReserve.heightAnchor constraintEqualToConstant:updateReserveHeight].active = YES;

    UIView *buttonPlaceHolder = [[UIView alloc] init];
    buttonPlaceHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack addArrangedSubview:buttonPlaceHolder];
    [buttonPlaceHolder.heightAnchor constraintEqualToConstant:60].active = YES;

    NSString *jailbreakButtonTitle = [self jailbreakButtonTitle];
    UIImage *jailbreakButtonImage = isSupported ?
        [UIImage systemImageNamed:@"lock.open" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]] :
        [UIImage systemImageNamed:@"lock.slash" withConfiguration:[DOGlobalAppearance smallIconImageConfiguration]];

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
    [self.view addSubview:self.jailbreakBtn];

    [NSLayoutConstraint activateConstraints:(self.jailbreakButtonConstraints = @[
        [self.jailbreakBtn.leadingAnchor constraintEqualToAnchor:buttonPlaceHolder.leadingAnchor],
        [self.jailbreakBtn.trailingAnchor constraintEqualToAnchor:buttonPlaceHolder.trailingAnchor],
        [self.jailbreakBtn.heightAnchor constraintEqualToAnchor:buttonPlaceHolder.heightAnchor],
        [self.jailbreakBtn.centerYAnchor constraintEqualToAnchor:buttonPlaceHolder.centerYAnchor]
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
