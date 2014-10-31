//
//  METLViewController.m
//  MetalDemo
//
//  Created by Warren Moore on 10/28/14.
//  Copyright (c) 2014 objc.io. All rights reserved.
//

#import "METLViewController.h"

@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;

static matrix_float4x4 rotation_matrix_2d(float radians)
{
    float cos = cosf(radians);
    float sin = sinf(radians);
    
    matrix_float4x4 m = {
        .columns[0] = {  cos, sin, 0, 0 },
        .columns[1] = { -sin, cos, 0, 0 },
        .columns[2] = {    0,   0, 1, 0 },
        .columns[3] = {    0,   0, 0, 1 }
    };
    return m;
}

static float quadVertexData[] =
{
     0.5, -0.5, 0.0, 1.0,     1.0, 0.0, 0.0, 1.0,
    -0.5, -0.5, 0.0, 1.0,     0.0, 1.0, 0.0, 1.0,
    -0.5,  0.5, 0.0, 1.0,     0.0, 0.0, 1.0, 1.0,
    
     0.5,  0.5, 0.0, 1.0,     1.0, 1.0, 0.0, 1.0,
     0.5, -0.5, 0.0, 1.0,     1.0, 0.0, 0.0, 1.0,
    -0.5,  0.5, 0.0, 1.0,     0.0, 0.0, 1.0, 1.0,
};

typedef struct
{
    matrix_float4x4 rotation_matrix;
} Uniforms;

@interface METLViewController ()

// Long-lived Metal objects
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLLibrary> defaultLibrary;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;

// Resources
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;

// Transient objects
@property (nonatomic, strong) id<CAMetalDrawable> currentDrawable;

@property (nonatomic, strong) CADisplayLink *timer;

@property (nonatomic, assign) BOOL layerSizeDidUpdate;
@property (nonatomic, assign) Uniforms uniforms;
@property (nonatomic, assign) float rotationAngle;

@end

@implementation METLViewController

- (void)dealloc {
    [_timer invalidate];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self setupMetal];
    [self buildPipeline];
    
    // Set up the render loop to redraw in sync with the main screen refresh rate
    self.timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(redraw)];
    [self.timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)setupMetal {
    // Create the default Metal device
    self.device = MTLCreateSystemDefaultDevice();
    
    // Create, configure, and add a Metal sublayer to the current layer
    self.metalLayer = [CAMetalLayer layer];
    self.metalLayer.device = self.device;
    self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.metalLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:self.metalLayer];

    // Create a long-lived command queue
    self.commandQueue = [self.device newCommandQueue];
    
    // Get the library that contains the functions compiled into our app bundle
    self.defaultLibrary = [self.device newDefaultLibrary];

    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)buildPipeline {
    // Generate a vertex buffer for holding the vertex data of the quad
    self.vertexBuffer = [self.device newBufferWithBytes:quadVertexData
                                                 length:sizeof(quadVertexData)
                                                options:MTLResourceOptionCPUCacheModeDefault];

    // Generate a buffer for holding the uniform rotation matrix
    self.uniformBuffer = [self.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceOptionCPUCacheModeDefault];

    // Fetch the vertex and fragment functions from the library
    id<MTLFunction> vertexProgram = [self.defaultLibrary newFunctionWithName:@"vertex_function"];
    id<MTLFunction> fragmentProgram = [self.defaultLibrary newFunctionWithName:@"fragment_function"];

    // Build a render pipeline descriptor with the desired functions
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Compile the render pipeline
    NSError* error = NULL;
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!self.pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
}

- (MTLRenderPassDescriptor *)renderPassDescriptorForTexture:(id<MTLTexture>) texture
{
    // Configure a render pass with properties applicable to its single color attachment (i.e., the framebuffer)
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0].texture = texture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    return renderPassDescriptor;
}

- (void)render {
    [self update];
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

    id<CAMetalDrawable> drawable = [self currentDrawable];

    // Set up a render pass to draw into the current drawable's texture
    MTLRenderPassDescriptor *renderPassDescriptor = [self renderPassDescriptorForTexture:drawable.texture];

    // Prepare a render command encoder with the current render pass
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    // Configure and issue our draw call
    [renderEncoder setRenderPipelineState:self.pipelineState];
    [renderEncoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

    [renderEncoder endEncoding];

    // Request that the current drawable be presented when rendering is done
    [commandBuffer presentDrawable:drawable];
    
    // Finalize the command buffer and commit it to its queue
    [commandBuffer commit];
}

- (void)update {
    // Generate a rotation matrix for the current rotation angle
    _uniforms.rotation_matrix = rotation_matrix_2d(self.rotationAngle);

    // Copy the rotation matrix into the uniform buffer for the next frame
    void *bufferPointer = [self.uniformBuffer contents];
    memcpy(bufferPointer, &_uniforms, sizeof(Uniforms));
    
    // Update the rotation angle
    _rotationAngle += 0.01;
}

- (void)redraw {
    @autoreleasepool {
        if (self.layerSizeDidUpdate) {
            // Ensure that the drawable size of the Metal layer is equal to its dimensions in pixels
            CGFloat nativeScale = self.view.window.screen.nativeScale;
            CGSize drawableSize = self.metalLayer.bounds.size;
            drawableSize.width *= nativeScale;
            drawableSize.height *= nativeScale;
            self.metalLayer.drawableSize = drawableSize;

            self.layerSizeDidUpdate = NO;
        }
        
        // Draw the scene
        [self render];
        
        self.currentDrawable = nil;
    }
}

- (void)viewDidLayoutSubviews {
    self.layerSizeDidUpdate = YES;
    
    // Re-center the Metal layer in its containing layer with a 1:1 aspect ratio
    CGSize parentSize = self.view.bounds.size;
    CGFloat minSize = MIN(parentSize.width, parentSize.height);
    CGRect frame = CGRectMake((parentSize.width - minSize) / 2,
                              (parentSize.height - minSize) / 2,
                              minSize,
                              minSize);
    [self.metalLayer setFrame:frame];
}

- (id <CAMetalDrawable>)currentDrawable {
    // Our drawable may be nil if we're not on the screen or we've taken too long to render.
    // Block here until we can draw again.
    while (_currentDrawable == nil) {
        _currentDrawable = [self.metalLayer nextDrawable];
    }
    
    return _currentDrawable;
}

@end
