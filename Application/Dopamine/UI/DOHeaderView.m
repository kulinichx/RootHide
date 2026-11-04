//
//  DOHeaderView.m
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import "DOHeaderView.h"
#import "DOThemeManager.h"
#import <math.h>
#import <time.h>

@interface DOHeaderView ()

@property (nonatomic) UIImageView *logoView;
@property (nonatomic) UILabel *timerLabel;
@property (nonatomic, strong) NSTimer *uptimeTimer;

@end

@implementation DOHeaderView

-(id)initWithImage:(UIImage *)image subtitles:(NSArray<NSAttributedString *> *)subtitles {
    if (self = [super init]) {
        UIStackView *stackView = [[UIStackView alloc] init];
        stackView.axis = UILayoutConstraintAxisVertical;
        stackView.spacing = 2;
        stackView.translatesAutoresizingMaskIntoConstraints = NO;
        stackView.alignment = UIStackViewAlignmentLeading;

        [self addSubview:stackView];

        [NSLayoutConstraint activateConstraints:@[
            [stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [stackView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        //1 - Add the logo to our stack
        self.logoView = [[UIImageView alloc] init];
        self.logoView.translatesAutoresizingMaskIntoConstraints = NO;
        self.logoView.image = [image imageWithAlignmentRectInsets:UIEdgeInsetsMake(7, 0, -7, 0)];
        [stackView addArrangedSubview:self.logoView];

        [NSLayoutConstraint activateConstraints:@[
            [self.logoView.heightAnchor constraintEqualToConstant:40],
            [self.logoView.widthAnchor constraintEqualToAnchor:self.logoView.heightAnchor multiplier:image.size.width / image.size.height],
        ]];

        //3 - Add our subtitles to our stack
        [subtitles enumerateObjectsUsingBlock:^(NSAttributedString *formatedText, NSUInteger idx, BOOL *stop) {
            UILabel *label = [[UILabel alloc] init];
            label.attributedText = formatedText;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [stackView addArrangedSubview:label];
            if (idx == 2) {
                self.timerLabel = label;
            }
        }];

        self.translatesAutoresizingMaskIntoConstraints = NO;

        DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
        if (theme.titleShadow)
        {
            self.layer.shadowColor = [UIColor blackColor].CGColor;
            self.layer.shadowOffset = CGSizeZero;
            self.layer.shadowRadius = 30;
            self.layer.shadowOpacity = 0.3;
        }
        
        [self updateLabel];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        for (NSNotificationName name in @[
            UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
            UISceneDidActivateNotification, UISceneWillDeactivateNotification,
            UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeHiddenNotification
        ]) {
            [center addObserver:self selector:@selector(uptimeContextDidChange:) name:name object:nil];
        }
    }
    return self;
}

- (void)setUptimeUpdatesEnabled:(BOOL)enabled {
    _uptimeUpdatesEnabled = enabled;
    [self resumeUptimeUpdates];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self stopUptimeTimer];
    [self resumeUptimeUpdates];
}

- (void)uptimeContextDidChange:(NSNotification *)notification {
    NSNotificationName name = notification.name;
    if (([name isEqualToString:UISceneDidActivateNotification] ||
         [name isEqualToString:UISceneWillDeactivateNotification]) &&
        notification.object != self.window.windowScene) return;
    if (([name isEqualToString:UIWindowDidBecomeVisibleNotification] ||
         [name isEqualToString:UIWindowDidBecomeHiddenNotification]) &&
        notification.object != self.window) return;

    if ([name isEqualToString:UIApplicationWillResignActiveNotification] ||
        [name isEqualToString:UISceneWillDeactivateNotification] ||
        [name isEqualToString:UIWindowDidBecomeHiddenNotification]) {
        [self stopUptimeTimer];
    } else {
        [self resumeUptimeUpdates];
    }
}

- (void)resumeUptimeUpdates {
    if (!self.uptimeUpdatesEnabled || !self.window || self.window.hidden ||
        self.window.windowScene.activationState != UISceneActivationStateForegroundActive ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self stopUptimeTimer];
        return;
    }

    [self updateLabel];
    if (self.uptimeTimer) return;

    __weak typeof(self) weakSelf = self;
    self.uptimeTimer = [NSTimer timerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }
        [strongSelf resumeUptimeUpdates];
    }];
    NSTimeInterval delay = 60.0 - fmod([self systemUptime], 60.0);
    self.uptimeTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
    [[NSRunLoop mainRunLoop] addTimer:self.uptimeTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUptimeTimer {
    [self.uptimeTimer invalidate];
    self.uptimeTimer = nil;
}

- (void)dealloc {
    [_uptimeTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateLabel {
        self.timerLabel.text = [self formatUptime];
}

- (NSTimeInterval)systemUptime {
    struct timespec ts = {0};
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}

- (NSString *)formatUptime {
    NSTimeInterval uptime = [self systemUptime];

    if (uptime < 60) {
        NSString *lessThanMinute = NSLocalizedString(@"System_Uptime_Less_Than_Minute", nil);
        if ([lessThanMinute isEqualToString:@"System_Uptime_Less_Than_Minute"]) {
            return @"uptime: less than 1 minute";
        }
        return lessThanMinute;
    }

    NSDateComponentsFormatter *formatter = [[NSDateComponentsFormatter alloc] init];
    formatter.allowedUnits = NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute;
    formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
    formatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropAll;
    formatter.maximumUnitCount = 3;

    NSString *duration = [formatter stringFromTimeInterval:uptime];
    NSString *prefix = NSLocalizedString(@"System_Uptime_Prefix", nil);
    if ([prefix isEqualToString:@"System_Uptime_Prefix"]) {
        prefix = @"uptime:";
    }
    return [NSString stringWithFormat:@"%@ %@", prefix, duration ?: @""];
}

@end
