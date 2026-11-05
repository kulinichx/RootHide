#import "DOLowPowerScheduleController.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import "../DOSupporterLicense.h"
#import "../../../../BaseBin/roothidehooks/RCLowPowerSchedule.h"
#include <notify.h>

static NSString * const DOScheduleThemeDidChangeNotification = @"DOCustomGlassTheme.DidChange";

// Shared renderer implemented by the existing RC9 main page.
@interface DOCustomLiquidGlassView : UIView
@property(nonatomic, assign) CGFloat materialScale;
@property(nonatomic, assign) CGFloat preferredCornerRadius;
- (instancetype)initWithCornerRadius:(CGFloat)cornerRadius baseTintAlpha:(CGFloat)baseTintAlpha;
- (void)reloadMaterial;
@end

@interface DOLowPowerScheduleController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UISwitch *enabledSwitch;
@property(nonatomic, strong) UIDatePicker *timePicker;
@property(nonatomic, strong) UIButton *backButton;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DOCustomLiquidGlassView *> *sectionGlassViews;
@property(nonatomic, strong) UIImpactFeedbackGenerator *timeFeedback;
@property(nonatomic, copy) NSArray<NSLayoutConstraint *> *timePickerCellConstraints;
@property(nonatomic) NSInteger editingTime;
@property(nonatomic) BOOL timePickerExpanded;
@property(nonatomic) NSInteger lastStartMinute;
@property(nonatomic) NSInteger lastEndMinute;
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
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:image withConfiguration:configuration]
           forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIDatePicker *)timePickerForMinute:(NSInteger)minute
{
    UIDatePicker *picker = [UIDatePicker new];
    picker.datePickerMode = UIDatePickerModeTime;
    picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    picker.minuteInterval = 1;
    picker.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    // Time-only editing must also allow a time missing in today's local DST.
    picker.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    picker.date = [NSDate dateWithTimeIntervalSinceReferenceDate:minute * 60];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    [picker.heightAnchor constraintEqualToConstant:216].active = YES;
    [picker addTarget:self action:@selector(timeChanged:) forControlEvents:UIControlEventValueChanged];
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
    self.editingTime = 0;
    self.timePickerExpanded = NO;
    self.sectionGlassViews = [NSMutableDictionary new];
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
    self.lastStartMinute = [self.savedConfiguration[@"StartMinute"] integerValue];
    self.lastEndMinute = [self.savedConfiguration[@"EndMinute"] integerValue];
    self.timePicker = [self timePickerForMinute:self.lastStartMinute];
    self.timePicker.accessibilityLabel = DOLocalizedString(@"LowPowerSchedule_OnTime");

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.backgroundView = nil;
    self.tableView.opaque = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [self refreshScheduleScrollInsets];
    [self.view addSubview:self.tableView];

    UIButton *back = [self chromeButton:@"chevron.left" action:@selector(backPressed)
        label:DOLocalizedString(@"Button_Cancel")];
    self.backButton = back;
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
        ^(__unused int value) {
            if (weakSelf.viewIfLoaded.window &&
                weakSelf.navigationController.topViewController == weakSelf) [weakSelf refreshStatus];
        }) == NOTIFY_STATUS_OK)
        self.statusToken = token;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleThemeDidChange:)
        name:DOScheduleThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshScheduleAppearance];
    [self requestStatus];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self refreshScheduleScrollInsets];
    [self refreshScheduleGlassFrames];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    self.timeFeedback = nil;
}

- (void)dealloc
{
    if (self.isViewLoaded && self.statusToken >= 0) notify_cancel(self.statusToken);
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)scheduleThemeDidChange:(NSNotification *)notification
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf refreshScheduleAppearance];
    });
}

- (void)styleScheduleCell:(UITableViewCell *)cell
{
    cell.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    cell.backgroundColor = DORHSupporterIsVerified() ? UIColor.clearColor :
        [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
}

- (void)refreshScheduleScrollInsets
{
    if (!self.tableView) return;
    CGFloat bottom = MAX(88.0, self.view.safeAreaInsets.bottom + 64.0);
    UIEdgeInsets insets = self.tableView.contentInset;
    insets.bottom = bottom;
    if (!UIEdgeInsetsEqualToEdgeInsets(self.tableView.contentInset, insets))
        self.tableView.contentInset = insets;
    if (!UIEdgeInsetsEqualToEdgeInsets(self.tableView.scrollIndicatorInsets, insets))
        self.tableView.scrollIndicatorInsets = insets;
}

- (void)refreshScheduleGlassFrames
{
    if (!DORHSupporterIsVerified()) {
        for (DOCustomLiquidGlassView *glass in self.sectionGlassViews.allValues) glass.hidden = YES;
        return;
    }

    for (NSInteger section = 0; section < self.tableView.numberOfSections; section++) {
        NSInteger rows = [self.tableView numberOfRowsInSection:section];
        if (!rows) continue;
        CGRect first = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:section]];
        CGRect last = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:rows - 1 inSection:section]];
        CGRect frame = CGRectUnion(first, last);
        // Keep the last valid frame during transient foreground/layout passes.
        if (CGRectIsEmpty(frame) || CGRectGetHeight(frame) < 2) continue;
        DOCustomLiquidGlassView *glass = self.sectionGlassViews[@(section)];
        BOOL created = NO;
        if (!glass) {
            glass = [[DOCustomLiquidGlassView alloc] initWithCornerRadius:18 baseTintAlpha:0.038];
            glass.userInteractionEnabled = NO;
            glass.materialScale = 0.88;
            glass.preferredCornerRadius = 18;
            glass.layer.cornerRadius = 18;
            glass.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
            self.sectionGlassViews[@(section)] = glass;
            [self.tableView insertSubview:glass atIndex:0];
            created = YES;
        }
        CGRect glassFrame = CGRectInset(frame, 1, 0.5);
        if (glass.hidden) glass.hidden = NO;
        if (!CGRectEqualToRect(glass.frame, glassFrame)) glass.frame = glassFrame;
        if (created) [self.tableView sendSubviewToBack:glass];
    }
}

- (void)refreshScheduleAppearance
{
    self.backButton.tintColor = UIColor.labelColor;
    self.saveButton.tintColor = UIColor.labelColor;
    for (UITableViewCell *cell in self.tableView.visibleCells) [self styleScheduleCell:cell];
    [self refreshScheduleGlassFrames];
    for (DOCustomLiquidGlassView *glass in self.sectionGlassViews.allValues)
        [glass reloadMaterial];
}

- (BOOL)hasChanges
{
    return self.enabledSwitch.on != [self.savedConfiguration[@"Enabled"] boolValue] ||
        self.lastStartMinute != [self.savedConfiguration[@"StartMinute"] integerValue] ||
        self.lastEndMinute != [self.savedConfiguration[@"EndMinute"] integerValue];
}

- (void)draftChanged
{
    self.saveButton.enabled = self.hasChanges || self.timePickerExpanded;
}

- (void)prepareTimeFeedback
{
    if (!self.timeFeedback)
        self.timeFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
    [self.timeFeedback prepare];
}

- (void)timeChanged:(UIDatePicker *)picker
{
    NSInteger minute = [self minuteFromPicker:picker];
    NSInteger previous = self.editingTime == 0 ? self.lastStartMinute : self.lastEndMinute;
    if (self.editingTime == 0) self.lastStartMinute = minute;
    else self.lastEndMinute = minute;
    if (minute != previous && self.viewIfLoaded.window &&
        self.navigationController.topViewController == self &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        // Match GlassFolders' crisp detent feedback, once per changed value.
        [self prepareTimeFeedback];
        [self.timeFeedback impactOccurredWithIntensity:0.68];
        [self.timeFeedback prepare];
    }
    [self updateTimeLabels];
    [self draftChanged];
}

- (NSDate *)dateForMinute:(NSInteger)minute
{
    return [NSDate dateWithTimeIntervalSinceReferenceDate:minute * 60];
}

- (void)attachTimePickerToCell:(UITableViewCell *)cell
{
    if (self.timePicker.superview == cell.contentView) {
        self.timePicker.hidden = NO;
        return;
    }
    [NSLayoutConstraint deactivateConstraints:self.timePickerCellConstraints ?: @[]];
    self.timePickerCellConstraints = nil;
    [self.timePicker removeFromSuperview];
    self.timePicker.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:self.timePicker];
    self.timePickerCellConstraints = @[
        [self.timePicker.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
        [self.timePicker.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
        [self.timePicker.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [self.timePicker.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ];
    [NSLayoutConstraint activateConstraints:self.timePickerCellConstraints];
    self.timePicker.hidden = NO;
}

- (void)setTimePickerExpanded:(BOOL)expanded animated:(BOOL)animated
{
    if (self.timePickerExpanded == expanded) {
        [self draftChanged];
        return;
    }
    if (!expanded) {
        // Remove the fixed-height wheel before collapsing its zero-height row.
        [NSLayoutConstraint deactivateConstraints:self.timePickerCellConstraints ?: @[]];
        self.timePickerCellConstraints = nil;
        [self.timePicker removeFromSuperview];
        self.timePicker.hidden = YES;
    }
    self.timePickerExpanded = expanded;
    [self updateTimeLabels];
    void (^updates)(void) = ^{
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
    };
    if (animated) {
        [UIView animateWithDuration:0.22 animations:updates];
    } else {
        updates();
    }
    if (expanded) {
        [self.tableView layoutIfNeeded];
        NSIndexPath *pickerPath = [NSIndexPath indexPathForRow:3 inSection:0];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:pickerPath];
        if (cell) [self attachTimePickerToCell:cell];
    }
    [self refreshScheduleGlassFrames];
    [self draftChanged];
}

- (BOOL)isStartRow:(NSIndexPath *)indexPath
{
    return indexPath.section == 0 && indexPath.row == 1;
}

- (void)updateTimeLabels
{
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if (indexPath.section != 0 || indexPath.row == 0 || indexPath.row == 3) continue;
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        NSInteger minute = [self isStartRow:indexPath] ? self.lastStartMinute : self.lastEndMinute;
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"%02ld:%02ld", (long)(minute / 60), (long)(minute % 60)];
        BOOL selected = (self.editingTime == 0 && [self isStartRow:indexPath]) ||
            (self.editingTime == 1 && ![self isStartRow:indexPath]);
        cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = UIColor.systemBlueColor;
    }
}

- (void)requestStatus
{
    NSDate *queryDate = NSDate.date;
    self.queryDate = queryDate;
    if (![self.runtimeStatus[@"Revision"] isEqual:self.savedConfiguration[@"Revision"]])
        [self refreshStatus];
    notify_post(RC_LOW_POWER_QUERY);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([weakSelf.queryDate isEqualToDate:queryDate] &&
            weakSelf.viewIfLoaded.window &&
            weakSelf.navigationController.topViewController == weakSelf &&
            UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
            [weakSelf refreshStatus];
    });
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    if (self.viewIfLoaded.window && self.navigationController.topViewController == self)
        [self requestStatus];
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    self.timeFeedback = nil;
}

- (void)refreshStatus
{
    self.runtimeStatus = [DOEnvironmentManager.sharedManager lowPowerScheduleStatus];
    NSIndexPath *statusPath = [NSIndexPath indexPathForRow:0 inSection:1];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:statusPath];
    NSString *text = self.statusText;
    if (![cell.textLabel.text isEqualToString:text]) {
        cell.textLabel.text = text;
        [cell setNeedsLayout];
        [cell layoutIfNeeded];
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView endUpdates];
        }];
    }
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
        @"LowPowerSchedule_OnAction" : @"LowPowerSchedule_OffAction");
    return [NSString stringWithFormat:DOLocalizedString(@"LowPowerSchedule_Next"),
        [formatter stringFromDate:next[@"Date"]], action];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 4 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return DOLocalizedString(section == 0 ? @"LowPowerSchedule_Title" : @"LowPowerSchedule_Status");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return DOLocalizedString(section == 0 ? @"LowPowerSchedule_Footer" : @"LowPowerSchedule_RuntimeFooter");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    [self styleScheduleCell:cell];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 1) {
        cell.textLabel.text = self.statusText;
    } else if (indexPath.row == 3) {
        if (self.timePickerExpanded) [self attachTimePickerToCell:cell];
    } else if (indexPath.row == 0) {
        cell.textLabel.text = DOLocalizedString(@"LowPowerSchedule_Enable");
        cell.accessoryView = self.enabledSwitch;
    } else {
        BOOL start = [self isStartRow:indexPath];
        cell.textLabel.text = DOLocalizedString(start ? @"LowPowerSchedule_OnTime" : @"LowPowerSchedule_OffTime");
        NSInteger minute = start ? self.lastStartMinute : self.lastEndMinute;
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"%02ld:%02ld", (long)(minute / 60), (long)(minute % 60)];
        cell.detailTextLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular]];
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.textColor = UIColor.systemBlueColor;
        BOOL isEditingTime = self.timePickerExpanded &&
            ((self.editingTime == 0 && start) || (self.editingTime == 1 && !start));
        cell.accessoryType = isEditingTime ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = UIColor.systemBlueColor;
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
        cell.accessibilityHint = DOLocalizedString(@"LowPowerSchedule_EditTime");
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        cell.selectedBackgroundView = selected;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0 && indexPath.row == 3 ?
        (self.timePickerExpanded ? 232 : 0) : UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self styleScheduleCell:cell];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || indexPath.row == 0 || indexPath.row == 3) return;
    self.editingTime = [self isStartRow:indexPath] ? 0 : 1;
    self.timePicker.date = [self dateForMinute:self.editingTime == 0 ?
        self.lastStartMinute : self.lastEndMinute];
    self.timePicker.accessibilityLabel = DOLocalizedString(self.editingTime == 0 ?
        @"LowPowerSchedule_OnTime" : @"LowPowerSchedule_OffTime");
    [self setTimePickerExpanded:YES animated:YES];
    [self updateTimeLabels];
    [self prepareTimeFeedback];
}

- (void)savePressed
{
    if (!self.hasChanges) {
        [self setTimePickerExpanded:NO animated:YES];
        return;
    }
    NSInteger start = self.lastStartMinute;
    NSInteger end = self.lastEndMinute;
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
    [self setTimePickerExpanded:NO animated:YES];
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
