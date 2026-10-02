//
//  DONavigationController.h
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import <UIKit/UIKit.h>
#import "UIImage+Blur.h"
#import "DOMainViewController.h"
#import "Transition/DOModalTransitionScale.h"
#import "Transition/DOModalTransitionPush.h"

NS_ASSUME_NONNULL_BEGIN

@interface DONavigationController : UINavigationController <UINavigationControllerDelegate>

// Main-thread, terminal cleanup before this controller's window is replaced
// or disconnected. A retired controller must never restart wallpaper playback.
- (void)customGlassPrepareForWindowReplacement;

@end

NS_ASSUME_NONNULL_END
