//
//  DOCustomGlassRefractionView.h
//  Dopamine
//
//  Glass V2 physical Liquid Glass surface for Custom Glass.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOCustomGlassRefractionView : UIView

/// Coordinate space used to map this view back onto the shared wallpaper image view.
@property(nonatomic, weak, nullable) UIView *wallpaperSamplingView;

/// Coordinate space of the viewport-sized adaptive wallpaper scrim.
@property(nonatomic, weak, nullable) UIView *wallpaperScrimSamplingView;

/// Rounded-rectangle geometry, in UIKit points.
@property(nonatomic, assign) CGFloat glassCornerRadius;

/// Optical controls layered over the calibrated wallpaper + live scrim backdrop.
@property(nonatomic, assign) CGFloat refractiveRimWidth;
@property(nonatomic, assign) CGFloat refractionAmount;
@property(nonatomic, assign) CGFloat diffusionRadius;
@property(nonatomic, assign) CGFloat specularStrength;
@property(nonatomic, assign) CGFloat darkEdgeStrength;

/// Installs/replaces the exact wallpaper image currently displayed by Navigation.
- (void)setWallpaperImage:(nullable UIImage *)image;

/// Installs the five real CAGradientLayer stop locations and effective black-scrim alphas.
- (void)setWallpaperScrimLocations:(NSArray<NSNumber *> *)locations
                            alphas:(NSArray<NSNumber *> *)alphas;

/// Re-renders using the current texture, sampling spaces, and scrim state.
- (void)refreshRefraction;

@end

NS_ASSUME_NONNULL_END
