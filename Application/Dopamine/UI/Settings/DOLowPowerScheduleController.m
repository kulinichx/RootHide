#import "DOLowPowerScheduleController.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import "../../../../BaseBin/roothidehooks/RCLowPowerSchedule.h"
#include <notify.h>

@interface DOLowPowerScheduleController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UISwitch *enabledSwitch;
@property(nonatomic, strong) UIDatePicker *startPicker;
@property(nonatomic, strong) UIDatePicker *endPicker;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic, copy) NSDictionary *savedConfiguration;
@property(nonatomic, copy) NSDictionary *runtimeStatus;
@property(nonatomic, strong) NSDate *queryDate;
@property(nonatomic) int statusToken;
@end

@implementation DOLowPowerScheduleController

- (UIButton *)chromeButton:(NSString *)image action:(SEL)action label:(NSString *)label
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = UIColor.labelColor;
    [button setImage:[UIImage systemImageNamed:image] forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIDatePicker *)timePicker:(NSInteger)minute
{
    UIDatePicker *picker = [UIDatePicker new];
    picker.datePickerMode = UIDatePickerModeTime;
    picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    picker.minuteInterval = 1;
    picker.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    // Time-only editing must also allow a time missing in today's local DST.
    picker.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    picker.date = [NSDate dateWithTimeIntervalSinceReferenceDate:minute * 60];
    picker.frame = CGRectMake(0, 0, 150, 44);
    [picker addTarget:self action:@selector(draftChanged) forControlEvents:UIControlEventValueChanged];
    return picker;
}

- (NSInteger)minuteFromPicker:(UIDatePicker *)picker
{
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDateComponents *components = [calendar components:NSCalendarUnitHour | NSCalendarUnitMinute
                                              fromDate:picker.date];
    return components.hour * 60 + components.minute;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.statusToken = -1;
    self.title = DOLocalizedString(@"LowPowerSchedule_Title");
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;
    self.savedConfiguration = [DOEnvironmentManager.sharedManager lowPowerScheduleConfiguration];
    if (!rcLowPowerConfigurationValid(self.savedConfiguration))
        self.savedConfiguration = rcLowPowerDefaultConfiguration();

    self.enabledSwitch = [UISwitch new];
    self.enabledSwitch.on = [self.savedConfiguration[@"Enabled"] boolValue];
    [self.enabledSwitch addTarget:self action:@selector(draftChanged)
                forControlEvents:UIControlEventValueChanged];
    self.startPicker = [self timePicker:[self.savedConfiguration[@"StartMinute"] integerValue]];
    self.endPicker = [self timePicker:[self.savedConfiguration[@"EndMinute"] integerValue]];
    self.startPicker.accessibilityLabel = DOLocalizedString(@"LowPowerSchedule_OnTime");
    self.endPicker.accessibilityLabel = DOLocalizedString(@"LowPowerSchedule_OffTime");

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [self.view addSubview:self.tableView];

    UIButton *back = [self chromeButton:@"chevron.left" action:@selector(backPressed)
        label:DOLocalizedString(@"Button_Cancel")];
    self.saveButton = [self chromeButton:@"checkmark" action:@selector(savePressed)
        label:DOLocalizedString(@"LowPowerSchedule_Save")];
    self.saveButton.enabled = NO;
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = self.title;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textColor = UIColor.labelColor;
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 2;
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:back];
    [self.view addSubview:title];
    [self.view addSubview:self.saveButton];
    [NSLayoutConstraint activateConstraints:@[
        [back.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:10],
        [back.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [back.widthAnchor constraintEqualToConstant:44],
        [back.heightAnchor constraintEqualToConstant:44],
        [self.saveButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [self.saveButton.topAnchor constraintEqualToAnchor:back.topAnchor],
        [self.saveButton.widthAnchor constraintEqualToConstant:44],
        [self.saveButton.heightAnchor constraintEqualToConstant:44],
        [title.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:8],
        [title.trailingAnchor constraintEqualToAnchor:self.saveButton.leadingAnchor constant:-8],
        [title.topAnchor constraintEqualToAnchor:back.topAnchor],
        [title.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.tableView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    UIScreenEdgePanGestureRecognizer *edge = [[UIScreenEdgePanGestureRecognizer alloc]
        initWithTarget:self action:@selector(edgeBack:)];
    edge.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edge];

    __weak typeof(self) weakSelf = self;
    int token = -1;
    if (notify_register_dispatch(RC_LOW_POWER_STATUS_CHANGED, &token, dispatch_get_main_queue(),
        ^(__unused int value) { [weakSelf refreshStatus]; }) == NOTIFY_STATUS_OK)
        self.statusToken = token;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self requestStatus];
}

- (void)dealloc
{
    if (self.statusToken >= 0) notify_cancel(self.statusToken);
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)hasChanges
{
    return self.enabledSwitch.on != [self.savedConfiguration[@"Enabled"] boolValue] ||
        [self minuteFromPicker:self.startPicker] != [self.savedConfiguration[@"StartMinute"] integerValue] ||
        [self minuteFromPicker:self.endPicker] != [self.savedConfiguration[@"EndMinute"] integerValue];
}

- (void)draftChanged
{
    self.saveButton.enabled = self.hasChanges;
}

- (void)requestStatus
{
    self.queryDate = NSDate.date;
    [self refreshStatus];
    notify_post(RC_LOW_POWER_QUERY);
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self requestStatus];
}

- (void)refreshStatus
{
    self.runtimeStatus = [DOEnvironmentManager.sharedManager lowPowerScheduleStatus];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                 withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)statusText
{
    if ([self.savedConfiguration[@"Revision"] isEqual:rcLowPowerDefaultConfiguration()[@"Revision"]])
        return DOLocalizedString(@"LowPowerSchedule_Disabled");
    NSDictionary *status = self.runtimeStatus;
    NSDate *updated = status[@"Updated"];
    BOOL fresh = [updated isKindOfClass:NSDate.class] &&
        [updated timeIntervalSinceDate:self.queryDate] >= -1;
    if (!fresh || ![status[@"Revision"] isEqual:self.savedConfiguration[@"Revision"]])
        return DOLocalizedString(@"LowPowerSchedule_Waiting");
    NSString *state = status[@"State"];
    if ([state isEqual:@"disabled"]) return DOLocalizedString(@"LowPowerSchedule_Disabled");
    if ([state isEqual:@"unsupported"]) return DOLocalizedString(@"LowPowerSchedule_Unsupported");
    if ([state isEqual:@"applyFailed"]) return DOLocalizedString(@"LowPowerSchedule_ApplyFailed");
    if (![state isEqual:@"scheduled"]) return DOLocalizedString(@"LowPowerSchedule_RuntimeFailed");
    NSDictionary *next = status[@"Next"];
    if (![next isKindOfClass:NSDictionary.class] || ![next[@"Date"] isKindOfClass:NSDate.class])
        return DOLocalizedString(@"LowPowerSchedule_Waiting");
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSString *action = DOLocalizedString([next[@"PowerMode"] boolValue] ?
        @"LowPowerSchedule_OnTime" : @"LowPowerSchedule_OffTime");
    return [NSString stringWithFormat:DOLocalizedString(@"LowPowerSchedule_Next"),
        [formatter stringFromDate:next[@"Date"]], action];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 3 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return DOLocalizedString(section == 0 ? @"LowPowerSchedule_Daily" : @"LowPowerSchedule_Status");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return DOLocalizedString(section == 0 ? @"LowPowerSchedule_Footer" : @"LowPowerSchedule_RuntimeFooter");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 1) {
        cell.textLabel.text = self.statusText;
    } else {
        NSArray *keys = @[@"LowPowerSchedule_Enable", @"LowPowerSchedule_OnTime", @"LowPowerSchedule_OffTime"];
        cell.textLabel.text = DOLocalizedString(keys[indexPath.row]);
        cell.accessoryView = indexPath.row == 0 ? self.enabledSwitch :
            (indexPath.row == 1 ? self.startPicker : self.endPicker);
    }
    return cell;
}

- (void)savePressed
{
    NSInteger start = [self minuteFromPicker:self.startPicker];
    NSInteger end = [self minuteFromPicker:self.endPicker];
    if (start == end) {
        [self showMessage:DOLocalizedString(@"LowPowerSchedule_SameTime")];
        return;
    }
    NSError *error = nil;
    if (![DOEnvironmentManager.sharedManager saveLowPowerScheduleEnabled:self.enabledSwitch.on
            startMinute:start endMinute:end error:&error]) {
        [self showMessage:[NSString stringWithFormat:DOLocalizedString(@"LowPowerSchedule_SaveFailed"),
            error.localizedDescription ?: @"Unknown"]];
        return;
    }
    self.savedConfiguration = [DOEnvironmentManager.sharedManager lowPowerScheduleConfiguration];
    self.saveButton.enabled = NO;
    [self requestStatus];
}

- (void)showMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)backPressed
{
    if (!self.hasChanges) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.title
        message:DOLocalizedString(@"LowPowerSchedule_Discard") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"LowPowerSchedule_DiscardButton")
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [self.navigationController popViewControllerAnimated:YES];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)edgeBack:(UIScreenEdgePanGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateEnded &&
        [gesture translationInView:self.view].x > 60 &&
        [gesture velocityInView:self.view].x > 80) [self backPressed];
}
@end
