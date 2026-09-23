//
//  SceneDelegate.m
//  Dopamine
//
//  Created by Lars Fröder on 23.09.23.
//

#import "DOSceneDelegate.h"
#import "DONavigationController.h"

@interface DOSceneDelegate ()

@end

@implementation DOSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [[DONavigationController alloc] init];
    self.window = window;
    [window makeKeyAndVisible];
}

+ (void)relaunch
{
    UIWindowScene *windowScene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
    DOSceneDelegate *instance = (DOSceneDelegate *)windowScene.delegate;
    UIWindow *oldWindow = instance.window;
    if (!oldWindow)
        return;

    [UIView animateWithDuration:0.3 animations:^{
        oldWindow.alpha = 0;
    } completion:^(BOOL finished) {
        // Ignore a stale completion after another relaunch or scene disconnect.
        if (instance.window != oldWindow)
            return;

        if ([oldWindow.rootViewController isKindOfClass:DONavigationController.class]) {
            [(DONavigationController *)oldWindow.rootViewController customGlassPrepareForWindowReplacement];
        }

        UIWindow *window = [[UIWindow alloc] initWithWindowScene:windowScene];
        window.rootViewController = [[DONavigationController alloc] init];
        window.alpha = 0;
        instance.window = window;
        [window makeKeyAndVisible];

        oldWindow.hidden = YES;
        oldWindow.rootViewController = nil;

        [UIView animateWithDuration:0.3 animations:^{
            window.alpha = 1;
        }];
    }];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    UIWindow *window = self.window;
    if (window.windowScene != scene)
        return;

    if ([window.rootViewController isKindOfClass:DONavigationController.class]) {
        [(DONavigationController *)window.rootViewController customGlassPrepareForWindowReplacement];
    }
    window.hidden = YES;
    window.rootViewController = nil;
    self.window = nil;
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
}


@end
