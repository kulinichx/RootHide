//
//  DOHeaderView.h
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOHeaderView : UIView

// The owning controller enables updates only while its page is visible.
@property (nonatomic, assign) BOOL uptimeUpdatesEnabled;

-(id)initWithImage:(UIImage *)image subtitles:(NSArray<NSAttributedString *> *)subtitles;

@end

NS_ASSUME_NONNULL_END
