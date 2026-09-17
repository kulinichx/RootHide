//
//  DOCustomGlassRefractionView.m
//  Dopamine
//
//  Experimental iOS 16 edge-refraction prototype for Custom Glass.
//
//  This intentionally does not emulate Liquid Glass with another opaque tint layer.
//  It re-samples the already-displayed wallpaper through a shallow rounded-rect lens,
//  adds a narrow directional specular and a weak opposing dark edge, and leaves the
//  center transparent so the real composed wallpaper remains untouched. The shader is compiled at runtime so the prototype does
//  not depend on a separate metallib build step.
//

#import "DOCustomGlassRefractionView.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

typedef struct {
    vector_float2 viewSize;
    vector_float2 viewOrigin;
    vector_float2 viewportSize;
    vector_float2 textureSize;
    float cornerRadius;
    float rimWidth;
    float refractionAmount;
    float diffusionRadius;
    float specularStrength;
    float darkEdgeStrength;
    float screenScale;
    float padding;
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
"    float2 viewOrigin;\n"
"    float2 viewportSize;\n"
"    float2 textureSize;\n"
"    float cornerRadius;\n"
"    float rimWidth;\n"
"    float refractionAmount;\n"
"    float diffusionRadius;\n"
"    float specularStrength;\n"
"    float darkEdgeStrength;\n"
"    float screenScale;\n"
"    float padding;\n"
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
"float2 aspectFillUV(float2 viewportPoint, constant Uniforms &u) {\n"
"    float scale = max(u.viewportSize.x / max(u.textureSize.x, 1.0),\n"
"                      u.viewportSize.y / max(u.textureSize.y, 1.0));\n"
"    float2 displayedSize = u.textureSize * scale;\n"
"    float2 crop = (displayedSize - u.viewportSize) * 0.5;\n"
"    float2 imagePoint = (viewportPoint + crop) / max(scale, 0.0001);\n"
"    return clamp(imagePoint / max(u.textureSize, float2(1.0)), float2(0.001), float2(0.999));\n"
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
"    float insideDistance = max(-d, 0.0);\n"
"    float rimWidth = max(u.rimWidth, 1.0);\n"
"    float rimT = clamp(insideDistance / rimWidth, 0.0, 1.0);\n"
"\n"
"    // Zero displacement exactly at the boundary and at the inner end of the bevel;\n"
"    // peak displacement occurs in the middle of the rim. This avoids a hard seam.\n"
"    float lensProfile = sin(rimT * 3.14159265);\n"
"    lensProfile *= 1.0 - smoothstep(0.96, 1.0, rimT);\n"
"\n"
"    // Numerical SDF gradient gives the local rounded-rect surface normal.\n"
"    const float eps = 0.65;\n"
"    float dx = roundedBoxSDF(localPoint + float2(eps, 0.0), u.viewSize, radius) -\n"
"               roundedBoxSDF(localPoint - float2(eps, 0.0), u.viewSize, radius);\n"
"    float dy = roundedBoxSDF(localPoint + float2(0.0, eps), u.viewSize, radius) -\n"
"               roundedBoxSDF(localPoint - float2(0.0, eps), u.viewSize, radius);\n"
"    float2 normal = normalize(float2(dx, dy) + float2(0.00001));\n"
"\n"
"    float2 viewportPoint = u.viewOrigin + localPoint;\n"
"    float2 refractedPoint = viewportPoint - (normal * (u.refractionAmount * lensProfile));\n"
"\n"
"    // Very small five-tap diffusion. The center remains readable; diffusion becomes\n"
"    // slightly stronger inside the refractive rim instead of turning into frosted blur.\n"
"    float diffusion = max(u.diffusionRadius, 0.0) * (0.45 + (0.55 * lensProfile));\n"
"    float2 uv0 = aspectFillUV(refractedPoint, u);\n"
"    float2 uvL = aspectFillUV(refractedPoint + float2(-diffusion, 0.0), u);\n"
"    float2 uvR = aspectFillUV(refractedPoint + float2( diffusion, 0.0), u);\n"
"    float2 uvT = aspectFillUV(refractedPoint + float2(0.0, -diffusion), u);\n"
"    float2 uvB = aspectFillUV(refractedPoint + float2(0.0,  diffusion), u);\n"
"\n"
"    float3 color = wallpaper.sample(linearSampler, uv0).rgb * 0.56;\n"
"    color += wallpaper.sample(linearSampler, uvL).rgb * 0.11;\n"
"    color += wallpaper.sample(linearSampler, uvR).rgb * 0.11;\n"
"    color += wallpaper.sample(linearSampler, uvT).rgb * 0.11;\n"
"    color += wallpaper.sample(linearSampler, uvB).rgb * 0.11;\n"
"\n"
"    // The glass is revealed mainly by an asymmetric bright/dark rim pair.\n"
"    float edgeWeight = 1.0 - smoothstep(0.0, rimWidth, insideDistance);\n"
"    float2 lightDirection = normalize(float2(-0.62, -0.78));\n"
"    float lightFacing = max(dot(normal, lightDirection), 0.0);\n"
"    float darkFacing = max(dot(normal, -lightDirection), 0.0);\n"
"    float specular = pow(lightFacing, 3.2) * pow(edgeWeight, 1.55);\n"
"    float opposingDark = pow(darkFacing, 2.2) * pow(edgeWeight, 1.35);\n"
"\n"
"    color += float3(u.specularStrength * specular);\n"
"    color *= 1.0 - (u.darkEdgeStrength * opposingDark);\n"
"    color = clamp(color, float3(0.0), float3(1.0));\n"
"\n"
"    // Prototype only replaces pixels in the refractive rim. The center remains\n"
"    // transparent so the real navigation wallpaper + adaptive scrim continue to\n"
"    // show through unchanged; this prevents the lens from becoming a second flat\n"
"    // wallpaper layer and makes actual edge displacement easy to verify on-device.\n"
"    float opticalAlpha = mask * clamp(edgeWeight * 1.10, 0.0, 1.0);\n"
"    return float4(color * opticalAlpha, opticalAlpha);\n"
"}\n";

@interface DOCustomGlassRefractionView ()
{
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLTexture> _wallpaperTexture;
    UIImage *_wallpaperImage;
}
@end

@implementation DOCustomGlassRefractionView

+ (Class)layerClass
{
    return [CAMetalLayer class];
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

- (void)commonInit
{
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.userInteractionEnabled = NO;

    _glassCornerRadius = 14.0;
    _refractiveRimWidth = 12.0;
    _refractionAmount = 0.85;   // UIKit points: ~2.6 px on a 3x iPhone.
    _diffusionRadius = 0.60;    // Deliberately much smaller than a frosted-glass blur.
    _specularStrength = 0.18;
    _darkEdgeStrength = 0.10;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        self.hidden = YES;
        return;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    metalLayer.device = _device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = YES;
    metalLayer.opaque = NO;
    metalLayer.contentsScale = UIScreen.mainScreen.scale;

    _commandQueue = [_device newCommandQueue];

    NSError *libraryError = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:DOCustomGlassRefractionShaderSource
                                                   options:nil
                                                     error:&libraryError];
    if (!library) {
        NSLog(@"[CustomGlass] Metal refraction shader compile failed: %@", libraryError);
        self.hidden = YES;
        return;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"glass_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"glass_fragment"];
    if (!vertexFunction || !fragmentFunction) {
        NSLog(@"[CustomGlass] Metal refraction shader functions are unavailable");
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
        NSLog(@"[CustomGlass] Metal refraction pipeline creation failed: %@", pipelineError);
        self.hidden = YES;
    }
}

static UIImage *DOCustomGlassRefractionNormalizedImage(UIImage *image)
{
    if (!image)
        return nil;

    CGSize orientedSize = image.size;
    if (orientedSize.width < 1.0 || orientedSize.height < 1.0)
        return image;

    CGFloat longestEdge = MAX(orientedSize.width, orientedSize.height);
    CGFloat downscale = longestEdge > 2048.0 ? (2048.0 / longestEdge) : 1.0;
    CGSize targetSize = CGSizeMake(MAX(1.0, floor(orientedSize.width * downscale)),
                                   MAX(1.0, floor(orientedSize.height * downscale)));

    UIGraphicsBeginImageContextWithOptions(targetSize, YES, 1.0);
    [image drawInRect:(CGRect){CGPointZero, targetSize}];
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
        NSLog(@"[CustomGlass] Wallpaper texture upload failed: %@", error);
        return;
    }

    self.hidden = NO;
    [self refreshRefraction];
}

- (void)setGlassCornerRadius:(CGFloat)glassCornerRadius
{
    _glassCornerRadius = MAX(0.0, glassCornerRadius);
    [self refreshRefraction];
}

- (void)setRefractiveRimWidth:(CGFloat)refractiveRimWidth
{
    _refractiveRimWidth = MAX(1.0, refractiveRimWidth);
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

    if (!_device || !_commandQueue || !_pipelineState || !_wallpaperTexture ||
        !self.window || CGRectIsEmpty(self.bounds))
        return;

    UIView *samplingView = self.wallpaperSamplingView;
    if (!samplingView || CGRectIsEmpty(samplingView.bounds))
        return;

    CGRect sampleRect = [self convertRect:self.bounds toView:samplingView];
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (!drawable)
        return;

    DOCustomGlassRefractionUniforms uniforms = {
        .viewSize = {(float)CGRectGetWidth(self.bounds), (float)CGRectGetHeight(self.bounds)},
        .viewOrigin = {(float)CGRectGetMinX(sampleRect), (float)CGRectGetMinY(sampleRect)},
        .viewportSize = {(float)CGRectGetWidth(samplingView.bounds), (float)CGRectGetHeight(samplingView.bounds)},
        .textureSize = {(float)_wallpaperTexture.width, (float)_wallpaperTexture.height},
        .cornerRadius = (float)self.glassCornerRadius,
        .rimWidth = (float)self.refractiveRimWidth,
        .refractionAmount = (float)self.refractionAmount,
        .diffusionRadius = (float)self.diffusionRadius,
        .specularStrength = (float)self.specularStrength,
        .darkEdgeStrength = (float)self.darkEdgeStrength,
        .screenScale = (float)(self.window.screen.scale ?: UIScreen.mainScreen.scale),
        .padding = 0.0f,
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
