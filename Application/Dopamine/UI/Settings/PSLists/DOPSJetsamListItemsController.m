//
//  DOPSExploitListItemsControllerViewController.m
//  Dopamine
//
//  Created by Lars Fröder on 29.04.24.
//

#import "DOPSJetsamListItemsController.h"
#import "DOUIManager.h"
#import "DOEnvironmentManager.h"
#import <libjailbreak/jbclient_xpc.h>
#include <math.h>

@interface DOPSJetsamListItemsController ()

@end

@implementation DOPSJetsamListItemsController

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [super specifiers];
        PSSpecifier *jetsamDescriptionSpecifier = [PSSpecifier emptyGroupSpecifier];
        NSString *footer = DOLocalizedString(@"Jetsam_Description");
        if ([DOEnvironmentManager sharedManager].isJailbroken) {
            double actual = 0;
            int result = jbclient_jbsettings_get_double_checked("jetsamMultiplier", &actual);
            if (result == 0 && (!isfinite(actual) || (actual != 0 && (actual < 1 || actual > 4)))) {
                result = JBCLIENT_SETTINGS_ERROR_INVALID_VALUE;
            }
            if (result != 0) {
                footer = [NSString stringWithFormat:@"%@\n\n%@", footer,
                    [NSString stringWithFormat:DOLocalizedString(@"Jetsam_Read_Failed_Body"), result]];
            }
        }
        [jetsamDescriptionSpecifier setProperty:footer forKey:@"footerText"];
        [(NSMutableArray *)_specifiers addObject:jetsamDescriptionSpecifier];
    }
    return _specifiers;
}

@end
