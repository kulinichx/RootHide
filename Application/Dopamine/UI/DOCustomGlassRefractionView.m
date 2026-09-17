//
//  DOCustomGlassRefractionView.m
//  Dopamine
//
//  Mango-style physical Liquid Glass surface for Custom Glass.
//
//  Keep the G02.R2A-calibrated wallpaper + live adaptive scrim as the one source
//  of truth. A convex rounded-rect lens bends that same source using Snell-style
//  refraction through a finite glass slab; restrained diffusion, Fresnel/specular
//  response, opposing dark thickness and weak RGB dispersion are layered after it.
//

#import "DOCustomGlassRefractionView.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

static inline float DOCustomGlassRefractionClamp01(CGFloat value)
{
    return (float)MIN(1.0, MAX(0.0, value));
}

static id DOCustomGlassRefractionCreateCAFilter(NSString *type)
{
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL selector = NSSelectorFromString(@"filterWithType:");
    if (!filterClass || ![filterClass respondsToSelector:selector])
        return nil;

    IMP implementation = [filterClass methodForSelector:selector];
    typedef id (*DOCustomGlassRefractionFilterFactoryIMP)(id, SEL, id);
    DOCustomGlassRefractionFilterFactoryIMP factory =
        (DOCustomGlassRefractionFilterFactoryIMP)implementation;
    return factory(filterClass, selector, type);
}

typedef struct {
    vector_float2 viewSize;
    vector_float2 wallpaperOrigin;
    vector_float2 wallpaperViewportSize;
    vector_float2 textureSize;
    vector_float2 scrimOrigin;
    vector_float2 scrimViewportSize;
    vector_float4 scrimLocations;
    vector_float4 scrimAlphas;
    vector_float4 scrimTail; // x = location[4], y = alpha[4]
    float cornerRadius;
    float rimWidth;
    float refractionAmount;
    float diffusionRadius;
    float specularStrength;
    float darkEdgeStrength;
    float padding0;
    float padding1;
} DOCustomGlassRefractionUniforms;

static NSString * const DOCustomGlassRefractionShaderSource =
@"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct VertexOut {\n"
"    float4 position [[position]];\n"
"    float2 uv;\n"
"};\n"
"\n"
"struct Uniforms {\n"
"    float2 viewSize;\n"
"    float2 wallpaperOrigin;\n"
"    float2 wallpaperViewportSize;\n"
"    float2 textureSize;\n"
"    float2 scrimOrigin;\n"
"    float2 scrimViewportSize;\n"
"    float4 scrimLocations;\n"
"    float4 scrimAlphas;\n"
"    float4 scrimTail;\n"
"    float cornerRadius;\n"
"    float rimWidth;\n"
"    float refractionAmount;\n"
"    float diffusionRadius;\n"
"    float specularStrength;\n"
"    float darkEdgeStrength;\n"
"    float padding0;\n"
"    float padding1;\n"
"};\n"
"\n"
"vertex VertexOut glass_vertex(uint vid [[vertex_id]]) {\n"
"    const float2 positions[6] = {\n"
"        float2(-1.0,  1.0), float2(-1.0, -1.0), float2( 1.0,  1.0),\n"
"        float2( 1.0,  1.0), float2(-1.0, -1.0), float2( 1.0, -1.0)\n"
"    };\n"
"    const float2 uvs[6] = {\n"
"        float2(0.0, 0.0), float2(0.0, 1.0), float2(1.0, 0.0),\n"
"        float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0)\n"
"    };\n"
"    VertexOut out;\n"
"    out.position = float4(positions[vid], 0.0, 1.0);\n"
"    out.uv = uvs[vid];\n"
"    return out;\n"
"}\n"
"\n"
"float roundedBoxSDF(float2 point, float2 size, float radius) {\n"
"    float2 p = point - (size * 0.5);\n"
"    float2 q = abs(p) - (size * 0.5 - radius);\n"
"    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;\n"
"}\n"
"\n"
"float2 roundedBoxOutwardNormal(float2 point, float2 size, float radius) {\n"
"    float2 p = point - (size * 0.5);\n"
"    float2 q = abs(p) - (size * 0.5 - radius);\n"
"    float2 outside = max(q, float2(0.0));\n"
"    float2 axisSign = float2(p.x < 0.0 ? -1.0 : 1.0,\n"
"                            p.y < 0.0 ? -1.0 : 1.0);\n"
"    if (dot(outside, outside) > 0.000001) {\n"
"        return normalize(outside) * axisSign;\n"
"    }\n"
"    return (q.x > q.y) ? float2(axisSign.x, 0.0) : float2(0.0, axisSign.y);\n"
"}\n"
"\n"
"float2 refractedSlabOffset(float2 outwardNormal, float slope, float thickness, float ior) {\n"
"    float3 n = normalize(float3(-outwardNormal.x * slope,\n"
"                                -outwardNormal.y * slope,\n"
"                                1.0));\n"
"    float3 ray = refract(float3(0.0, 0.0, -1.0), n, 1.0 / ior);\n"
"    float travel = thickness / max(-ray.z, 0.0001);\n"
"    return ray.xy * travel;\n"
"}\n"
"\n"
"float2 aspectFillUV(float2 viewportPoint, constant Uniforms &u) {\n"
"    float scale = max(u.wallpaperViewportSize.x / max(u.textureSize.x, 1.0),\n"
"                      u.wallpaperViewportSize.y / max(u.textureSize.y, 1.0));\n"
"    float2 displayedSize = u.textureSize * scale;\n"
"    float2 crop = (displayedSize - u.wallpaperViewportSize) * 0.5;\n"
"    float2 imagePoint = (viewportPoint + crop) / max(scale, 0.0001);\n"
"    return clamp(imagePoint / max(u.textureSize, float2(1.0)), float2(0.001), float2(0.999));\n"
"}\n"
"\n"
"float scrimSegment(float y, float l0, float l1, float a0, float a1) {\n"
"    float t = clamp((y - l0) / max(l1 - l0, 0.0001), 0.0, 1.0);\n"
"    return mix(a0, a1, t);\n"
"}\n"
"\n"
"float adaptiveScrimAlpha(float y, constant Uniforms &u) {\n"
"    float4 l = u.scrimLocations;\n"
"    float4 a = u.scrimAlphas;\n"
"    float l4 = u.scrimTail.x;\n"
"    float a4 = u.scrimTail.y;\n"
"    if (y <= l.x) return a.x;\n"
"    if (y <= l.y) return scrimSegment(y, l.x, l.y, a.x, a.y);\n"
"    if (y <= l.z) return scrimSegment(y, l.y, l.z, a.y, a.z);\n"
"    if (y <= l.w) return scrimSegment(y, l.z, l.w, a.z, a.w);\n"
"    if (y <= l4)  return scrimSegment(y, l.w, l4, a.w, a4);\n"
"    return a4;\n"
"}\n"
"\n"
"fragment float4 glass_fragment(VertexOut in [[stage_in]],\n"
"                               texture2d<float> wallpaper [[texture(0)]],\n"
"                               constant Uniforms &u [[buffer(0)]]) {\n"
"    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);\n"
"\n"
"    float2 localPoint = in.uv * u.viewSize;\n"
"    float radius = min(u.cornerRadius, 0.5 * min(u.viewSize.x, u.viewSize.y));\n"
"    float d = roundedBoxSDF(localPoint, u.viewSize, radius);\n"
"    float mask = 1.0 - smoothstep(-0.55, 0.55, d);\n"
"    if (mask <= 0.001) {\n"
"        discard_fragment();\n"
"    }\n"
"\n"
"    // Apple-style lens mapping: the whole capsule gets slight backdrop magnification,\n"
"    // while a broad edge band adds visible Snell-style wrap.\n"
"    const float baseIOR = 1.46;\n"
"    const float opticalDepth = 4.5;\n"
"    const float backdropZoom = 1.035;\n"
"    const float dispersionDelta = 0.008;\n"
"    float insideDepth = max(-d, 0.0);\n"
"    float rimWidth = max(u.rimWidth, 0.001);\n"
"    float rimT = clamp(insideDepth / rimWidth, 0.0, 1.0);\n"
"    float rimWeight = 1.0 - smoothstep(0.0, 1.0, rimT);\n"
"    float2 outwardNormal = roundedBoxOutwardNormal(localPoint, u.viewSize, radius);\n"
"    float2 center = u.viewSize * 0.5;\n"
"    float2 bodyPoint = center + (localPoint - center) / backdropZoom;\n"
"    float profileSlope = 1.80 * pow(max(rimWeight, 0.0), 1.30);\n"
"\n"
"    float2 offsetG = float2(0.0);\n"
"    float2 offsetR = float2(0.0);\n"
"    float2 offsetB = float2(0.0);\n"
"    if (insideDepth < rimWidth && u.refractionAmount > 0.0001) {\n"
"        offsetG = refractedSlabOffset(outwardNormal, profileSlope, opticalDepth, baseIOR) *\n"
"                  u.refractionAmount;\n"
"        offsetR = refractedSlabOffset(outwardNormal, profileSlope, opticalDepth,\n"
"                                      baseIOR - dispersionDelta) * u.refractionAmount;\n"
"        offsetB = refractedSlabOffset(outwardNormal, profileSlope, opticalDepth,\n"
"                                      baseIOR + dispersionDelta) * u.refractionAmount;\n"
"        float2 wrap = outwardNormal *\n"
"                      (1.60 * u.refractionAmount * pow(max(rimWeight, 0.0), 1.40));\n"
"        offsetG += wrap;\n"
"        offsetR += wrap;\n"
"        offsetB += wrap;\n"
"    }\n"
"\n"
"    float2 sourcePoint = bodyPoint + offsetG;\n"
"    float2 sourcePointR = bodyPoint + offsetR;\n"
"    float2 sourcePointB = bodyPoint + offsetB;\n"
"    float2 uvR = aspectFillUV(u.wallpaperOrigin + sourcePointR, u);\n"
"    float2 uvG = aspectFillUV(u.wallpaperOrigin + sourcePoint, u);\n"
"    float2 uvB = aspectFillUV(u.wallpaperOrigin + sourcePointB, u);\n"
"    float3 color = float3(wallpaper.sample(linearSampler, uvR).r,\n"
"                          wallpaper.sample(linearSampler, uvG).g,\n"
"                          wallpaper.sample(linearSampler, uvB).b);\n"
"\n"
"    // Restrained diffusion belongs to the refractive rim, not the center.\n"
"    float blurRadius = u.diffusionRadius * rimWeight;\n"
"    if (blurRadius > 0.001) {\n"
"        float2 dx = float2(blurRadius, 0.0);\n"
"        float2 dy = float2(0.0, blurRadius);\n"
"        float3 crossColor =\n"
"            wallpaper.sample(linearSampler, aspectFillUV(u.wallpaperOrigin + sourcePoint + dx, u)).rgb +\n"
"            wallpaper.sample(linearSampler, aspectFillUV(u.wallpaperOrigin + sourcePoint - dx, u)).rgb +\n"
"            wallpaper.sample(linearSampler, aspectFillUV(u.wallpaperOrigin + sourcePoint + dy, u)).rgb +\n"
"            wallpaper.sample(linearSampler, aspectFillUV(u.wallpaperOrigin + sourcePoint - dy, u)).rgb;\n"
"        color = mix(color, crossColor * 0.25, 0.28 * rimWeight);\n"
"    }\n"
"\n"
"    // The adaptive black scrim follows the exact same refracted green/reference ray.\n"
"    float2 scrimPoint = u.scrimOrigin + sourcePoint;\n"
"    float scrimY = clamp(scrimPoint.y / max(u.scrimViewportSize.y, 1.0), 0.0, 1.0);\n"
"    float scrimAlpha = clamp(adaptiveScrimAlpha(scrimY, u), 0.0, 1.0);\n"
"    color *= (1.0 - scrimAlpha);\n"
"\n"
"    // Fresnel + directional edge response. This is reflection structure, not a border.\n"
"    float3 surfaceNormal = normalize(float3(-outwardNormal.x * profileSlope,\n"
"                                            -outwardNormal.y * profileSlope,\n"
"                                            1.0));\n"
"    float f0 = pow((baseIOR - 1.0) / (baseIOR + 1.0), 2.0);\n"
"    float fresnel = f0 + (1.0 - f0) * pow(1.0 - clamp(surfaceNormal.z, 0.0, 1.0), 5.0);\n"
"    float3 viewDir = float3(0.0, 0.0, 1.0);\n"
"    float3 lightDir = normalize(float3(-0.58, -0.72, 0.38));\n"
"    float3 halfDir = normalize(viewDir + lightDir);\n"
"    float directionalSpec = pow(max(dot(surfaceNormal, halfDir), 0.0), 28.0);\n"
"    float edgeCore = exp(-pow(insideDepth / 0.90, 2.0));\n"
"    float edgeBody = exp(-pow(insideDepth / 3.40, 2.0));\n"
"    float specular = u.specularStrength * rimWeight *\n"
"                     (0.55 * directionalSpec + 0.45 * fresnel) *\n"
"                     (0.42 + 0.58 * edgeBody);\n"
"    float2 lightXY = normalize(lightDir.xy);\n"
"    float opposing = max(dot(outwardNormal, -lightXY), 0.0);\n"
"    float darkThickness = u.darkEdgeStrength * rimWeight * edgeBody *\n"
"                          (0.18 + 0.82 * opposing);\n"
"    float farGlint = u.specularStrength * 0.18 * edgeCore * opposing;\n"
"    color *= (1.0 - darkThickness);\n"
"    color += float3(specular + farGlint);\n"
"    color = clamp(color, float3(0.0), float3(1.0));\n"
"\n"
"    // Premultiplied full replacement preserves the calibrated transmission while\n"
"    // the optical signature comes from refraction and reflection at the rim.\n"
"    return float4(color * mask, mask);\n"
"}\n";

@interface DOCustomGlassRefractionView ()
{
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLTexture> _wallpaperTexture;
    UIImage *_wallpaperImage;
    NSString *_routeB0GroupName;
    float _scrimLocations[5];
    float _scrimAlphas[5];
}
- (BOOL)routeB0UsesBackdropLayer;
- (void)configureRouteB0Backdrop;
@end

@implementation DOCustomGlassRefractionView

+ (Class)layerClass
{
    // Route B0: prefer the compositor-backed source Mango relies on.
    // If CABackdropLayer is unavailable, preserve the existing Metal fallback.
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass ?: [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (BOOL)routeB0UsesBackdropLayer
{
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass && [self.layer isKindOfClass:backdropClass];
}

- (void)configureRouteB0Backdrop
{
    if (![self routeB0UsesBackdropLayer])
        return;

    CALayer *backdropLayer = self.layer;

    if ([backdropLayer respondsToSelector:NSSelectorFromString(@"setLayerUsesCoreImageFilters:")])
        [backdropLayer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
    if ([backdropLayer respondsToSelector:NSSelectorFromString(@"setWindowServerAware:")])
        [backdropLayer setValue:@YES forKey:@"windowServerAware"];
    if ([backdropLayer respondsToSelector:NSSelectorFromString(@"setGroupName:")])
        [backdropLayer setValue:_routeB0GroupName forKey:@"groupName"];
    if ([backdropLayer respondsToSelector:NSSelectorFromString(@"setAllowsInPlaceFiltering:")])
        [backdropLayer setValue:@YES forKey:@"allowsInPlaceFiltering"];
    if ([backdropLayer respondsToSelector:NSSelectorFromString(@"setScale:")])
        [backdropLayer setValue:@1.0 forKey:@"scale"];

    id blur = DOCustomGlassRefractionCreateCAFilter(@"gaussianBlur");
    if (blur) {
        [blur setValue:@12.0 forKey:@"inputRadius"];
        [blur setValue:@YES forKey:@"inputNormalizeEdges"];
        [blur setValue:@YES forKey:@"inputHardEdges"];
        [backdropLayer setValue:@[blur] forKey:@"filters"];
    }
    else {
        [backdropLayer setValue:@[] forKey:@"filters"];
    }

    self.clipsToBounds = YES;
    backdropLayer.masksToBounds = YES;
    backdropLayer.cornerRadius = self.glassCornerRadius;
    backdropLayer.cornerCurve = kCACornerCurveContinuous;
    [backdropLayer setNeedsDisplay];
}

- (void)commonInit
{
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.userInteractionEnabled = NO;

    _glassCornerRadius = 14.0;
    _refractiveRimWidth = 12.0;
    _refractionAmount = 0.0;
    _diffusionRadius = 0.0;
    _specularStrength = 0.0;
    _darkEdgeStrength = 0.0;

    const float defaultLocations[5] = {0.0f, 0.22f, 0.48f, 0.74f, 1.0f};
    for (NSUInteger index = 0; index < 5; index++) {
        _scrimLocations[index] = defaultLocations[index];
        _scrimAlphas[index] = 0.0f;
    }

    _routeB0GroupName =
        [NSString stringWithFormat:@"com.roothide.dopamine.customglass.route-b0.%p", self];

    if ([self routeB0UsesBackdropLayer]) {
        [self configureRouteB0Backdrop];
        NSLog(@"[CustomGlass][RouteB0] live CABackdropLayer active (%@)", _routeB0GroupName);
        return;
    }

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        self.hidden = YES;
        return;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    metalLayer.device = _device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    metalLayer.framebufferOnly = YES;
    metalLayer.opaque = NO;
    metalLayer.contentsScale = UIScreen.mainScreen.scale;

    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (sRGB) {
        metalLayer.colorspace = sRGB;
        CGColorSpaceRelease(sRGB);
    }

    _commandQueue = [_device newCommandQueue];

    NSError *libraryError = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:DOCustomGlassRefractionShaderSource
                                                   options:nil
                                                     error:&libraryError];
    if (!library) {
        NSLog(@"[CustomGlass][Identity] Metal shader compile failed: %@", libraryError);
        self.hidden = YES;
        return;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"glass_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"glass_fragment"];
    if (!vertexFunction || !fragmentFunction) {
        NSLog(@"[CustomGlass][Identity] Metal shader functions are unavailable");
        self.hidden = YES;
        return;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat;

    MTLRenderPipelineColorAttachmentDescriptor *attachment = descriptor.colorAttachments[0];
    attachment.blendingEnabled = YES;
    attachment.rgbBlendOperation = MTLBlendOperationAdd;
    attachment.alphaBlendOperation = MTLBlendOperationAdd;
    attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
    attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
    attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    NSError *pipelineError = nil;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (!_pipelineState) {
        NSLog(@"[CustomGlass][Identity] Metal pipeline creation failed: %@", pipelineError);
        self.hidden = YES;
    }
}

static UIImage *DOCustomGlassRefractionNormalizedImage(UIImage *image)
{
    if (!image)
        return nil;

    // Preserve source resolution for the identity gate. Only normalize orientation.
    if (image.imageOrientation == UIImageOrientationUp)
        return image;

    CGSize orientedSize = image.size;
    if (orientedSize.width < 1.0 || orientedSize.height < 1.0)
        return image;

    UIGraphicsBeginImageContextWithOptions(orientedSize, YES, image.scale);
    [image drawInRect:(CGRect){CGPointZero, orientedSize}];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

- (void)setWallpaperImage:(UIImage *)image
{
    if (_wallpaperImage == image && _wallpaperTexture) {
        [self refreshRefraction];
        return;
    }

    _wallpaperImage = image;
    _wallpaperTexture = nil;

    if (!image || !_device || !_pipelineState) {
        [self refreshRefraction];
        return;
    }

    UIImage *normalized = DOCustomGlassRefractionNormalizedImage(image);
    CGImageRef cgImage = normalized.CGImage;
    if (!cgImage)
        return;

    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:_device];
    NSDictionary *options = @{
        MTKTextureLoaderOptionSRGB : @YES,
        MTKTextureLoaderOptionOrigin : MTKTextureLoaderOriginTopLeft,
        MTKTextureLoaderOptionTextureUsage : @(MTLTextureUsageShaderRead),
    };

    NSError *error = nil;
    _wallpaperTexture = [loader newTextureWithCGImage:cgImage options:options error:&error];
    if (!_wallpaperTexture) {
        NSLog(@"[CustomGlass][Identity] Wallpaper texture upload failed: %@", error);
        return;
    }

    self.hidden = NO;
    [self refreshRefraction];
}

- (void)setWallpaperScrimLocations:(NSArray<NSNumber *> *)locations
                            alphas:(NSArray<NSNumber *> *)alphas
{
    static const float fallbackLocations[5] = {0.0f, 0.22f, 0.48f, 0.74f, 1.0f};

    for (NSUInteger index = 0; index < 5; index++) {
        float location = (locations.count > index)
            ? DOCustomGlassRefractionClamp01(locations[index].doubleValue)
            : fallbackLocations[index];
        if (index > 0)
            location = MAX(location, _scrimLocations[index - 1]);

        float alpha = (alphas.count > index)
            ? DOCustomGlassRefractionClamp01(alphas[index].doubleValue)
            : 0.0f;

        _scrimLocations[index] = location;
        _scrimAlphas[index] = alpha;
    }

    [self refreshRefraction];
}

- (void)setGlassCornerRadius:(CGFloat)glassCornerRadius
{
    _glassCornerRadius = MAX(0.0, glassCornerRadius);
    [self refreshRefraction];
}

- (void)setRefractiveRimWidth:(CGFloat)refractiveRimWidth
{
    _refractiveRimWidth = MAX(0.0, refractiveRimWidth);
    [self refreshRefraction];
}

- (void)setRefractionAmount:(CGFloat)refractionAmount
{
    _refractionAmount = MAX(0.0, MIN(3.0, refractionAmount));
    [self refreshRefraction];
}

- (void)setDiffusionRadius:(CGFloat)diffusionRadius
{
    _diffusionRadius = MAX(0.0, MIN(3.0, diffusionRadius));
    [self refreshRefraction];
}

- (void)setSpecularStrength:(CGFloat)specularStrength
{
    _specularStrength = MAX(0.0, MIN(0.50, specularStrength));
    [self refreshRefraction];
}

- (void)setDarkEdgeStrength:(CGFloat)darkEdgeStrength
{
    _darkEdgeStrength = MAX(0.0, MIN(0.40, darkEdgeStrength));
    [self refreshRefraction];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self refreshRefraction];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    if ([self routeB0UsesBackdropLayer]) {
        self.layer.cornerRadius = self.glassCornerRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        return;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    metalLayer.contentsScale = scale;
    metalLayer.drawableSize = CGSizeMake(MAX(1.0, CGRectGetWidth(self.bounds) * scale),
                                         MAX(1.0, CGRectGetHeight(self.bounds) * scale));

    [self refreshRefraction];
}

- (void)refreshRefraction
{
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refreshRefraction];
        });
        return;
    }

    if ([self routeB0UsesBackdropLayer]) {
        if (self.window && !CGRectIsEmpty(self.bounds))
            [self configureRouteB0Backdrop];
        return;
    }

    if (!_device || !_commandQueue || !_pipelineState || !_wallpaperTexture ||
        !self.window || CGRectIsEmpty(self.bounds))
        return;

    UIView *wallpaperView = self.wallpaperSamplingView;
    if (!wallpaperView || CGRectIsEmpty(wallpaperView.bounds))
        return;

    CGRect wallpaperRect = [self convertRect:self.bounds toView:wallpaperView];

    UIView *scrimView = self.wallpaperScrimSamplingView;
    CGRect scrimRect = CGRectZero;
    CGSize scrimViewportSize = self.bounds.size;
    if (scrimView && !CGRectIsEmpty(scrimView.bounds)) {
        scrimRect = [self convertRect:self.bounds toView:scrimView];
        scrimViewportSize = scrimView.bounds.size;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (!drawable)
        return;

    DOCustomGlassRefractionUniforms uniforms = {
        .viewSize = {(float)CGRectGetWidth(self.bounds), (float)CGRectGetHeight(self.bounds)},
        .wallpaperOrigin = {(float)CGRectGetMinX(wallpaperRect), (float)CGRectGetMinY(wallpaperRect)},
        .wallpaperViewportSize = {(float)CGRectGetWidth(wallpaperView.bounds), (float)CGRectGetHeight(wallpaperView.bounds)},
        .textureSize = {(float)_wallpaperTexture.width, (float)_wallpaperTexture.height},
        .scrimOrigin = {(float)CGRectGetMinX(scrimRect), (float)CGRectGetMinY(scrimRect)},
        .scrimViewportSize = {(float)MAX(scrimViewportSize.width, 1.0), (float)MAX(scrimViewportSize.height, 1.0)},
        .scrimLocations = {_scrimLocations[0], _scrimLocations[1], _scrimLocations[2], _scrimLocations[3]},
        .scrimAlphas = {_scrimAlphas[0], _scrimAlphas[1], _scrimAlphas[2], _scrimAlphas[3]},
        .scrimTail = {_scrimLocations[4], _scrimAlphas[4], 0.0f, 0.0f},
        .cornerRadius = (float)self.glassCornerRadius,
        .rimWidth = (float)self.refractiveRimWidth,
        .refractionAmount = (float)self.refractionAmount,
        .diffusionRadius = (float)self.diffusionRadius,
        .specularStrength = (float)self.specularStrength,
        .darkEdgeStrength = (float)self.darkEdgeStrength,
        .padding0 = 0.0f,
        .padding1 = 0.0f,
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipelineState];
    [encoder setFragmentTexture:_wallpaperTexture atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
