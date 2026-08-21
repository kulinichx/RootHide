//
//  DOHeaderView.m
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import "DOHeaderView.h"
#import "DOThemeManager.h"

@interface DOHeaderView ()

@property (nonatomic) UIImageView *logoView;
@property (nonatomic) UILabel *timerLabel;

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
        [NSTimer scheduledTimerWithTimeInterval:60.0 target:self selector:@selector(updateLabel) userInfo:nil repeats:YES];
    }
    return self;
}

- (void)updateLabel {
        self.timerLabel.text = [self formatUptime];
}

- (NSString *)formatUptime {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    NSTimeInterval uptime = ts.tv_sec;

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
