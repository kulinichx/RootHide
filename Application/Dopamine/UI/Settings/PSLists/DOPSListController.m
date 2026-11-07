//
//  DOPSListController.m
//  Dopamine
//
//  Created by tomt000 on 26/01/2024.
//

#import "DOPSListController.h"
#import "DOThemeManager.h"
#import "DOUIManager.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSUInteger const DOScrollTraceCapacity = 1024;

typedef struct {
    CFTimeInterval timestamp;
    NSUInteger phase;
    CGRect frame;
    CGRect bounds;
    CGRect pageBounds;
    CGPoint offset;
    CGSize contentSize;
    UIEdgeInsets contentInset;
    UIEdgeInsets adjustedInset;
    UIEdgeInsets pageSafeArea;
    BOOL tracking;
    BOOL dragging;
    BOOL decelerating;
} DOScrollTraceSample;

static id DOScrollTraceNumber(double value)
{
    if (isfinite(value)) return @(value);
    return [NSString stringWithFormat:@"%.17g", value];
}

static NSArray *DOScrollTraceRect(CGRect rect)
{
    return @[DOScrollTraceNumber(rect.origin.x), DOScrollTraceNumber(rect.origin.y),
        DOScrollTraceNumber(rect.size.width), DOScrollTraceNumber(rect.size.height)];
}

static NSArray *DOScrollTraceInsets(UIEdgeInsets insets)
{
    return @[DOScrollTraceNumber(insets.top), DOScrollTraceNumber(insets.left),
        DOScrollTraceNumber(insets.bottom), DOScrollTraceNumber(insets.right)];
}

static NSArray *DOScrollTraceRecords(const DOScrollTraceSample *samples, NSUInteger writeCount)
{
    NSUInteger count = MIN(writeCount, DOScrollTraceCapacity);
    NSUInteger start = writeCount - count;
    NSMutableArray *records = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = start; i < writeCount; i++) {
        DOScrollTraceSample sample = samples[i % DOScrollTraceCapacity];
        [records addObject:@{
            @"seconds": DOScrollTraceNumber(sample.timestamp), @"phase": @(sample.phase),
            @"table_frame": DOScrollTraceRect(sample.frame),
            @"table_bounds": DOScrollTraceRect(sample.bounds),
            @"page_bounds": DOScrollTraceRect(sample.pageBounds),
            @"content_size": @[DOScrollTraceNumber(sample.contentSize.width),
                DOScrollTraceNumber(sample.contentSize.height)],
            @"content_inset": DOScrollTraceInsets(sample.contentInset),
            @"adjusted_inset": DOScrollTraceInsets(sample.adjustedInset),
            @"page_safe_area": DOScrollTraceInsets(sample.pageSafeArea),
            @"offset_y": DOScrollTraceNumber(sample.offset.y),
            @"resting_top_y": DOScrollTraceNumber(-sample.adjustedInset.top),
            @"tracking": @(sample.tracking), @"dragging": @(sample.dragging),
            @"decelerating": @(sample.decelerating),
        }];
    }
    return records;
}

@interface DOScrollTraceTarget : NSObject
@property(nonatomic, weak) DOPSListController *controller;
- (void)tick:(CADisplayLink *)link;
@end

@interface DOPSListController ()
@property(nonatomic) BOOL scrollTraceInstalled;
@property(nonatomic) BOOL scrollTraceArmed;
@property(nonatomic) BOOL scrollTraceCapturing;
@property(nonatomic, strong) NSMutableData *scrollTraceBuffer;
@property(nonatomic) NSUInteger scrollTraceWriteCount;
@property(nonatomic) CFTimeInterval scrollTraceStart;
@property(nonatomic) CFTimeInterval scrollTraceLastMotion;
@property(nonatomic) CGPoint scrollTraceLastOffset;
@property(nonatomic, strong) CADisplayLink *scrollTraceLink;
@property(nonatomic, copy) NSString *scrollTraceStopReason;
- (void)scrollDiagnosticsTick:(CADisplayLink *)link;
@end

@implementation DOScrollTraceTarget
- (void)tick:(CADisplayLink *)link
{
    DOPSListController *controller = self.controller;
    if (controller) [controller scrollDiagnosticsTick:link];
    else [link invalidate];
}
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
    [self recordScrollDiagnosticsPhase:3];
    [super viewDidLayoutSubviews];
    [self recordScrollDiagnosticsPhase:4];
    // Preferences owns the table's frame. Shrinking it here makes the next
    // superclass layout expand it again and reset an active top overscroll.

    // Keep UIKit's automatic top safe-area adjustment for Preferences lists.
    // The raw 24pt bottom inset adds scroll room; UIKit adds the device safe area.
    UIEdgeInsets insets = _table.contentInset;
    insets.bottom = 24.0;
    if (!UIEdgeInsetsEqualToEdgeInsets(_table.contentInset, insets))
        _table.contentInset = insets;
    [self recordScrollDiagnosticsPhase:5];
}

#pragma mark - Opt-in scroll diagnostics

- (void)installScrollDiagnosticsForBackButton:(UIButton *)button
{
    if (self.scrollTraceInstalled) return;
    self.scrollTraceInstalled = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(scrollDiagnosticsWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [_table.panGestureRecognizer addTarget:self action:@selector(scrollDiagnosticsPan:)];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(scrollDiagnosticsPressed:)];
    press.minimumPressDuration = 0.8;
    [button addGestureRecognizer:press];
}

- (void)recordScrollDiagnosticsPhase:(NSUInteger)phase
{
    if (!self.scrollTraceCapturing || !self.scrollTraceBuffer || !_table) return;
    DOScrollTraceSample *samples = self.scrollTraceBuffer.mutableBytes;
    samples[self.scrollTraceWriteCount % DOScrollTraceCapacity] = (DOScrollTraceSample){
        .timestamp = CACurrentMediaTime() - self.scrollTraceStart,
        .phase = phase,
        .frame = _table.frame,
        .bounds = _table.bounds,
        .pageBounds = self.view.bounds,
        .offset = _table.contentOffset,
        .contentSize = _table.contentSize,
        .contentInset = _table.contentInset,
        .adjustedInset = _table.adjustedContentInset,
        .pageSafeArea = self.view.safeAreaInsets,
        .tracking = _table.tracking,
        .dragging = _table.dragging,
        .decelerating = _table.decelerating,
    };
    self.scrollTraceWriteCount++;
}

- (void)stopScrollDiagnosticsWithReason:(NSString *)reason
{
    if (!self.scrollTraceCapturing && !self.scrollTraceLink) return;
    [self recordScrollDiagnosticsPhase:6];
    self.scrollTraceCapturing = NO;
    self.scrollTraceStopReason = reason;
    [self.scrollTraceLink invalidate];
    self.scrollTraceLink = nil;
}

- (void)scrollDiagnosticsPan:(UIPanGestureRecognizer *)pan
{
    if (!self.scrollTraceArmed || pan.state != UIGestureRecognizerStateBegan ||
        !self.viewIfLoaded.window || !_table) return;
    [self stopScrollDiagnosticsWithReason:@"next_gesture"];
    self.scrollTraceWriteCount = 0;
    self.scrollTraceStart = CACurrentMediaTime();
    self.scrollTraceLastMotion = self.scrollTraceStart;
    self.scrollTraceLastOffset = _table.contentOffset;
    self.scrollTraceStopReason = @"capturing";
    self.scrollTraceCapturing = YES;
    [self recordScrollDiagnosticsPhase:1];
    DOScrollTraceTarget *target = [DOScrollTraceTarget new];
    target.controller = self;
    self.scrollTraceLink = [CADisplayLink displayLinkWithTarget:target
        selector:@selector(tick:)];
    self.scrollTraceLink.preferredFramesPerSecond = 60;
    [self.scrollTraceLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)scrollDiagnosticsTick:(CADisplayLink *)link
{
    if (link != self.scrollTraceLink) {
        [link invalidate];
        return;
    }
    if (!self.scrollTraceCapturing || !self.viewIfLoaded.window ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        (self.navigationController && self.navigationController.topViewController != self)) {
        [self stopScrollDiagnosticsWithReason:@"not_visible_or_active"];
        return;
    }
    [self recordScrollDiagnosticsPhase:2];
    CFTimeInterval now = CACurrentMediaTime();
    CGPoint offset = _table.contentOffset;
    if (_table.tracking || _table.dragging || _table.decelerating ||
        !CGPointEqualToPoint(offset, self.scrollTraceLastOffset))
        self.scrollTraceLastMotion = now;
    self.scrollTraceLastOffset = offset;
    if (now - self.scrollTraceStart >= 8.0)
        [self stopScrollDiagnosticsWithReason:@"eight_second_limit"];
    else if (now - self.scrollTraceLastMotion >= 0.5)
        [self stopScrollDiagnosticsWithReason:@"settled"];
}

- (void)scrollDiagnosticsWillResignActive:(NSNotification *)notification
{
    self.scrollTraceArmed = NO;
    [self stopScrollDiagnosticsWithReason:@"application_inactive"];
}

- (void)viewWillDisappear:(BOOL)animated
{
    self.scrollTraceArmed = NO;
    [self stopScrollDiagnosticsWithReason:@"page_disappeared"];
    [super viewWillDisappear:animated];
}

- (void)showScrollDiagnosticsMessage:(NSString *)message onConfirm:(void (^)(void))confirm
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:DOLocalizedString(@"ScrollDiagnostics_Title")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (confirm) confirm();
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)scrollDiagnosticsPressed:(UILongPressGestureRecognizer *)press
{
    if (press.state != UIGestureRecognizerStateBegan || self.presentedViewController ||
        !self.viewIfLoaded.window) return;
    if (!self.scrollTraceArmed) {
        self.scrollTraceBuffer = [NSMutableData
            dataWithLength:sizeof(DOScrollTraceSample) * DOScrollTraceCapacity];
        self.scrollTraceWriteCount = 0;
        __weak typeof(self) weakSelf = self;
        [self showScrollDiagnosticsMessage:DOLocalizedString(@"ScrollDiagnostics_Armed")
            onConfirm:^{
                if (weakSelf.viewIfLoaded.window &&
                    UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
                    weakSelf.scrollTraceArmed = YES;
            }];
        return;
    }
    [self stopScrollDiagnosticsWithReason:@"share_requested"];
    if (!self.scrollTraceWriteCount) {
        [self showScrollDiagnosticsMessage:DOLocalizedString(@"ScrollDiagnostics_Empty")
            onConfirm:nil];
        return;
    }
    self.scrollTraceArmed = NO;
    NSUInteger count = MIN(self.scrollTraceWriteCount, DOScrollTraceCapacity);
    NSUInteger start = self.scrollTraceWriteCount - count;
    NSArray *records = DOScrollTraceRecords(self.scrollTraceBuffer.bytes,
        self.scrollTraceWriteCount);
    NSString *sourceCommit = @"not_embedded";
#if defined(NIGHTLY) && defined(COMMIT_HASH)
    sourceCommit = [NSString stringWithUTF8String:COMMIT_HASH];
#endif
    NSDictionary *report = @{
        @"schema": @1,
        @"app_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"source_commit": sourceCommit ?: @"",
        @"system": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"controller": NSStringFromClass(self.class),
        @"table_class": NSStringFromClass(_table.class),
        @"inset_adjustment_behavior": @(_table.contentInsetAdjustmentBehavior),
        @"table_style": @(_table.style),
        @"estimated_row_height": DOScrollTraceNumber(_table.estimatedRowHeight),
        @"estimated_header_height": DOScrollTraceNumber(_table.estimatedSectionHeaderHeight),
        @"estimated_footer_height": DOScrollTraceNumber(_table.estimatedSectionFooterHeight),
        @"stop_reason": self.scrollTraceStopReason ?: @"",
        @"sample_count": @(count),
        @"dropped_samples": @(start),
        @"rect_order": @"x,y,width,height",
        @"inset_order": @"top,left,bottom,right",
        @"phases": @{@"1": @"gesture_begin", @"2": @"display_tick",
            @"3": @"before_preferences_layout", @"4": @"after_preferences_layout",
            @"5": @"after_rc9_layout", @"6": @"capture_stop"},
        @"samples": records,
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report
        options:NSJSONWritingPrettyPrinted error:&error];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"RC9-scroll-%@.json", NSUUID.UUID.UUIDString]]];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [self showScrollDiagnosticsMessage:error.localizedDescription ?:
            DOLocalizedString(@"ScrollDiagnostics_ExportFailed") onConfirm:nil];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = press.view;
    share.popoverPresentationController.sourceRect = press.view.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)dealloc
{
    [_scrollTraceLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:UIApplicationWillResignActiveNotification object:nil];
}

#pragma mark - Status Bar

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}


@end
