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

@interface UINavigationController (DOCustomGlassSharedBackground)
- (void)customGlassRefreshSharedBackground;
- (BOOL)customGlassPrefersDarkForegroundForView:(UIView *)view;
@end

@interface DOCreditsViewController ()

@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DOCustomLiquidGlassView *> *customGlassSectionBackdropViews;

@end

@implementation DOCreditsViewController

- (UIColor *)customGlassAdaptiveForegroundForView:(UIView *)view alpha:(CGFloat)alpha
{
    BOOL dark = [self.navigationController respondsToSelector:@selector(customGlassPrefersDarkForegroundForView:)] &&
        [self.navigationController customGlassPrefersDarkForegroundForView:view];
    return [UIColor colorWithWhite:(dark ? 0.08 : 1.0) alpha:alpha];
}

- (void)customGlassImproveReadabilityInView:(UIView *)view header:(BOOL)isHeader
{
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        BOOL dark = [self.navigationController respondsToSelector:@selector(customGlassPrefersDarkForegroundForView:)] &&
            [self.navigationController customGlassPrefersDarkForegroundForView:label];
        CGFloat alpha = isHeader ? 0.72 : (label.font.pointSize >= 15.0 ? 0.96 : 0.84);
        label.textColor = [self customGlassAdaptiveForegroundForView:label alpha:alpha];
        label.shadowColor = [UIColor colorWithWhite:(dark ? 1.0 : 0.0) alpha:(isHeader ? 0.08 : 0.11)];
        label.shadowOffset = CGSizeMake(0.0, 0.35);
    }
    else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        UIColor *foreground = [self customGlassAdaptiveForegroundForView:button alpha:0.96];
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
            imageView.tintColor = [self customGlassAdaptiveForegroundForView:imageView alpha:0.92];
    }

    for (UIView *subview in view.subviews)
        [self customGlassImproveReadabilityInView:subview header:isHeader];
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
    UIView *separator = [cell.contentView viewWithTag:DOCustomGlassCreditsSeparatorTag];
    if (!separator) {
        separator = [[UIView alloc] init];
        separator.tag = DOCustomGlassCreditsSeparatorTag;
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        separator.userInteractionEnabled = NO;
        [cell.contentView addSubview:separator];
        [NSLayoutConstraint activateConstraints:@[
            [separator.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:18.0],
            [separator.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-18.0],
            [separator.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
            [separator.heightAnchor constraintEqualToConstant:0.5]
        ]];
    }

    UITableView *tableView = [self valueForKey:@"table"];
    NSInteger rowCount = [tableView numberOfRowsInSection:indexPath.section];
    separator.hidden = indexPath.row >= MAX(0, rowCount - 1);
    BOOL dark = [self.navigationController respondsToSelector:@selector(customGlassPrefersDarkForegroundForView:)] &&
        [self.navigationController customGlassPrefersDarkForegroundForView:cell];
    separator.backgroundColor = [UIColor colorWithWhite:(dark ? 0.0 : 1.0) alpha:0.082];
}

- (void)customGlassStyleVisibleCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath
{
    if (!cell)
        return;

    NSString *className = NSStringFromClass(cell.class);
    BOOL isHeader = [className containsString:@"HeaderCell"];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = nil;

    if (isHeader) {
        cell.selectedBackgroundView = nil;
        UIView *separator = [cell.contentView viewWithTag:DOCustomGlassCreditsSeparatorTag];
        separator.hidden = YES;
        [self customGlassImproveReadabilityInView:cell.contentView header:YES];
        return;
    }

    UIView *selected = cell.selectedBackgroundView;
    if (!selected) {
        selected = [[UIView alloc] initWithFrame:CGRectZero];
        cell.selectedBackgroundView = selected;
    }
    BOOL dark = [self.navigationController respondsToSelector:@selector(customGlassPrefersDarkForegroundForView:)] &&
        [self.navigationController customGlassPrefersDarkForegroundForView:cell];
    selected.backgroundColor = [UIColor colorWithWhite:(dark ? 0.0 : 1.0) alpha:0.050];

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
    [self.navigationController customGlassRefreshSharedBackground];

    UITableView *tableView = [self valueForKey:@"table"];
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
    self.view.backgroundColor = UIColor.clearColor;

    UITableView *tableView = [self valueForKey:@"table"];
    tableView.backgroundColor = UIColor.clearColor;
    tableView.opaque = NO;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.backgroundView = nil;
    tableView.layer.cornerRadius = 0.0;
    tableView.layer.masksToBounds = NO;

    self.customGlassSectionBackdropViews = [NSMutableDictionary dictionary];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(customGlassThemeDidChange:)
                                                 name:DOCustomGlassCreditsDidChangeNotification
                                               object:nil];

    [self.navigationController customGlassRefreshSharedBackground];
    [self customGlassRefreshPageAppearance];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self customGlassStyleVisibleCell:cell atIndexPath:indexPath];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf customGlassRefreshSectionBackdrops];
    });
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self customGlassRefreshSectionBackdrops];
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
