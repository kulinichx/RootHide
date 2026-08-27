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

static NSString * const DOCustomGlassCreditsDidChangeNotification = @"DOCustomGlassTheme.DidChange";
static NSInteger const DOCustomGlassCreditsSeparatorTag = 0xC652;

@interface DOCustomLiquidGlassView : UIView
@property(nonatomic, assign) CGFloat materialScale;
@property(nonatomic, assign) BOOL suppressBackdrop;
@property(nonatomic, assign) CGFloat preferredCornerRadius;
- (instancetype)initWithCornerRadius:(CGFloat)cornerRadius baseTintAlpha:(CGFloat)baseTintAlpha;
- (void)reloadMaterial;
@end

@interface DOCreditsViewController ()

@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DOCustomLiquidGlassView *> *customGlassSectionBackdropViews;

@end

@implementation DOCreditsViewController

- (UIColor *)customGlassForegroundWithAlpha:(CGFloat)alpha
{
    return [UIColor.labelColor colorWithAlphaComponent:alpha];
}

- (void)customGlassImproveReadabilityInView:(UIView *)view
                                     header:(BOOL)isHeader
{
    // Preferences may reconfigure reused cells after willDisplayCell. Make the
    // trait environment authoritative instead of fighting it with sampled
    // black/white colors. Semantic label colors now always resolve in Dark mode
    // on both iPhone and iPad.
    view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    if ([view isKindOfClass:[UISwitch class]] ||
        [view isKindOfClass:[UISlider class]] ||
        [view isKindOfClass:[UISegmentedControl class]]) {
        return;
    }

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        CGFloat alpha = isHeader ? 0.74 : (label.font.pointSize >= 15.0 ? 0.96 : 0.84);
        label.textColor = [self customGlassForegroundWithAlpha:alpha];
        label.shadowColor = [UIColor colorWithWhite:0.0 alpha:(isHeader ? 0.10 : 0.14)];
        label.shadowOffset = CGSizeMake(0.0, 0.35);
    }
    else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        UIColor *foreground = [self customGlassForegroundWithAlpha:0.96];
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
            imageView.tintColor = [self customGlassForegroundWithAlpha:0.92];
    }

    for (UIView *subview in view.subviews)
        [self customGlassImproveReadabilityInView:subview header:isHeader];
}

- (void)customGlassHideHeaderHairlinesInView:(UIView *)view
{
    for (UIView *subview in view.subviews) {
        CGFloat height = CGRectGetHeight(subview.bounds);
        CGFloat width = CGRectGetWidth(subview.bounds);
        BOOL isSimpleHairline = ![subview isKindOfClass:[UILabel class]] &&
                                ![subview isKindOfClass:[UIButton class]] &&
                                ![subview isKindOfClass:[UIImageView class]] &&
                                height > 0.0 && height <= 1.25 && width >= 48.0;
        if (isSimpleHairline)
            subview.hidden = YES;
        [self customGlassHideHeaderHairlinesInView:subview];
    }
}

- (void)customGlassCleanupTableHairlines
{
    UITableView *tableView = [self valueForKey:@"table"];
    if (!tableView)
        return;

    // Remove only horizontal 1-2 px chrome. Vertical scroll indicators are
    // intentionally preserved. Run after layout because Preferences header
    // hairlines often have a zero frame earlier in the lifecycle.
    [self customGlassHideHeaderHairlinesInView:tableView];
    for (UITableViewCell *cell in tableView.visibleCells) {
        if ([NSStringFromClass(cell.class) containsString:@"HeaderCell"]) {
            cell.layer.borderWidth = 0.0;
            cell.contentView.layer.borderWidth = 0.0;
            cell.layer.shadowOpacity = 0.0;
            [self customGlassHideHeaderHairlinesInView:cell];
        }
    }
}

- (void)customGlassRemoveNestedChromeInView:(UIView *)view
{
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        button.backgroundColor = UIColor.clearColor;
        button.layer.borderWidth = 0.0;
        button.layer.shadowOpacity = 0.0;
    }
    else if (view.layer.borderWidth > 0.1) {
        view.layer.borderWidth = 0.0;
    }

    for (UIView *subview in view.subviews)
        [self customGlassRemoveNestedChromeInView:subview];
}

- (void)customGlassConfigureSeparatorForCell:(UITableViewCell *)cell indexPath:(NSIndexPath *)indexPath
{
    // R11: the Section Glass perimeter is the only structural line. Remove
    // the custom 0.5pt row separators so Settings/About cannot accumulate
    // extra horizontal rules during reuse or relayout.
    UIView *separator = [cell.contentView viewWithTag:DOCustomGlassCreditsSeparatorTag];
    [separator removeFromSuperview];
}

- (void)customGlassStyleVisibleCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath
{
    if (!cell)
        return;

    cell.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    cell.contentView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    NSString *className = NSStringFromClass(cell.class);
    BOOL isHeader = [className containsString:@"HeaderCell"];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = nil;

    if (isHeader) {
        cell.selectedBackgroundView = nil;
        UIView *separator = [cell.contentView viewWithTag:DOCustomGlassCreditsSeparatorTag];
        separator.hidden = YES;
        cell.layer.borderWidth = 0.0;
        cell.contentView.layer.borderWidth = 0.0;
        cell.layer.shadowOpacity = 0.0;
        [self customGlassRemoveNestedChromeInView:cell.contentView];
        [self customGlassHideHeaderHairlinesInView:cell];
        [self customGlassImproveReadabilityInView:cell.contentView header:YES];
        return;
    }

    UIView *selected = cell.selectedBackgroundView;
    if (!selected) {
        selected = [[UIView alloc] initWithFrame:CGRectZero];
        cell.selectedBackgroundView = selected;
    }
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.050];

    [self customGlassRemoveNestedChromeInView:cell.contentView];
    [self customGlassConfigureSeparatorForCell:cell indexPath:indexPath];
    [self customGlassImproveReadabilityInView:cell.contentView header:NO];
}

- (void)customGlassRefreshSectionBackdrops
{
    UITableView *tableView = [self valueForKey:@"table"];
    if (!tableView)
        return;

    if (!self.customGlassSectionBackdropViews)
        self.customGlassSectionBackdropViews = [NSMutableDictionary dictionary];

    NSInteger sectionCount = [tableView numberOfSections];
    NSMutableSet<NSNumber *> *activeKeys = [NSMutableSet set];
    for (NSInteger section = 0; section < sectionCount; section++) {
        NSInteger rowCount = [tableView numberOfRowsInSection:section];
        if (rowCount <= 0)
            continue;

        NSInteger firstMaterialRow = 0;
        UITableViewCell *firstCell = [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:section]];
        if ([NSStringFromClass(firstCell.class) containsString:@"HeaderCell"] && rowCount > 1)
            firstMaterialRow = 1;
        if (firstMaterialRow >= rowCount)
            continue;

        NSIndexPath *firstIndexPath = [NSIndexPath indexPathForRow:firstMaterialRow inSection:section];
        NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:rowCount - 1 inSection:section];
        CGRect firstRect = [tableView rectForRowAtIndexPath:firstIndexPath];
        CGRect lastRect = [tableView rectForRowAtIndexPath:lastIndexPath];
        CGRect sectionRect = CGRectUnion(firstRect, lastRect);
        if (CGRectIsEmpty(sectionRect) || CGRectGetHeight(sectionRect) < 2.0)
            continue;

        NSNumber *key = @(section);
        [activeKeys addObject:key];
        DOCustomLiquidGlassView *glass = self.customGlassSectionBackdropViews[key];
        if (!glass) {
            BOOL isTallSection = CGRectGetHeight(sectionRect) > 220.0;
            glass = [[DOCustomLiquidGlassView alloc] initWithCornerRadius:(isTallSection ? 24.0 : 18.0)
                                                             baseTintAlpha:(isTallSection ? 0.044 : 0.038)];
            glass.userInteractionEnabled = NO;
            glass.materialScale = isTallSection ? 0.94 : 0.88;
            self.customGlassSectionBackdropViews[key] = glass;
            [tableView insertSubview:glass atIndex:0];
        }

        BOOL isTallSection = CGRectGetHeight(sectionRect) > 220.0;
        CGFloat radius = isTallSection ? 24.0 : 18.0;
        glass.hidden = NO;
        glass.frame = CGRectInset(sectionRect, 1.0, 0.5);
        glass.preferredCornerRadius = radius;
        glass.layer.cornerRadius = radius;
        glass.layer.maskedCorners =
            kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
            kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        glass.materialScale = isTallSection ? 0.94 : 0.88;
        [glass reloadMaterial];
        [tableView sendSubviewToBack:glass];
    }

    [self.customGlassSectionBackdropViews enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, DOCustomLiquidGlassView *glass, BOOL *stop) {
        if (![activeKeys containsObject:key])
            glass.hidden = YES;
    }];
}

- (void)customGlassApplyPageAppearance
{
    UITableView *tableView = [self valueForKey:@"table"];
    [self customGlassRefreshSectionBackdrops];
    for (UITableViewCell *cell in tableView.visibleCells)
        [self customGlassStyleVisibleCell:cell atIndexPath:[tableView indexPathForCell:cell]];
    [self customGlassRefreshSectionBackdrops];
}

- (void)customGlassRefreshPageAppearance
{
    [self customGlassApplyPageAppearance];
    UITableView *tableView = [self valueForKey:@"table"];
    [tableView setNeedsLayout];
    [tableView layoutIfNeeded];
    [self customGlassRefreshSectionBackdrops];

    UIView *backButton = [self.view viewWithTag:0xC654];
    if ([backButton isKindOfClass:[UIButton class]]) {
        ((UIButton *)backButton).tintColor = [self customGlassForegroundWithAlpha:0.96];
    }
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

- (void)customGlassBackPressed
{
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)customGlassEdgeBackGesture:(UIScreenEdgePanGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded)
        return;

    CGPoint translation = [gesture translationInView:self.view];
    CGPoint velocity = [gesture velocityInView:self.view];
    if (translation.x > 60.0 && velocity.x > 80.0)
        [self.navigationController popViewControllerAnimated:YES];
}

- (void)customGlassInstallBackNavigation
{
    static NSInteger const DOCustomGlassCreditsBackButtonTag = 0xC654;
    if ([self.view viewWithTag:DOCustomGlassCreditsBackButtonTag])
        return;

    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    backButton.tag = DOCustomGlassCreditsBackButtonTag;
    backButton.translatesAutoresizingMaskIntoConstraints = NO;
    backButton.backgroundColor = UIColor.clearColor;
    backButton.tintColor = UIColor.whiteColor;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightMedium];
    [backButton setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:configuration]
                forState:UIControlStateNormal];
    [backButton addTarget:self action:@selector(customGlassBackPressed)
         forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:backButton];

    [NSLayoutConstraint activateConstraints:@[
        [backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:10.0],
        [backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6.0],
        [backButton.widthAnchor constraintEqualToConstant:44.0],
        [backButton.heightAnchor constraintEqualToConstant:44.0]
    ]];

    UIScreenEdgePanGestureRecognizer *edgeGesture =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(customGlassEdgeBackGesture:)];
    edgeGesture.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edgeGesture];
}

- (void)customGlassInstallPageAppearance
{
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;

    UITableView *tableView = [self valueForKey:@"table"];
    tableView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.opaque = NO;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.separatorColor = UIColor.clearColor;
    tableView.backgroundView = nil;
    tableView.layer.cornerRadius = 0.0;
    tableView.layer.borderWidth = 0.0;
    tableView.layer.masksToBounds = NO;

    self.customGlassSectionBackdropViews = [NSMutableDictionary dictionary];
    [self customGlassInstallBackNavigation];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(customGlassThemeDidChange:)
                                                 name:DOCustomGlassCreditsDidChangeNotification
                                               object:nil];

    [self customGlassRefreshPageAppearance];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self customGlassStyleVisibleCell:cell atIndexPath:indexPath];

    __weak typeof(self) weakSelf = self;
    __weak UITableViewCell *weakCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableViewCell *strongCell = weakCell;
        if (strongCell && strongCell.window) {
            NSIndexPath *currentIndexPath = [tableView indexPathForCell:strongCell];
            if (currentIndexPath)
                [weakSelf customGlassStyleVisibleCell:strongCell atIndexPath:currentIndexPath];
        }
        [weakSelf customGlassRefreshSectionBackdrops];
    });
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self customGlassRefreshSectionBackdrops];
    [self customGlassCleanupTableHairlines];
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
    [self customGlassCleanupTableHairlines];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DOCustomGlassCreditsDidChangeNotification
                                                  object:nil];
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
