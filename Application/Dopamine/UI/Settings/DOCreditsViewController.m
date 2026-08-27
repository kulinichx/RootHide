//
//  DOCreditsViewController.m
//  Dopamine
//
//  Created by tomt000 on 08/01/2024.
//

#import "DOCreditsViewController.h"
#import "DOLicenseViewController.h"
#import "DOUIManager.h"
#import "DOEnvironmentManager.h"
#import <Preferences/PSSpecifier.h>

#pragma mark - Custom Glass page appearance

static NSString * const DOCustomGlassCreditsBackgroundBlurKey = @"DOCustomGlassTheme.BackgroundBlur";
static NSString * const DOCustomGlassCreditsDidChangeNotification = @"DOCustomGlassTheme.DidChange";

static NSString *DOCustomGlassCreditsBackgroundFilePath(void)
{
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (applicationSupport.length == 0)
        return nil;
    return [[applicationSupport stringByAppendingPathComponent:@"CustomGlass"]
        stringByAppendingPathComponent:@"background.jpg"];
}

@interface DOCustomLiquidGlassView : UIView
@property(nonatomic, assign) CGFloat materialScale;
@property(nonatomic, assign) BOOL suppressBackdrop;
@property(nonatomic, assign) CGFloat preferredCornerRadius;
- (instancetype)initWithCornerRadius:(CGFloat)cornerRadius baseTintAlpha:(CGFloat)baseTintAlpha;
- (void)reloadMaterial;
@end

@interface DOCustomWallpaperBlurView : UIView
- (void)setBlurIntensity:(CGFloat)blurIntensity;
@end

@interface DOCreditsViewController ()

@property(nonatomic, strong) UIView *customGlassPageBackgroundHostView;
@property(nonatomic, strong) UIImageView *customGlassPageBackgroundImageView;
@property(nonatomic, strong) DOCustomWallpaperBlurView *customGlassPageBackgroundBlurView;

@end

@implementation DOCreditsViewController

- (void)customGlassReloadPageBackground
{
    NSString *path = DOCustomGlassCreditsBackgroundFilePath();
    UIImage *image = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    self.customGlassPageBackgroundImageView.image = image;
    self.customGlassPageBackgroundImageView.hidden = image == nil;
}

- (void)customGlassImproveReadabilityInView:(UIView *)view header:(BOOL)isHeader
{
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        CGFloat alpha = isHeader ? 0.76 : (label.font.pointSize >= 15.0 ? 0.96 : 0.84);
        label.textColor = [UIColor colorWithWhite:1.0 alpha:alpha];
        label.shadowColor = [UIColor colorWithWhite:0.0 alpha:(isHeader ? 0.18 : 0.26)];
        label.shadowOffset = CGSizeMake(0.0, 0.5);
    }

    for (UIView *subview in view.subviews)
        [self customGlassImproveReadabilityInView:subview header:isHeader];
}

- (void)customGlassStyleVisibleCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath
{
    if (!cell)
        return;

    NSString *className = NSStringFromClass(cell.class);
    if ([className containsString:@"HeaderCell"]) {
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.backgroundView = nil;
        [self customGlassImproveReadabilityInView:cell.contentView header:YES];
        return;
    }

    BOOL isCreditsContentCell = [className containsString:@"CreditsCell"];
    UITableView *tableView = [self valueForKey:@"table"];
    NSInteger rowCount = indexPath ? [tableView numberOfRowsInSection:indexPath.section] : 1;
    BOOL firstRow = !indexPath || indexPath.row == 0;
    BOOL lastRow = !indexPath || indexPath.row == MAX(0, rowCount - 1);
    BOOL singleRow = firstRow && lastRow;

    // Links read as one compact Section Glass. DOCreditsCell is a tall custom
    // surface containing the people groups, so give that content one coherent
    // medium/large Glass backplate instead of letting names float directly over
    // arbitrary bright/dark wallpaper regions.
    DOCustomLiquidGlassView *glass = nil;
    if ([cell.backgroundView isKindOfClass:[DOCustomLiquidGlassView class]]) {
        glass = (DOCustomLiquidGlassView *)cell.backgroundView;
    }
    else {
        CGFloat radius = isCreditsContentCell ? 24.0 : 16.0;
        CGFloat tint = isCreditsContentCell ? 0.040 : 0.032;
        glass = [[DOCustomLiquidGlassView alloc] initWithCornerRadius:radius baseTintAlpha:tint];
        glass.userInteractionEnabled = NO;
        cell.backgroundView = glass;

        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.060];
        selected.layer.cornerCurve = kCACornerCurveContinuous;
        cell.selectedBackgroundView = selected;
    }

    glass.suppressBackdrop = NO;
    glass.materialScale = isCreditsContentCell ? 0.90 : 0.78;

    if (isCreditsContentCell) {
        glass.preferredCornerRadius = 24.0;
        glass.layer.cornerRadius = 24.0;
        glass.layer.maskedCorners =
            kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
            kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    }
    else {
        glass.preferredCornerRadius = (singleRow || firstRow || lastRow) ? 16.0 : 0.0;
        glass.layer.cornerRadius = glass.preferredCornerRadius;
        if (singleRow) {
            glass.layer.maskedCorners =
                kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        }
        else if (firstRow) {
            glass.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        }
        else if (lastRow) {
            glass.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        }
        else {
            glass.layer.maskedCorners = 0;
        }
    }

    cell.selectedBackgroundView.layer.cornerRadius = glass.preferredCornerRadius;
    cell.selectedBackgroundView.layer.maskedCorners = glass.layer.maskedCorners;
    [glass reloadMaterial];

    if (!isCreditsContentCell && !singleRow && !firstRow && !lastRow)
        glass.layer.borderWidth *= 0.42;

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    [self customGlassImproveReadabilityInView:cell.contentView header:NO];
}

- (void)customGlassApplyPageAppearance
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat blur = [defaults objectForKey:DOCustomGlassCreditsBackgroundBlurKey] ?
        [defaults floatForKey:DOCustomGlassCreditsBackgroundBlurKey] : 0.10;
    blur = MIN(1.0, MAX(0.0, blur));
    [self.customGlassPageBackgroundBlurView setBlurIntensity:blur];

    UITableView *tableView = [self valueForKey:@"table"];
    for (UITableViewCell *cell in tableView.visibleCells)
        [self customGlassStyleVisibleCell:cell atIndexPath:[tableView indexPathForCell:cell]];
}

- (void)customGlassRefreshPageAppearance
{
    [self customGlassReloadPageBackground];
    [self customGlassApplyPageAppearance];

    [self.customGlassPageBackgroundBlurView.layer setNeedsDisplay];
    [self.customGlassPageBackgroundBlurView setNeedsLayout];

    UITableView *tableView = [self valueForKey:@"table"];
    [tableView setNeedsLayout];
    [tableView layoutIfNeeded];
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

    [self customGlassRefreshPageAppearance];
}

- (void)customGlassInstallPageAppearance
{
    UIView *backgroundHostParent = self.navigationController.view ?: self.view;

    self.customGlassPageBackgroundHostView = [[UIView alloc] init];
    self.customGlassPageBackgroundHostView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassPageBackgroundHostView.backgroundColor = UIColor.clearColor;
    self.customGlassPageBackgroundHostView.userInteractionEnabled = NO;
    [backgroundHostParent insertSubview:self.customGlassPageBackgroundHostView atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassPageBackgroundHostView.leadingAnchor constraintEqualToAnchor:backgroundHostParent.leadingAnchor],
        [self.customGlassPageBackgroundHostView.trailingAnchor constraintEqualToAnchor:backgroundHostParent.trailingAnchor],
        [self.customGlassPageBackgroundHostView.topAnchor constraintEqualToAnchor:backgroundHostParent.topAnchor],
        [self.customGlassPageBackgroundHostView.bottomAnchor constraintEqualToAnchor:backgroundHostParent.bottomAnchor]
    ]];

    self.customGlassPageBackgroundImageView = [[UIImageView alloc] init];
    self.customGlassPageBackgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassPageBackgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.customGlassPageBackgroundImageView.clipsToBounds = YES;
    self.customGlassPageBackgroundImageView.userInteractionEnabled = NO;
    self.customGlassPageBackgroundImageView.hidden = YES;
    [self.customGlassPageBackgroundHostView addSubview:self.customGlassPageBackgroundImageView];

    self.customGlassPageBackgroundBlurView = [[DOCustomWallpaperBlurView alloc] initWithFrame:CGRectZero];
    self.customGlassPageBackgroundBlurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.customGlassPageBackgroundHostView addSubview:self.customGlassPageBackgroundBlurView];

    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassPageBackgroundImageView.leadingAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.leadingAnchor],
        [self.customGlassPageBackgroundImageView.trailingAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.trailingAnchor],
        [self.customGlassPageBackgroundImageView.topAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.topAnchor],
        [self.customGlassPageBackgroundImageView.bottomAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.bottomAnchor],
        [self.customGlassPageBackgroundBlurView.leadingAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.leadingAnchor],
        [self.customGlassPageBackgroundBlurView.trailingAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.trailingAnchor],
        [self.customGlassPageBackgroundBlurView.topAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.topAnchor],
        [self.customGlassPageBackgroundBlurView.bottomAnchor constraintEqualToAnchor:self.customGlassPageBackgroundHostView.bottomAnchor]
    ]];

    self.view.backgroundColor = UIColor.clearColor;

    UITableView *tableView = [self valueForKey:@"table"];
    tableView.backgroundColor = UIColor.clearColor;
    tableView.opaque = NO;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.backgroundView = nil;
    tableView.layer.cornerRadius = 0.0;
    tableView.layer.masksToBounds = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(customGlassThemeDidChange:)
                                                 name:DOCustomGlassCreditsDidChangeNotification
                                               object:nil];

    [self customGlassRefreshPageAppearance];
}


- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self customGlassStyleVisibleCell:cell atIndexPath:indexPath];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self customGlassInstallPageAppearance];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self customGlassRefreshPageAppearance];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf customGlassRefreshPageAppearance];
    });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self customGlassRefreshPageAppearance];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DOCustomGlassCreditsDidChangeNotification
                                                  object:nil];
    [self.customGlassPageBackgroundHostView removeFromSuperview];
}

- (id)specifiers
{
    if(_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Credits" target:self];

        PSSpecifier *headerSpecifier = _specifiers[0];
        [headerSpecifier setProperty:[NSString stringWithFormat:@"Dopamine %@ - %@", [DOEnvironmentManager sharedManager].appVersionDisplayString, DOLocalizedString(@"Menu_Credits_Title")] forKey:@"title"];
    }
    return _specifiers;
}

- (void)openSourceCode
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/roothide/Dopamine2-roothide"] options:@{} completionHandler:nil];
}

- (void)openDiscord
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://discord.gg/jb"] options:@{} completionHandler:nil];
}

- (void)openLicense
{
    [self.navigationController pushViewController:[[DOLicenseViewController alloc] init] animated:YES];
}

@end
