//
//  DOPSListController.m
//  Dopamine
//
//  Created by tomt000 on 26/01/2024.
//

#import "DOPSListController.h"
#import "DOThemeManager.h"

@interface DOPSListController ()

@end

@implementation DOPSListController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [_table setSeparatorColor:[UIColor clearColor]];
    [_table setBackgroundColor:[UIColor clearColor]];
    [DOPSListController setupViewControllerStyle:self];
}

+ (void)setupViewControllerStyle:(UIViewController*)vc
{
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    
    vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    vc.view.backgroundColor = theme.windowColor;
    vc.view.layer.cornerRadius = 16;
    vc.view.layer.masksToBounds = YES;
    vc.view.layer.cornerCurve = kCACornerCurveContinuous;
    
    if (@available(iOS 19.0, *)) {
        // Apple broke the method below by reimplementing some Preferences.framework classes in SwiftUI 🤮
        // Now onTintColor is only implemented when the cell is initialized but gets reset to the stock color when the cell is reused
        // I tried hard to fix it but failed in the end, so we will need to just use the stock tint color on iOS 26.0+
    }
    else {
        [UISwitch appearanceWhenContainedInInstancesOfClasses:@[[vc class]]].onTintColor = [UIColor colorWithRed: 71.0/255.0 green: 169.0/255.0 blue: 135.0/255.0 alpha: 1.0];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.backgroundColor = [UIColor clearColor];
}

- (void)keepTableBackdropViewsBehindContent:(NSArray<UIView *> *)backdropViews
{
    if (!backdropViews.count) return;
    NSSet<UIView *> *backdrops = [NSSet setWithArray:backdropViews];
    BOOL contentSeen = NO;
    for (UIView *subview in _table.subviews) {
        if ([backdrops containsObject:subview]) {
            if (!contentSeen) continue;
            // Reuse can insert content below a backdrop. Repair that case, but
            // leave an already-correct hierarchy untouched during scrolling.
            for (UIView *backdrop in backdropViews) {
                if (backdrop.superview == _table)
                    [_table sendSubviewToBack:backdrop];
            }
            return;
        }
        contentSeen = YES;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect tableFrame = CGRectMake(12, 5, self.view.bounds.size.width - 24, self.view.bounds.size.height - 10);
    if (!CGRectEqualToRect(_table.frame, tableFrame))
        _table.frame = tableFrame;

    // Keep UIKit's automatic top safe-area adjustment for Preferences lists.
    // The raw 24pt bottom inset adds scroll room; UIKit adds the device safe area.
    UIEdgeInsets insets = _table.contentInset;
    insets.bottom = 24.0;
    if (!UIEdgeInsetsEqualToEdgeInsets(_table.contentInset, insets))
        _table.contentInset = insets;
}

#pragma mark - Status Bar

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}


@end
