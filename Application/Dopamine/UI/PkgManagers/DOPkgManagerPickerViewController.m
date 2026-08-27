//
//  DOPkgManagerPickerViewController.m
//  Dopamine
//
//  Created by tomt000 on 11/02/2024.
//

#import "DOPkgManagerPickerViewController.h"
#import "DOPkgManagerPickerView.h"
#import "DOEnvironmentManager.h"


@interface DOPkgManagerPickerViewController ()

@property (nonatomic, assign) BOOL repairInProgress;

@end

@implementation DOPkgManagerPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    DOPkgManagerPickerView *picker = [[DOPkgManagerPickerView alloc] initWithCallback:^(BOOL success) {
        (void)success;
        if (self.repairInProgress) return;
        self.repairInProgress = YES;
        self.view.userInteractionEnabled = NO;

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *repairError = [[DOEnvironmentManager sharedManager] repairPackageManagers];

            dispatch_async(dispatch_get_main_queue(), ^{
                self.repairInProgress = NO;
                self.view.userInteractionEnabled = YES;

                NSString *title = repairError ? @"Package Manager Repair Failed" : NSLocalizedString(@"Button_Reinstall_Package_Managers", nil);
                NSString *message = repairError.localizedDescription ?: @"Selected package managers are healthy and up to date.";
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                               message:message
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__kindof UIAlertAction *action) {
                    (void)action;
                    if (!repairError) {
                        [self.navigationController popViewControllerAnimated:YES];
                    }
                }]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        });
    }];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:picker];
    [NSLayoutConstraint activateConstraints:@[
        [picker.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [picker.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [picker.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [picker.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}


@end
