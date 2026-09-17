//
//  DOCustomGlassRefractionView.h
//  Dopamine
//
//  Experimental iOS 16 edge-refraction prototype for Custom Glass.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOCustomGlassRefractionView : UIView

/// Coordinate space used to map this view back onto the shared wallpaper image view.
@property(nonatomic, weak, nullable) UIView *wallpaperSamplingView;

/// Rounded-rectangle optical geometry, in UIKit points.
@property(nonatomic, assign) CGFloat glassCornerRadius;
@property(nonatomic, assign) CGFloat refractiveRimWidth;
@property(nonatomic, assign) CGFloat refractionAmount;
@property(nonatomic, assign) CGFloat diffusionRadius;

/// Edge-lighting response. These do not tint the center of the glass.
@property(nonatomic, assign) CGFloat specularStrength;
@property(nonatomic, assign) CGFloat darkEdgeStrength;

/// Installs/replaces the wallpaper texture. Passing nil clears the optical surface.
- (void)setWallpaperImage:(nullable UIImage *)image;

/// Re-renders using the current texture and geometry.
- (void)refreshRefraction;

@end

NS_ASSUME_NONNULL_END
