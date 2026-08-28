//
//  DOSettingsController.m
//  Dopamine
//
//  Created by tomt000 on 08/01/2024.
//

#import "DOSettingsController.h"
#import <objc/runtime.h>
#import <Photos/Photos.h>
#import <libjailbreak/util.h>
#import "DOUIManager.h"
#import "DOPkgManagerPickerViewController.h"
#import "DOHeaderCell.h"
#import "DOEnvironmentManager.h"
#import "DOExploitManager.h"
#import "DOPSListItemsController.h"
#import "DOPSExploitListItemsController.h"
#import "DOThemeManager.h"
#import "DOSceneDelegate.h"
#import "DOPSJetsamListItemsController.h"
#import "DOButtonCell.h"
#import "../DOSupporterLicense.h"

#pragma mark - Custom Glass page appearance

static NSString * const DOCustomGlassSettingsDidChangeNotification = @"DOCustomGlassTheme.DidChange";
static NSInteger const DOCustomGlassSettingsSeparatorTag = 0xC651;

// Implemented in DOMainViewController.m. Keeping the declaration local avoids
// adding a new project file while letting Settings consume the same renderer.
@interface DOCustomLiquidGlassView : UIView
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, assign) CGFloat materialScale;
@property(nonatomic, assign) BOOL suppressBackdrop;
@property(nonatomic, assign) CGFloat preferredCornerRadius;
- (instancetype)initWithCornerRadius:(CGFloat)cornerRadius baseTintAlpha:(CGFloat)baseTintAlpha;
- (void)reloadMaterial;
@end

@interface DORootHideHealthViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) DOCustomLiquidGlassView *sectionGlassView;
@property(nonatomic, strong) UIButton *backButton;
@property(nonatomic, strong) UIButton *refreshButton;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *healthReport;
@property(nonatomic, assign) BOOL refreshInProgress;
@property(nonatomic, assign) BOOL repairInProgress;
@end

@implementation DORootHideHealthViewController

- (instancetype)init
{
    return [super initWithNibName:nil bundle:nil];
}

- (UIColor *)healthForegroundWithAlpha:(CGFloat)alpha
{
    return [UIColor.labelColor colorWithAlphaComponent:alpha];
}

- (UIButton *)healthChromeButtonWithSystemImage:(NSString *)systemImage action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = UIColor.clearColor;
    button.tintColor = [self healthForegroundWithAlpha:0.96];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:systemImage withConfiguration:configuration]
             forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"RootHide Health";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.opaque = NO;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.separatorColor = UIColor.clearColor;
    tableView.backgroundView = nil;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 56.0;
    tableView.contentInset = UIEdgeInsetsMake(58.0, 0.0, 0.0, 0.0);
    tableView.scrollIndicatorInsets = tableView.contentInset;
    self.tableView = tableView;
    [self.view addSubview:tableView];

    self.backButton = [self healthChromeButtonWithSystemImage:@"chevron.left" action:@selector(backPressed)];
    [self.view addSubview:self.backButton];

    self.refreshButton = [self healthChromeButtonWithSystemImage:@"arrow.clockwise" action:@selector(refreshHealth)];
    [self.view addSubview:self.refreshButton];

    [NSLayoutConstraint activateConstraints:@[
        [tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:10.0],
        [self.backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6.0],
        [self.backButton.widthAnchor constraintEqualToConstant:44.0],
        [self.backButton.heightAnchor constraintEqualToConstant:44.0],

        [self.refreshButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-10.0],
        [self.refreshButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6.0],
        [self.refreshButton.widthAnchor constraintEqualToConstant:44.0],
        [self.refreshButton.heightAnchor constraintEqualToConstant:44.0],
    ]];

    DOCustomLiquidGlassView *glass = [[DOCustomLiquidGlassView alloc] initWithCornerRadius:18.0 baseTintAlpha:0.038];
    glass.userInteractionEnabled = NO;
    glass.materialScale = 0.88;
    glass.preferredCornerRadius = 18.0;
    glass.layer.cornerRadius = 18.0;
    glass.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
        kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    self.sectionGlassView = glass;
    [tableView insertSubview:glass atIndex:0];

    UIScreenEdgePanGestureRecognizer *edgeGesture =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeBackGesture:)];
    edgeGesture.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edgeGesture];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(healthThemeDidChange:)
                                                 name:DOCustomGlassSettingsDidChangeNotification
                                               object:nil];

    [self refreshHealth];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshGlassAppearance];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self refreshGlassAppearance];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DOCustomGlassSettingsDidChangeNotification
                                                  object:nil];
}

- (void)healthThemeDidChange:(NSNotification *)notification
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf healthThemeDidChange:notification];
        });
        return;
    }
    [self refreshGlassAppearance];
}

- (void)backPressed
{
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)edgeBackGesture:(UIScreenEdgePanGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded)
        return;

    CGPoint translation = [gesture translationInView:self.view];
    CGPoint velocity = [gesture velocityInView:self.view];
    if (translation.x > 60.0 && velocity.x > 80.0)
        [self.navigationController popViewControllerAnimated:YES];
}

- (void)refreshGlassAppearance
{
    self.backButton.tintColor = [self healthForegroundWithAlpha:0.96];
    self.refreshButton.tintColor = [self healthForegroundWithAlpha:0.96];

    NSInteger rowCount = [self.tableView numberOfRowsInSection:0];
    if (rowCount <= 0) {
        self.sectionGlassView.hidden = YES;
        return;
    }

    NSIndexPath *firstIndexPath = [NSIndexPath indexPathForRow:0 inSection:0];
    NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:rowCount - 1 inSection:0];
    CGRect firstRect = [self.tableView rectForRowAtIndexPath:firstIndexPath];
    CGRect lastRect = [self.tableView rectForRowAtIndexPath:lastIndexPath];
    CGRect sectionRect = CGRectUnion(firstRect, lastRect);
    if (CGRectIsEmpty(sectionRect) || CGRectGetHeight(sectionRect) < 2.0) {
        self.sectionGlassView.hidden = YES;
        return;
    }

    self.sectionGlassView.hidden = NO;
    self.sectionGlassView.frame = CGRectInset(sectionRect, 1.0, 0.5);
    [self.sectionGlassView reloadMaterial];
    [self.tableView sendSubviewToBack:self.sectionGlassView];
}

- (void)refreshHealth
{
    if (self.refreshInProgress || self.repairInProgress) return;
    self.refreshInProgress = YES;
    self.refreshButton.enabled = NO;
    self.refreshButton.alpha = 0.45;
    [self.tableView reloadData];
    [self refreshGlassAppearance];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary<NSString *, id> *> *report = [[DOEnvironmentManager sharedManager] rootHideHealthReport];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.healthReport = report ?: @[];
            self.refreshInProgress = NO;
            self.refreshButton.enabled = YES;
            self.refreshButton.alpha = 1.0;
            [self.tableView reloadData];
            [self.tableView layoutIfNeeded];
            [self refreshGlassAppearance];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (!self.healthReport.count && self.refreshInProgress) return 1;
    return self.healthReport.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Bootstrap and Injection are detection-only. Repair is offered only where RootHide already has a bounded repair primitive.";
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
        label.textColor = [self healthForegroundWithAlpha:0.68];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString * const CellIdentifier = @"RootHideHealthCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];

    cell.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    cell.contentView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = nil;

    UIView *selected = cell.selectedBackgroundView;
    if (!selected) {
        selected = [[UIView alloc] initWithFrame:CGRectZero];
        cell.selectedBackgroundView = selected;
    }
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.050];

    if (!self.healthReport.count && self.refreshInProgress) {
        cell.textLabel.text = @"Checking RootHide Health…";
        cell.textLabel.textColor = [self healthForegroundWithAlpha:0.96];
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSDictionary<NSString *, id> *entry = self.healthReport[indexPath.row];
    NSString *stateName = entry[@"StateName"] ?: @"Unknown";
    BOOL healthy = [entry[@"Healthy"] boolValue];
    BOOL repairable = [entry[@"Repairable"] boolValue];

    cell.textLabel.text = entry[@"DisplayName"] ?: @"RootHide Health";
    cell.textLabel.textColor = [self healthForegroundWithAlpha:0.96];
    cell.detailTextLabel.text = stateName;
    cell.detailTextLabel.numberOfLines = 1;
    if (@available(iOS 13.0, *)) {
        if ([stateName isEqualToString:@"Not Selected"])
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        else
            cell.detailTextLabel.textColor = healthy ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    }
    cell.accessoryType = (repairable || [entry[@"Detail"] length]) ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = cell.accessoryType == UITableViewCellAccessoryNone ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.repairInProgress || indexPath.row >= self.healthReport.count) return;

    NSDictionary<NSString *, id> *entry = self.healthReport[indexPath.row];
    BOOL repairable = [entry[@"Repairable"] boolValue];
    NSString *stateName = entry[@"StateName"] ?: @"Unknown";
    NSString *detail = entry[@"Detail"];
    NSString *message = detail.length ? [NSString stringWithFormat:@"%@\n\n%@", stateName, detail] : stateName;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:entry[@"DisplayName"] ?: @"RootHide Health"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK") style:UIAlertActionStyleCancel handler:nil]];
    if (repairable) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Repair" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self repairEntry:entry];
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)repairEntry:(NSDictionary<NSString *, id> *)entry
{
    if (self.repairInProgress) return;
    NSString *kind = entry[@"Kind"];
    if (![kind isEqualToString:@"JailbreakApps"] && ![kind isEqualToString:@"PackageManager"]) return;

    self.repairInProgress = YES;
    self.refreshButton.enabled = NO;
    self.refreshButton.alpha = 0.45;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *repairError = nil;
        if ([kind isEqualToString:@"JailbreakApps"]) {
            repairError = [[DOEnvironmentManager sharedManager] repairJailbreakApps];
        }
        else {
            repairError = [[DOEnvironmentManager sharedManager] repairPackageManagers];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.repairInProgress = NO;
            self.refreshButton.enabled = YES;
            self.refreshButton.alpha = 1.0;

            NSString *title = repairError ? @"RootHide Health Repair Failed" : @"Repair Complete";
            NSString *message = repairError.localizedDescription ?: @"The selected RootHide component is healthy.";
            UIAlertController *resultAlert = [UIAlertController alertControllerWithTitle:title
                                                                                   message:message
                                                                            preferredStyle:UIAlertControllerStyleAlert];
            [resultAlert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK")
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(__unused UIAlertAction *action) {
                [self refreshHealth];
            }]];
            [self presentViewController:resultAlert animated:YES completion:nil];
        });
    });
}

@end

@interface DOSettingsController ()

@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DOCustomLiquidGlassView *> *customGlassSectionBackdropViews;

@end

@implementation DOSettingsController

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
                                ![subview isKindOfClass:[UIControl class]] &&
                                height > 0.0 && height <= 2.0 && width >= 40.0;
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
    else if (![view isKindOfClass:[UISwitch class]] &&
             ![view isKindOfClass:[UISlider class]] &&
             view.layer.borderWidth > 0.1) {
        // Preferences action cells often draw their own rounded inner outline.
        // The Section Glass owns the only perimeter in Custom Glass mode.
        view.layer.borderWidth = 0.0;
    }

    for (UIView *subview in view.subviews)
        [self customGlassRemoveNestedChromeInView:subview];
}

- (void)customGlassConfigureSeparatorForCell:(UITableViewCell *)cell
                                  indexPath:(NSIndexPath *)indexPath
{
    // R11: the Section Glass perimeter is the only structural line. Remove
    // the custom 0.5pt row separators so Settings/About cannot accumulate
    // extra horizontal rules during reuse or relayout.
    UIView *separator = [cell.contentView viewWithTag:DOCustomGlassSettingsSeparatorTag];
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

    // R8: one section = one Glass surface. Cells carry content only; this
    // removes the nested rounded frames and doubled optical rails seen in R7.
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = nil;

    if (isHeader) {
        cell.selectedBackgroundView = nil;
        UIView *separator = [cell.contentView viewWithTag:DOCustomGlassSettingsSeparatorTag];
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
            glass = [[DOCustomLiquidGlassView alloc] initWithCornerRadius:18.0 baseTintAlpha:0.038];
            glass.userInteractionEnabled = NO;
            glass.materialScale = 0.88;
            self.customGlassSectionBackdropViews[key] = glass;
            [tableView insertSubview:glass atIndex:0];
        }

        glass.hidden = NO;
        glass.frame = CGRectInset(sectionRect, 1.0, 0.5);
        glass.preferredCornerRadius = 18.0;
        glass.layer.cornerRadius = 18.0;
        glass.layer.maskedCorners =
            kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
            kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
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

    // Build the Section Glass geometry first. Every row in one surface then
    // samples that same backdrop and receives one foreground mode, eliminating
    // the R8 black/white alternation inside a single section.
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

    UIView *backButton = [self.view viewWithTag:0xC653];
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
    static NSInteger const DOCustomGlassSettingsBackButtonTag = 0xC653;
    if ([self.view viewWithTag:DOCustomGlassSettingsBackButtonTag])
        return;

    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    backButton.tag = DOCustomGlassSettingsBackButtonTag;
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
                                                 name:DOCustomGlassSettingsDidChangeNotification
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
    _lastKnownTheme = [[DOThemeManager sharedInstance] enabledTheme].key;
    [super viewDidLoad];
    [self customGlassInstallPageAppearance];
}

- (void)viewWillAppear:(BOOL)arg1
{
    [super viewWillAppear:arg1];
    if (_lastKnownTheme != [[DOThemeManager sharedInstance] enabledTheme].key)
    {
        [DOSceneDelegate relaunch];
        NSString *icon = [[DOThemeManager sharedInstance] enabledTheme].icon;
        [[UIApplication sharedApplication] setAlternateIconName:icon completionHandler:^(NSError * _Nullable error) {
            if (error)
                NSLog(@"Error changing app icon: %@", error);
        }];

        if ([DOEnvironmentManager sharedManager].isJailbroken) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[DOEnvironmentManager sharedManager] updateBootLogo];
            });
        }
    }

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
                                                    name:DOCustomGlassSettingsDidChangeNotification
                                                  object:nil];
}

- (NSArray *)availableKernelExploitIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray new];
    for (DOExploit *exploit in _availableKernelExploits) {
        [identifiers addObject:exploit.identifier];
    }
    return identifiers;
}

- (NSArray *)availableKernelExploitNames
{
    NSMutableArray *names = [NSMutableArray new];
    for (DOExploit *exploit in _availableKernelExploits) {
        [names addObject:exploit.name];
    }
    return names;
}

- (NSArray *)availablePACBypassIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray new];
    if (![DOEnvironmentManager sharedManager].isPACBypassRequired) {
        [identifiers addObject:@"none"];
    }
    for (DOExploit *exploit in _availablePACBypasses) {
        [identifiers addObject:exploit.identifier];
    }
    return identifiers;
}

- (NSArray *)availablePACBypassNames
{
    NSMutableArray *names = [NSMutableArray new];
    if (![DOEnvironmentManager sharedManager].isPACBypassRequired) {
        [names addObject:DOLocalizedString(@"None")];
    }
    for (DOExploit *exploit in _availablePACBypasses) {
        [names addObject:exploit.name];
    }
    return names;
}

- (NSArray *)availablePPLBypassIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray new];
    for (DOExploit *exploit in _availablePPLBypasses) {
        [identifiers addObject:exploit.identifier];
    }
    return identifiers;
}

- (NSArray *)availablePPLBypassNames
{
    NSMutableArray *names = [NSMutableArray new];
    for (DOExploit *exploit in _availablePPLBypasses) {
        [names addObject:exploit.name];
    }
    return names;
}

- (NSArray *)themeIdentifiers
{
    return [[DOThemeManager sharedInstance] getAvailableThemeKeys];
}

- (NSArray *)themeNames
{
    return [[DOThemeManager sharedInstance] getAvailableThemeNames];
}

- (NSArray *)jetsamOptionNumbers
{
    return @[
    @2,
    @3,
    @4,
    @5,
    @6,
    @7,
    @8,
    ];
}

- (NSArray *)jetsamOptionTitles
{
    return @[
        @"1x",
        @"1.5x",
        @"2x",
        @"2.5x",
        [NSString stringWithFormat:@"3x (%@)", DOLocalizedString(@"Recommended")],
        @"3.5x",
        @"4x",
    ];
}

- (id)specifiers
{
    if(_specifiers == nil) {
        NSMutableArray *specifiers = [NSMutableArray new];
        DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
        DOExploitManager *exploitManager = [DOExploitManager sharedManager];

        NSNumber *buttonHeight = @(44);
        
        SEL defGetter = @selector(readPreferenceValue:);
        SEL defSetter = @selector(setPreferenceValue:specifier:);
        
        NSSortDescriptor *prioritySortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"priority" ascending:NO];
        
        _availableKernelExploits = [[exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL] sortedArrayUsingDescriptors:@[prioritySortDescriptor]];
        if (envManager.isArm64e) {
            _availablePACBypasses = [[exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC] sortedArrayUsingDescriptors:@[prioritySortDescriptor]];
            _availablePPLBypasses = [[exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL] sortedArrayUsingDescriptors:@[prioritySortDescriptor]];
        }
        
        PSSpecifier *headerSpecifier = [PSSpecifier emptyGroupSpecifier];
        [headerSpecifier setProperty:@"DOHeaderCell" forKey:@"headerCellClass"];
        [headerSpecifier setProperty:[NSString stringWithFormat:@"Settings"] forKey:@"title"];
        [specifiers addObject:headerSpecifier];
        
        if (envManager.isSupported) {
            if (!envManager.isJailbroken) {
                PSSpecifier *exploitGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
                exploitGroupSpecifier.name = DOLocalizedString(@"Section_Exploits");
                [specifiers addObject:exploitGroupSpecifier];
                
                PSSpecifier *kernelExploitSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Kernel Exploit") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
                [kernelExploitSpecifier setProperty:@YES forKey:@"enabled"];
                [kernelExploitSpecifier setProperty:exploitManager.preferredKernelExploit.identifier forKey:@"default"];
                kernelExploitSpecifier.detailControllerClass = [DOPSExploitListItemsController class];
                [kernelExploitSpecifier setProperty:@"availableKernelExploitIdentifiers" forKey:@"valuesDataSource"];
                [kernelExploitSpecifier setProperty:@"availableKernelExploitNames" forKey:@"titlesDataSource"];
                [kernelExploitSpecifier setProperty:@"selectedKernelExploit" forKey:@"key"];
                [kernelExploitSpecifier setProperty:(_availableKernelExploits.firstObject.identifier ?: @"none") forKey:@"recommendedExploitIdentifier"];
                [specifiers addObject:kernelExploitSpecifier];
                
                if (envManager.isArm64e) {
                    PSSpecifier *pacBypassSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"PAC Bypass") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
                    [pacBypassSpecifier setProperty:@YES forKey:@"enabled"];
                    DOExploit *preferredPACBypass = exploitManager.preferredPACBypass;
                    if (!preferredPACBypass) {
                        [pacBypassSpecifier setProperty:@"none" forKey:@"default"];
                    }
                    else {
                        [pacBypassSpecifier setProperty:preferredPACBypass.identifier forKey:@"default"];
                    }
                    pacBypassSpecifier.detailControllerClass = [DOPSExploitListItemsController class];
                    [pacBypassSpecifier setProperty:@"availablePACBypassIdentifiers" forKey:@"valuesDataSource"];
                    [pacBypassSpecifier setProperty:@"availablePACBypassNames" forKey:@"titlesDataSource"];
                    [pacBypassSpecifier setProperty:@"selectedPACBypass" forKey:@"key"];
                    [pacBypassSpecifier setProperty:([envManager isPACBypassRequired] ? _availablePACBypasses.firstObject.identifier : @"none") forKey:@"recommendedExploitIdentifier"];
                    [specifiers addObject:pacBypassSpecifier];
                    
                    PSSpecifier *pplBypassSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"PPL Bypass") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
                    [pplBypassSpecifier setProperty:@YES forKey:@"enabled"];
                    [pplBypassSpecifier setProperty:exploitManager.preferredPPLBypass.identifier forKey:@"default"];
                    pplBypassSpecifier.detailControllerClass = [DOPSExploitListItemsController class];
                    [pplBypassSpecifier setProperty:@"availablePPLBypassIdentifiers" forKey:@"valuesDataSource"];
                    [pplBypassSpecifier setProperty:@"availablePPLBypassNames" forKey:@"titlesDataSource"];
                    [pplBypassSpecifier setProperty:@"selectedPPLBypass" forKey:@"key"];
                    [pplBypassSpecifier setProperty:(_availablePPLBypasses.firstObject.identifier ?: @"none") forKey:@"recommendedExploitIdentifier"];
                    [specifiers addObject:pplBypassSpecifier];
                }
            }
            
            PSSpecifier *settingsGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
            settingsGroupSpecifier.name = DOLocalizedString(@"Section_Jailbreak_Settings");
            [specifiers addObject:settingsGroupSpecifier];
            
            PSSpecifier *tweakInjectionSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Tweak_Injection") target:self set:@selector(setTweakInjectionEnabled:specifier:) get:@selector(readTweakInjectionEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [tweakInjectionSpecifier setProperty:@YES forKey:@"enabled"];
            [tweakInjectionSpecifier setProperty:@"tweakInjectionEnabled" forKey:@"key"];
            [tweakInjectionSpecifier setProperty:@YES forKey:@"default"];
            [specifiers addObject:tweakInjectionSpecifier];
            
            if (!envManager.isJailbroken) {
                PSSpecifier *verboseLogSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Verbose_Logs") target:self set:defSetter get:defGetter detail:nil cell:PSSwitchCell edit:nil];
                [verboseLogSpecifier setProperty:@YES forKey:@"enabled"];
                [verboseLogSpecifier setProperty:@"verboseLogsEnabled" forKey:@"key"];
                [verboseLogSpecifier setProperty:@NO forKey:@"default"];
                [specifiers addObject:verboseLogSpecifier];
            }
            
            PSSpecifier *idownloadSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_iDownload") target:self set:@selector(setIDownloadEnabled:specifier:) get:@selector(readIDownloadEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [idownloadSpecifier setProperty:@YES forKey:@"enabled"];
            [idownloadSpecifier setProperty:@"idownloadEnabled" forKey:@"key"];
            [idownloadSpecifier setProperty:@NO forKey:@"default"];
            [specifiers addObject:idownloadSpecifier];
            
            PSSpecifier *appJitSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Apps_JIT") target:self set:@selector(setAppJITEnabled:specifier:) get:@selector(readAppJITEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [appJitSpecifier setProperty:@YES forKey:@"enabled"];
            [appJitSpecifier setProperty:@"appJITEnabled" forKey:@"key"];
            [appJitSpecifier setProperty:@YES forKey:@"default"];
            [specifiers addObject:appJitSpecifier];
            
            
            /**************************** roothide specfic *********************************/
            NSString* namedesc = DOLocalizedString(@"Enable dyld patch");
            if(envManager.isArm64e && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15) {
                namedesc = DOLocalizedString(@"Dyld Patch(Spinlock Fix)");
            }
            PSSpecifier *dyldPatchSpecifier = [PSSpecifier preferenceSpecifierNamed:namedesc target:self set:@selector(setDyldPatchEnabled:specifier:) get:@selector(readDyldPatchEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [dyldPatchSpecifier setProperty:@YES forKey:@"enabled"];
            [dyldPatchSpecifier setProperty:@"dyldPatchEnabled" forKey:@"key"];
            [dyldPatchSpecifier setProperty:@NO forKey:@"default"];
            [specifiers addObject:dyldPatchSpecifier];
            /**************************** roothide specfic *********************************/
            
            PSSpecifier *disableUpdateSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Disable_Update") target:self set:defSetter get:defGetter detail:nil cell:PSSwitchCell edit:nil];
            [disableUpdateSpecifier setProperty:@YES forKey:@"enabled"];
            [disableUpdateSpecifier setProperty:@"disableUpdateEnabled" forKey:@"key"];
            [disableUpdateSpecifier setProperty:@YES forKey:@"default"];
            [specifiers addObject:disableUpdateSpecifier];
            
            PSSpecifier *jetsamSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Jetsam_Multiplier") target:self set:@selector(setJetsamMultiplier:specifier:) get:@selector(readJetsamMultiplier:) detail:nil cell:PSLinkListCell edit:nil];
            [jetsamSpecifier setProperty:@YES forKey:@"enabled"];
            [jetsamSpecifier setProperty:@"jetsamMultiplier" forKey:@"key"];
            [jetsamSpecifier setProperty:@6 forKey:@"default"];
            jetsamSpecifier.detailControllerClass = [DOPSJetsamListItemsController class];
            [jetsamSpecifier setProperty:@"jetsamOptionNumbers" forKey:@"valuesDataSource"];
            [jetsamSpecifier setProperty:@"jetsamOptionTitles" forKey:@"titlesDataSource"];
            [specifiers addObject:jetsamSpecifier];

            PSSpecifier *supporterLicenseSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
            [supporterLicenseSpecifier setProperty:@"Supporter License" forKey:@"title"];
            [supporterLicenseSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
            [supporterLicenseSpecifier setProperty:buttonHeight forKey:@"height"];
            [supporterLicenseSpecifier setProperty:@"checkmark.seal" forKey:@"image"];
            [supporterLicenseSpecifier setProperty:@"supporterLicensePressed" forKey:@"action"];
            [specifiers addObject:supporterLicenseSpecifier];
            
            if (!envManager.isJailbroken && !envManager.isInstalledThroughTrollStore) {
                PSSpecifier *removeJailbreakSwitchSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Button_Remove_Jailbreak") target:self set:@selector(setRemoveJailbreakEnabled:specifier:) get:defGetter detail:nil cell:PSSwitchCell edit:nil];
                [removeJailbreakSwitchSpecifier setProperty:@YES forKey:@"enabled"];
                [removeJailbreakSwitchSpecifier setProperty:@"removeJailbreakEnabled" forKey:@"key"];
                [specifiers addObject:removeJailbreakSwitchSpecifier];
            }
            
            if (envManager.isJailbroken || (envManager.isInstalledThroughTrollStore && envManager.isBootstrapped)) {
                PSSpecifier *actionsGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
                actionsGroupSpecifier.name = DOLocalizedString(@"Section_Actions");
                [specifiers addObject:actionsGroupSpecifier];
                
                if (envManager.isJailbroken) {
                    PSSpecifier *rootHideHealthSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [rootHideHealthSpecifier setProperty:@"RootHide Health" forKey:@"title"];
                    [rootHideHealthSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [rootHideHealthSpecifier setProperty:buttonHeight forKey:@"height"];
                    [rootHideHealthSpecifier setProperty:@"heart.text.square" forKey:@"image"];
                    [rootHideHealthSpecifier setProperty:@"rootHideHealthPressed" forKey:@"action"];
                    [specifiers addObject:rootHideHealthSpecifier];

                    PSSpecifier *refreshAppsSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [refreshAppsSpecifier setProperty:@"Button_Refresh_Jailbreak_Apps" forKey:@"title"];
                    [refreshAppsSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [refreshAppsSpecifier setProperty:buttonHeight forKey:@"height"];
                    [refreshAppsSpecifier setProperty:@"arrow.triangle.2.circlepath" forKey:@"image"];
                    [refreshAppsSpecifier setProperty:@"refreshJailbreakAppsPressed" forKey:@"action"];
                    [specifiers addObject:refreshAppsSpecifier];
                    
                    PSSpecifier *changeMobilePasswordSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [changeMobilePasswordSpecifier setProperty:@"Button_Change_Mobile_Password" forKey:@"title"];
                    [changeMobilePasswordSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [changeMobilePasswordSpecifier setProperty:buttonHeight forKey:@"height"];
                    [changeMobilePasswordSpecifier setProperty:@"key" forKey:@"image"];
                    [changeMobilePasswordSpecifier setProperty:@"changeMobilePasswordWithAuthenticationPressed" forKey:@"action"];
                    [specifiers addObject:changeMobilePasswordSpecifier];
                    
                    PSSpecifier *reinstallPackageManagersSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [reinstallPackageManagersSpecifier setProperty:@"Button_Reinstall_Package_Managers" forKey:@"title"];
                    [reinstallPackageManagersSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [reinstallPackageManagersSpecifier setProperty:buttonHeight forKey:@"height"];
                    if (@available(iOS 16.0, *))
                        [reinstallPackageManagersSpecifier setProperty:@"shippingbox.and.arrow.backward" forKey:@"image"];
                    else
                        [reinstallPackageManagersSpecifier setProperty:@"shippingbox" forKey:@"image"];
                    [reinstallPackageManagersSpecifier setProperty:@"reinstallPackageManagersPressed" forKey:@"action"];
                    [specifiers addObject:reinstallPackageManagersSpecifier];

                    PSSpecifier *addMountSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [addMountSpecifier setProperty:@"Mount_Add_Title" forKey:@"title"];
                    [addMountSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [addMountSpecifier setProperty:buttonHeight forKey:@"height"];
                    [addMountSpecifier setProperty:@"externaldrive.badge.plus" forKey:@"image"];
                    [addMountSpecifier setProperty:@"addMountPressed" forKey:@"action"];
                    [specifiers addObject:addMountSpecifier];

                    PSSpecifier *manageMountsSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [manageMountsSpecifier setProperty:@"Mount_Manage_Title" forKey:@"title"];
                    [manageMountsSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [manageMountsSpecifier setProperty:buttonHeight forKey:@"height"];
                    [manageMountsSpecifier setProperty:@"externaldrive" forKey:@"image"];
                    [manageMountsSpecifier setProperty:@"manageMountsPressed" forKey:@"action"];
                    [specifiers addObject:manageMountsSpecifier];
                }
                if ((envManager.isJailbroken || envManager.isInstalledThroughTrollStore) && envManager.isBootstrapped) {
/*
                    PSSpecifier *hideUnhideJailbreakSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [hideUnhideJailbreakSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [hideUnhideJailbreakSpecifier setProperty:buttonHeight forKey:@"height"];
                    if (envManager.isJailbreakHidden) {
                        [hideUnhideJailbreakSpecifier setProperty:@"Button_Unhide_Jailbreak" forKey:@"title"];
                        [hideUnhideJailbreakSpecifier setProperty:@"eye" forKey:@"image"];
                    }
                    else {
                        [hideUnhideJailbreakSpecifier setProperty:@"Button_Hide_Jailbreak" forKey:@"title"];
                        [hideUnhideJailbreakSpecifier setProperty:@"eye.slash" forKey:@"image"];
                    }
                    [hideUnhideJailbreakSpecifier setProperty:@"hideUnhideJailbreakPressed" forKey:@"action"];
                    BOOL hideJailbreakButtonShown = (envManager.isJailbroken || (envManager.isInstalledThroughTrollStore && envManager.isBootstrapped && !envManager.isJailbreakHidden));
                    if (hideJailbreakButtonShown) {
                        [specifiers addObject:hideUnhideJailbreakSpecifier];
                    }
*/
                    
                    if (!envManager.isJailbroken && envManager.isInstalledThroughTrollStore) {
                        PSSpecifier *removeJailbreakSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                        [removeJailbreakSpecifier setProperty:@"Button_Remove_Jailbreak" forKey:@"title"];
                        [removeJailbreakSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                        [removeJailbreakSpecifier setProperty:buttonHeight forKey:@"height"];
                        [removeJailbreakSpecifier setProperty:@"trash" forKey:@"image"];
                        [removeJailbreakSpecifier setProperty:@"removeJailbreakPressed" forKey:@"action"];
/*
                        if (hideJailbreakButtonShown) {
                            if (envManager.isJailbroken) {
                                [removeJailbreakSpecifier setProperty:DOLocalizedString(@"Hint_Hide_Jailbreak_Jailbroken") forKey:@"footerText"];
                            }
                            else {
                                [removeJailbreakSpecifier setProperty:DOLocalizedString(@"Hint_Hide_Jailbreak") forKey:@"footerText"];
                            }
                        }
*/
                        [specifiers addObject:removeJailbreakSpecifier];
                    }
                }
            }
        }
        
        PSSpecifier *themingGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        themingGroupSpecifier.name = DOLocalizedString(@"Section_Customization");
        [specifiers addObject:themingGroupSpecifier];
        
        PSSpecifier *themeSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Theme") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
        themeSpecifier.detailControllerClass = [DOPSListItemsController class];
        [themeSpecifier setProperty:@YES forKey:@"enabled"];
        [themeSpecifier setProperty:@"theme" forKey:@"key"];
        [themeSpecifier setProperty:[[self themeIdentifiers] firstObject] forKey:@"default"];
        [themeSpecifier setProperty:@"themeIdentifiers" forKey:@"valuesDataSource"];
        [themeSpecifier setProperty:@"themeNames" forKey:@"titlesDataSource"];
        [specifiers addObject:themeSpecifier];

        PSSpecifier *bootlogoGropSpecifier = [PSSpecifier emptyGroupSpecifier];
        bootlogoGropSpecifier.name = DOLocalizedString(@"Section_Boot_Logo");
        [specifiers addObject:bootlogoGropSpecifier];

        PSSpecifier *bootlogoEnabledSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Enabled") target:self set:@selector(setBootlogoEnabled:specifier:) get:defGetter detail:nil cell:PSSwitchCell edit:nil];
        [bootlogoEnabledSpecifier setProperty:@YES forKey:@"enabled"];
        [bootlogoEnabledSpecifier setProperty:@"bootlogoEnabled" forKey:@"key"];
        [bootlogoEnabledSpecifier setProperty:@YES forKey:@"default"];
        bootlogoEnabledSpecifier.identifier = @"bootlogoEnabled";
        [specifiers addObject:bootlogoEnabledSpecifier];

        _customBootlogoEnabledSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Custom_Boot_Logo") target:self set:@selector(setCustomBootlogoEnabled:specifier:) get:defGetter detail:nil cell:PSSwitchCell edit:nil];
        [_customBootlogoEnabledSpecifier setProperty:@YES forKey:@"enabled"];
        [_customBootlogoEnabledSpecifier setProperty:@"customBootlogoEnabled" forKey:@"key"];
        [_customBootlogoEnabledSpecifier setProperty:@NO forKey:@"default"];
        _customBootlogoEnabledSpecifier.identifier = @"customBootlogoEnabled";

        _customBootlogoSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Select_Image") target:self set:defSetter get:defGetter detail:nil cell:PSButtonCell edit:nil];
        _customBootlogoSpecifier.buttonAction = @selector(selectCustomBootlogoPressed);
        [_customBootlogoSpecifier setProperty:@YES forKey:@"enabled"];
        [_customBootlogoSpecifier setProperty:@"customBootlogo" forKey:@"key"];
        _customBootlogoSpecifier.identifier = @"customBootlogo";

        if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"bootlogoEnabled" fallback:YES]) {
            [specifiers addObject:_customBootlogoEnabledSpecifier];

            if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"customBootlogoEnabled" fallback:NO]) {
                [specifiers addObject:_customBootlogoSpecifier];
            }
        }

        _specifiers = specifiers;
    }
    return _specifiers;
}

#pragma mark - Getters & Setters

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    [[DOPreferenceManager sharedManager] setPreferenceValue:value forKey:key];
}

- (id)readPreferenceValue:(PSSpecifier*)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    id value = [[DOPreferenceManager sharedManager] preferenceValueForKey:key];
    if (!value) {
        return [specifier propertyForKey:@"default"];
    }
    return value;
}

- (id)readIDownloadEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        return @([DOEnvironmentManager sharedManager].isIDownloadEnabled);
    }
    return [self readPreferenceValue:specifier];
}

- (void)setIDownloadEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        [[DOEnvironmentManager sharedManager] setIDownloadLoaded:((NSNumber *)value).boolValue needsUnsandbox:YES];
    }
}

- (id)readTweakInjectionEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        return @([DOEnvironmentManager sharedManager].isTweakInjectionEnabled);
    }
    return [self readPreferenceValue:specifier];
}

- (void)setTweakInjectionEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        [[DOEnvironmentManager sharedManager] setTweakInjectionEnabled:((NSNumber *)value).boolValue];
        UIAlertController *userspaceRebootAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Title") message:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Body") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *rebootNowAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Reboot_Now") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[DOEnvironmentManager sharedManager] rebootUserspace];
        }];
        UIAlertAction *rebootLaterAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Reboot_Later") style:UIAlertActionStyleCancel handler:nil];
        
        [userspaceRebootAlertController addAction:rebootNowAction];
        [userspaceRebootAlertController addAction:rebootLaterAction];
        [self presentViewController:userspaceRebootAlertController animated:YES completion:nil];
    }
}

- (id)readAppJITEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        bool v = jbclient_jbsettings_get_bool("markAppsAsDebugged");
        return @(v);
    }
    return [self readPreferenceValue:specifier];
}

- (void)setAppJITEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        jbclient_platform_jbsettings_set_bool("markAppsAsDebugged", ((NSNumber *)value).boolValue);
    }
}

- (id)readJetsamMultiplier:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        double v = jbclient_jbsettings_get_double("jetsamMultiplier");
        return @((v < 1 || isnan(v)) ? 6 : ceil(v * 2));
    }
    return [self readPreferenceValue:specifier];
}

- (void)setJetsamMultiplier:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        jbclient_platform_jbsettings_set_double("jetsamMultiplier", ((NSNumber *)value).doubleValue / 2);
    }
}

- (void)setRemoveJailbreakEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    if (((NSNumber *)value).boolValue) {
        UIAlertController *confirmationAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Remove_Jailbreak_Title") message:DOLocalizedString(@"Alert_Remove_Jailbreak_Enabled_Body") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *uninstallAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Continue") style:UIAlertActionStyleDestructive handler:nil];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setPreferenceValue:@NO specifier:specifier];
            [self reloadSpecifiers];
        }];
        [confirmationAlertController addAction:uninstallAction];
        [confirmationAlertController addAction:cancelAction];
        [self presentViewController:confirmationAlertController animated:YES completion:nil];
    }
}

- (void)setBootlogoEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    bool prevValueBool = ((NSNumber *)[self readPreferenceValue:specifier]).boolValue;
    [self setPreferenceValue:value specifier:specifier];
    bool valueBool = ((NSNumber *)value).boolValue;

    if (prevValueBool != valueBool) {
        NSMutableArray *affectedSpecifiers = [NSMutableArray new];
        [affectedSpecifiers addObject:_customBootlogoEnabledSpecifier];

        if (valueBool == ![self containsSpecifier:_customBootlogoSpecifier]) {
            [affectedSpecifiers addObject:_customBootlogoSpecifier];
        }

        if (valueBool) {
            [self insertContiguousSpecifiers:affectedSpecifiers afterSpecifier:specifier animated:YES];
        }
        else {
            [self removeContiguousSpecifiers:affectedSpecifiers animated:YES];
        }
    }

    if ([DOEnvironmentManager sharedManager].isJailbroken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[DOEnvironmentManager sharedManager] updateBootLogo];
        });
    }
}

- (void)setCustomBootlogoEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    bool prevValueBool = ((NSNumber *)[self readPreferenceValue:specifier]).boolValue;
    [self setPreferenceValue:value specifier:specifier];
    bool valueBool = ((NSNumber *)value).boolValue;

    if (prevValueBool != valueBool) {
        if (valueBool) {
            [self insertSpecifier:_customBootlogoSpecifier afterSpecifier:specifier animated:YES];
        }
        else {
            [self removeSpecifier:_customBootlogoSpecifier animated:YES];
        }
    }

    if ([DOEnvironmentManager sharedManager].isJailbroken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[DOEnvironmentManager sharedManager] updateBootLogo];
        });
    }
}

- (void)selectCustomBootlogoPressed
{
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusDenied || status == PHAuthorizationStatusRestricted) {
        return;
    } else if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self selectCustomBootlogoPressed];
                });
            }
        }];
        return;
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Boot Logo Picker

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    UIImage *chosenImage = info[UIImagePickerControllerEditedImage];
    if (!chosenImage) {
        chosenImage = info[UIImagePickerControllerOriginalImage];
    }

    // Force correct the orientation
    // For some reason without rerendering the image, the stored file will have a wrong orientation for photos taken with the camera‚
    UIGraphicsBeginImageContextWithOptions(chosenImage.size, NO, 1.0);
    [chosenImage drawInRect:CGRectMake(0,0, chosenImage.size.width, chosenImage.size.height)];
    chosenImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    [UIImagePNGRepresentation(chosenImage) writeToFile:[DOUIManager sharedInstance].bootlogoPath atomically:YES];

    if ([DOEnvironmentManager sharedManager].isJailbroken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[DOEnvironmentManager sharedManager] updateBootLogo];
        });
    }

    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Button Actions

- (void)showSupporterLicenseResultWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)supporterLicensePressed
{
    NSDictionary<NSString *, id> *info = DORHSupporterCurrentLicenseInfo();
    NSString *supporterID = [info[@"sid"] isKindOfClass:NSString.class] ? info[@"sid"] : nil;
    NSString *status = supporterID.length > 0
        ? [NSString stringWithFormat:@"Verified · #%@", supporterID]
        : @"Not Activated";
    NSString *deviceCode = DORHSupporterDeviceCode();
    NSString *message = [NSString stringWithFormat:@"%@\n\nDevice Code\n%@",
                         status,
                         deviceCode.length > 0 ? deviceCode : @"Unavailable"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Supporter License"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *copyDeviceCodeAction =
        [UIAlertAction actionWithTitle:@"Copy Device Code"
                                 style:UIAlertActionStyleDefault
                               handler:^(__kindof UIAlertAction * _Nonnull action) {
        UIPasteboard.generalPasteboard.string = deviceCode;
    }];
    copyDeviceCodeAction.enabled = deviceCode.length > 0;
    [alert addAction:copyDeviceCodeAction];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Paste License"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__kindof UIAlertAction * _Nonnull action) {
        NSString *licenseCode = UIPasteboard.generalPasteboard.string ?: @"";
        NSError *error = nil;
        if (DORHSupporterStoreLicenseCode(licenseCode, &error)) {
            NSString *verifiedID = DORHSupporterCurrentID() ?: @"";
            NSString *verifiedMessage = verifiedID.length > 0
                ? [NSString stringWithFormat:@"Supporter #%@", verifiedID]
                : @"Supporter verified";
            [weakSelf showSupporterLicenseResultWithTitle:@"Verified" message:verifiedMessage];
        }
        else {
            [weakSelf showSupporterLicenseResultWithTitle:@"Invalid License"
                                                  message:error.localizedDescription ?: @"Unable to verify supporter license"];
        }
    }]];

    if (supporterID.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove License"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__kindof UIAlertAction * _Nonnull action) {
            DORHSupporterRemoveLicense();
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)rootHideHealthPressed
{
    [self.navigationController pushViewController:[[DORootHideHealthViewController alloc] init] animated:YES];
}

- (void)refreshJailbreakAppsPressed
{
    static BOOL repairInProgress = NO;
    if (repairInProgress) return;
    repairInProgress = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *repairError = [[DOEnvironmentManager sharedManager] repairJailbreakApps];

        dispatch_async(dispatch_get_main_queue(), ^{
            repairInProgress = NO;

            NSString *title = repairError ? @"Jailbreak App Repair Failed" : DOLocalizedString(@"Button_Refresh_Jailbreak_Apps");
            NSString *message = repairError.localizedDescription ?: @"Jailbreak app registrations are healthy and up to date.";

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK")
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)reinstallPackageManagersPressed
{
    [self.navigationController pushViewController:[[DOPkgManagerPickerViewController alloc] init] animated:YES];
}

- (void)changeMobilePasswordWithAuthenticationPressed
{
	LAContext *context = [[LAContext alloc] init];
	NSError *authError = nil;
	NSString *reason = DOLocalizedString(@"Password_Auth_Required");
	
	if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&authError]) {
		[context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
			localizedReason:reason
			reply:^(BOOL success, NSError * _Nullable error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (success) {
					[self changeMobilePassword];
				}
			});
		}];
	}
	else {
		[self changeMobilePassword];
	}
}

- (void)changeMobilePassword
{
    UIAlertController *changeMobilePasswordAlert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Button_Change_Mobile_Password") message:DOLocalizedString(@"Alert_Change_Mobile_Password_Body") preferredStyle:UIAlertControllerStyleAlert];
    
    [changeMobilePasswordAlert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = DOLocalizedString(@"Password_Placeholder");
        textField.secureTextEntry = YES;
    }];
    
    [changeMobilePasswordAlert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = DOLocalizedString(@"Repeat_Password_Placeholder");
        textField.secureTextEntry = YES;
    }];
    
    UIAlertAction *changeButton = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Change") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action){
        NSString *password = changeMobilePasswordAlert.textFields[0].text;
        NSString *repeatPassword = changeMobilePasswordAlert.textFields[1].text;
        if (![password isEqualToString:repeatPassword]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self changeMobilePassword];
            });
        }
        else {
            [[DOEnvironmentManager sharedManager] changeMobilePassword:password];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil];
    [changeMobilePasswordAlert addAction:changeButton];
    [changeMobilePasswordAlert addAction:cancelAction];
    [self presentViewController:changeMobilePasswordAlert animated:YES completion:nil];
}

/*
- (void)hideUnhideJailbreakPressed
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    [envManager setJailbreakHidden:!envManager.isJailbreakHidden];
    [self reloadSpecifiers];
}
*/

- (void)removeJailbreakPressed
{
    UIAlertController *confirmationAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Remove_Jailbreak_Title") message:DOLocalizedString(@"Alert_Remove_Jailbreak_Pressed_Body") preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *uninstallAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Continue") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[DOEnvironmentManager sharedManager] deleteBootstrap];
        if ([DOEnvironmentManager sharedManager].isJailbroken) {
            [[DOEnvironmentManager sharedManager] reboot];
        }
        else {
            if (gSystemInfo.jailbreakInfo.rootPath) {
                free(gSystemInfo.jailbreakInfo.rootPath);
                gSystemInfo.jailbreakInfo.rootPath = NULL;
                [[DOEnvironmentManager sharedManager] locateJailbreakRoot];
            }
            [self reloadSpecifiers];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleDefault handler:nil];
    [confirmationAlertController addAction:uninstallAction];
    [confirmationAlertController addAction:cancelAction];
    [self presentViewController:confirmationAlertController animated:YES completion:nil];
}

- (void)showMountMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Mount_Title")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)normalizedMountPath:(NSString *)path
{
    NSString *trimmedPath = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmedPath hasPrefix:@"/"]) trimmedPath = [@"/" stringByAppendingString:trimmedPath];
    return trimmedPath.stringByStandardizingPath;
}

- (void)performMountPath:(NSString *)path mounted:(BOOL)mounted deleteMirror:(BOOL)deleteMirror
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DOEnvironmentManager *environmentManager = [DOEnvironmentManager sharedManager];
        int result = [environmentManager setFakeMountPath:path mounted:mounted deleteMirror:deleteMirror];
        if (result == 0) {
            NSMutableArray<NSString *> *paths = [environmentManager.fakeMountPaths mutableCopy];
            if (mounted && ![paths containsObject:path]) [paths addObject:path];
            if (!mounted) [paths removeObject:path];
            if (![environmentManager saveFakeMountPaths:paths]) result = EIO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = result == 0 ? DOLocalizedString(@"Mount_Operation_Succeeded") :
                [NSString stringWithFormat:DOLocalizedString(@"Mount_Operation_Failed"), result];
            [self showMountMessage:message];
        });
    });
}

- (void)addMountPressed
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Mount_Add_Title")
                                                                   message:DOLocalizedString(@"Mount_Path_Prompt")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"/System/Library/...";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Mount") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *path = [self normalizedMountPath:alert.textFields.firstObject.text ?: @""];
        BOOL isDirectory = NO;
        if ([path isEqualToString:@"/"] || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
            [self showMountMessage:DOLocalizedString(@"Mount_Path_Invalid")];
            return;
        }
        [self performMountPath:path mounted:YES deleteMirror:NO];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)manageMountsPressed
{
    NSArray<NSString *> *paths = [DOEnvironmentManager sharedManager].fakeMountPaths;
    if (paths.count == 0) {
        [self showMountMessage:DOLocalizedString(@"Mount_No_Paths")];
        return;
    }

    UIAlertController *list = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Mount_Manage_Title")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *path in paths) {
        [list addAction:[UIAlertAction actionWithTitle:path style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIAlertController *options = [UIAlertController alertControllerWithTitle:path message:nil preferredStyle:UIAlertControllerStyleAlert];
            [options addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Mount_Unmount_Keep_Copy") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *innerAction) {
                [self performMountPath:path mounted:NO deleteMirror:NO];
            }]];
            [options addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Mount_Unmount_Delete_Copy") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *innerAction) {
                [self performMountPath:path mounted:NO deleteMirror:YES];
            }]];
            [options addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:options animated:YES completion:nil];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:list animated:YES completion:nil];
}

- (void)resetSettingsPressed
{
    [[DOUIManager sharedInstance] resetSettings];
    [self.navigationController popToRootViewControllerAnimated:YES];
    [self reloadSpecifiers];
}


- (id)readDyldPatchEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        return @(jbclient_dyld_patch_enabled());
    }
    return [self readPreferenceValue:specifier];
}

- (void)setDyldPatchEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    
    bool enable = ((NSNumber *)value).boolValue;
    
    void (^confirmAction)(void) = ^{
        
        if (!envManager.isJailbroken) {
            
            [self setPreferenceValue:value specifier:specifier];
            return;
        }
    
        UIAlertController *userspaceRebootAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Title") message:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Body") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *rebootNowAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Menu_Reboot_Userspace_Title") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            if(jbclient_set_dyld_patch(enable) == 0) {
                [self setPreferenceValue:value specifier:specifier];
                [[DOEnvironmentManager sharedManager] rebootUserspace];
            } else {
                [self reloadSpecifiers];
            }
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers];
        }];
        
        [userspaceRebootAlertController addAction:cancelAction];
        [userspaceRebootAlertController addAction:rebootNowAction];
        [self presentViewController:userspaceRebootAlertController animated:YES completion:nil];
    };
    
    
    if(enable && envManager.isArm64e && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Warning") message:DOLocalizedString(@"When spinlock fix is ​​enabled, app extensions of blacklisted apps will be disabled and may also cause spinlock panics when the blacklisted app is in foreground/background.\n\nYou can first try disabling tweak injection for the app in Choicy (spinlock fix still works), and only blacklist the app if that doesn't work.") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *continueAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Continue") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            confirmAction();
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers];
        }];
        
        [alert addAction:cancelAction];
        [alert addAction:continueAction];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        confirmAction();
    }
}

@end
