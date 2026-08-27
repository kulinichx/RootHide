//
//  DONavigationController.m
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import "DONavigationController.h"
#import <objc/runtime.h>
#import "DOModalBackAction.h"
#import "DOGlobalAppearance.h"
#import "DOThemeManager.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString * const DOCustomGlassNavigationBackgroundBlurKey = @"DOCustomGlassTheme.BackgroundBlur";
static NSString * const DOCustomGlassNavigationDidChangeNotification = @"DOCustomGlassTheme.DidChange";

static NSString *DOCustomGlassNavigationBackgroundFilePath(void)
{
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (applicationSupport.length == 0)
        return nil;
    return [[applicationSupport stringByAppendingPathComponent:@"CustomGlass"]
        stringByAppendingPathComponent:@"background.jpg"];
}

static inline CGFloat DOCustomGlassNavigationClamp01(CGFloat value)
{
    return MIN(1.0, MAX(0.0, value));
}

static CGFloat DOCustomGlassNavigationPerceivedLuminance(CGFloat red, CGFloat green, CGFloat blue)
{
    return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue);
}

@interface DOCustomWallpaperBlurView : UIView
- (void)setBlurIntensity:(CGFloat)blurIntensity;
@end

@interface DONavigationController ()

@property (nonatomic) UIImageView *backgroundImageView;
@property (nonatomic) UIView *customGlassBackgroundHostView;
@property (nonatomic) UIImageView *customGlassBackgroundImageView;
@property (nonatomic) DOCustomWallpaperBlurView *customGlassBackgroundBlurView;
@property (nonatomic) DOMainViewController *mainView;
@property (nonatomic) DOModalBackAction *backAction;

@end

@interface UINavigationController (Private)
-(CGRect)_frameForViewController:(id)arg1;
@end

@implementation DONavigationController

- (BOOL)isCustomGlassFullScreenViewController:(UIViewController *)viewController
{
    return [NSStringFromClass(viewController.class) hasPrefix:@"DOCustomGlass"];
}

- (void)viewDidLoad
{
    [self setupBackground];
    [super viewDidLoad];
    [self setNavigationBarHidden:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(customGlassThemeDidChange:)
                                                 name:DOCustomGlassNavigationDidChangeNotification
                                               object:nil];
    [self customGlassRefreshSharedBackground];

    [self pushViewController:(self.mainView = [[DOMainViewController alloc] init]) animated:NO];
    [self setDelegate:self];
    [self setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
}

- (void)setupBackground
{
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    
    self.view.backgroundColor = [UIColor blackColor];
    self.backgroundImageView = [[UIImageView alloc] init];
    self.backgroundImageView.image = [theme image];
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundImageView.userInteractionEnabled = NO;
    self.backgroundImageView.layer.zPosition = -1;

    [self.view insertSubview:self.backgroundImageView atIndex:0];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:-100],
        [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:100],
    ]];

    // Custom Glass owns one persistent wallpaper layer at the navigation level.
    // Every pushed controller stays transparent above this layer, so scale/push
    // transitions can never expose the Dopamine theme for a single edge frame.
    self.customGlassBackgroundHostView = [[UIView alloc] init];
    self.customGlassBackgroundHostView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassBackgroundHostView.backgroundColor = UIColor.clearColor;
    self.customGlassBackgroundHostView.userInteractionEnabled = NO;
    self.customGlassBackgroundHostView.hidden = YES;
    self.customGlassBackgroundHostView.layer.zPosition = -0.5;
    [self.view insertSubview:self.customGlassBackgroundHostView aboveSubview:self.backgroundImageView];

    self.customGlassBackgroundImageView = [[UIImageView alloc] init];
    self.customGlassBackgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassBackgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.customGlassBackgroundImageView.clipsToBounds = YES;
    self.customGlassBackgroundImageView.userInteractionEnabled = NO;
    [self.customGlassBackgroundHostView addSubview:self.customGlassBackgroundImageView];

    self.customGlassBackgroundBlurView = [[DOCustomWallpaperBlurView alloc] initWithFrame:CGRectZero];
    self.customGlassBackgroundBlurView.translatesAutoresizingMaskIntoConstraints = NO;
    self.customGlassBackgroundBlurView.userInteractionEnabled = NO;
    [self.customGlassBackgroundHostView addSubview:self.customGlassBackgroundBlurView];

    // Deliberately overscan the shared wallpaper. The custom modal-scale
    // transition briefly reveals area outside a controller's transformed frame;
    // overscan guarantees that area is still the same Custom Glass wallpaper.
    [NSLayoutConstraint activateConstraints:@[
        [self.customGlassBackgroundHostView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:-48.0],
        [self.customGlassBackgroundHostView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:48.0],
        [self.customGlassBackgroundHostView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:-140.0],
        [self.customGlassBackgroundHostView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:140.0],
        [self.customGlassBackgroundImageView.leadingAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.leadingAnchor],
        [self.customGlassBackgroundImageView.trailingAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.trailingAnchor],
        [self.customGlassBackgroundImageView.topAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.topAnchor],
        [self.customGlassBackgroundImageView.bottomAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.bottomAnchor],
        [self.customGlassBackgroundBlurView.leadingAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.leadingAnchor],
        [self.customGlassBackgroundBlurView.trailingAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.trailingAnchor],
        [self.customGlassBackgroundBlurView.topAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.topAnchor],
        [self.customGlassBackgroundBlurView.bottomAnchor constraintEqualToAnchor:self.customGlassBackgroundHostView.bottomAnchor]
    ]];

    self.backAction = [[DOModalBackAction alloc] initWithAction:^{
        [self popViewControllerAnimated:YES];
    }];
    self.backAction.translatesAutoresizingMaskIntoConstraints = NO;
    self.backAction.hidden = YES;
    
    [self.view insertSubview:self.backAction atIndex:2];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.backAction.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backAction.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backAction.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backAction.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
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

    [self customGlassRefreshSharedBackground];
}

- (void)customGlassApplySharedBackgroundBlurIntensity:(CGFloat)blurIntensity
{
    [self.customGlassBackgroundBlurView setBlurIntensity:DOCustomGlassNavigationClamp01(blurIntensity)];
    [self.customGlassBackgroundBlurView.layer setNeedsDisplay];
    [self.customGlassBackgroundBlurView setNeedsLayout];
}

- (void)customGlassRefreshSharedBackground
{
    NSString *path = DOCustomGlassNavigationBackgroundFilePath();
    UIImage *image = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat blur = [defaults objectForKey:DOCustomGlassNavigationBackgroundBlurKey] ?
        [defaults floatForKey:DOCustomGlassNavigationBackgroundBlurKey] : 0.10;

    [UIView performWithoutAnimation:^{
        self.customGlassBackgroundImageView.image = image;
        self.customGlassBackgroundHostView.hidden = image == nil;
        [self customGlassApplySharedBackgroundBlurIntensity:blur];
        [self.customGlassBackgroundHostView setNeedsLayout];
        [self.customGlassBackgroundHostView layoutIfNeeded];
    }];
}

- (BOOL)customGlassHasSharedBackground
{
    return !self.customGlassBackgroundHostView.hidden && self.customGlassBackgroundImageView.image != nil;
}

- (CGFloat)customGlassLuminanceForView:(UIView *)view
{
    if (!view)
        return 0.28;

    UIImageView *imageView = [self customGlassHasSharedBackground] ?
        self.customGlassBackgroundImageView : self.backgroundImageView;
    UIImage *image = imageView.image;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage || CGRectIsEmpty(imageView.bounds))
        return 0.28;

    CGPoint centerInImageView = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                            toView:imageView];
    CGSize imagePointSize = image.size;
    if (imagePointSize.width <= 0.0 || imagePointSize.height <= 0.0)
        return 0.28;

    CGFloat scale = MAX(CGRectGetWidth(imageView.bounds) / imagePointSize.width,
                        CGRectGetHeight(imageView.bounds) / imagePointSize.height);
    CGFloat renderedWidth = imagePointSize.width * scale;
    CGFloat renderedHeight = imagePointSize.height * scale;
    CGFloat offsetX = (CGRectGetWidth(imageView.bounds) - renderedWidth) * 0.5;
    CGFloat offsetY = (CGRectGetHeight(imageView.bounds) - renderedHeight) * 0.5;
    CGFloat normalizedX = (centerInImageView.x - offsetX) / MAX(renderedWidth, 1.0);
    CGFloat normalizedY = (centerInImageView.y - offsetY) / MAX(renderedHeight, 1.0);
    normalizedX = DOCustomGlassNavigationClamp01(normalizedX);
    normalizedY = DOCustomGlassNavigationClamp01(normalizedY);

    size_t pixelWidth = CGImageGetWidth(cgImage);
    size_t pixelHeight = CGImageGetHeight(cgImage);
    CGFloat sampleWidth = MAX(8.0, pixelWidth * 0.12);
    CGFloat sampleHeight = MAX(8.0, pixelHeight * 0.10);
    CGFloat centerX = normalizedX * pixelWidth;
    CGFloat centerY = normalizedY * pixelHeight;
    CGRect cropRect = CGRectMake(centerX - sampleWidth * 0.5,
                                 centerY - sampleHeight * 0.5,
                                 sampleWidth, sampleHeight);
    cropRect = CGRectIntersection(cropRect, CGRectMake(0.0, 0.0, pixelWidth, pixelHeight));
    if (CGRectIsEmpty(cropRect))
        return 0.28;

    CGImageRef crop = CGImageCreateWithImageInRect(cgImage, cropRect);
    if (!crop)
        return 0.28;

    unsigned char pixel[4] = {0, 0, 0, 255};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0.0, 0.0, 1.0, 1.0), crop);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(crop);

    CGFloat red = pixel[0] / 255.0;
    CGFloat green = pixel[1] / 255.0;
    CGFloat blue = pixel[2] / 255.0;
    CGFloat luminance = DOCustomGlassNavigationPerceivedLuminance(red, green, blue);
    if (imageView == self.backgroundImageView)
        luminance *= imageView.alpha;
    return luminance;
}

- (BOOL)customGlassPrefersDarkForegroundForView:(UIView *)view
{
    static char DOCustomGlassForegroundAssociationKey;
    CGFloat luminance = [self customGlassLuminanceForView:view];
    NSNumber *previous = objc_getAssociatedObject(view, &DOCustomGlassForegroundAssociationKey);

    BOOL useDarkForeground;
    if (luminance >= 0.68)
        useDarkForeground = YES;
    else if (luminance <= 0.46)
        useDarkForeground = NO;
    else if (previous)
        useDarkForeground = previous.boolValue;
    else
        useDarkForeground = luminance > 0.57;

    objc_setAssociatedObject(view, &DOCustomGlassForegroundAssociationKey,
                             @(useDarkForeground), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return useDarkForeground;
}

- (void)setBackgroundDimmed:(BOOL)dimmed
{
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundImageView.alpha = dimmed ? 0.4 : 1;
    }];
    self.backgroundImageView.userInteractionEnabled = dimmed;
    self.backAction.hidden = !dimmed;
}

#pragma mark - Delegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController
           animationControllerForOperation:(UINavigationControllerOperation)operation
                        fromViewController:(UIViewController *)fromVC
                          toViewController:(UIViewController *)toVC {

    // Make the persistent wallpaper current before the transition snapshot is
    // captured. This is the last synchronous gate before any animated push/pop.
    [self customGlassRefreshSharedBackground];

    if (fromVC.class == DOMainViewController.class || toVC.class == DOMainViewController.class)
        return [[DOModalTransitionScale alloc] initForwards: operation == UINavigationControllerOperationPush];
    return [[DOModalTransitionPush alloc] initForwards: operation == UINavigationControllerOperationPush];
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    [self customGlassRefreshSharedBackground];
    BOOL isMainView = [viewController isKindOfClass:[DOMainViewController class]];
    BOOL isCustomGlassView = [self isCustomGlassFullScreenViewController:viewController];
    [self setBackgroundDimmed:!(isMainView || isCustomGlassView)];
    [self.backAction setIgnoreFrame:[self _frameForViewController:viewController]];
}

#pragma mark - Overrides

-(CGRect)_frameForViewController:(id)viewController
{
    CGRect orig = [super _frameForViewController: viewController];
    if ([[viewController class] isEqual:[DOMainViewController class]] ||
        [self isCustomGlassFullScreenViewController:viewController])
        return orig;
    
    orig.size.width = fmin(orig.size.width - UI_MODAL_PADDING * 2, UI_IPAD_MAX_WIDTH);
    orig.size.height *= [DOGlobalAppearance isSmallDevice] ? 0.8 : 0.7;
    orig.origin.x = (self.view.frame.size.width - orig.size.width) / 2;
    orig.origin.y = (self.view.frame.size.height - orig.size.height) / 2;

    return orig;

}


- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DOCustomGlassNavigationDidChangeNotification
                                                  object:nil];
}


@end
