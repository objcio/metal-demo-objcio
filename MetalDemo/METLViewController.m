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

static const NSUInteger g_max_inflight_buffers = 3;

static const size_t MAX_BYTES_PER_FRAME = 1024*1024;

float quadVertexData[] =
{
    0.5, -0.5, -0.5,  1.0,  0.0, 0.0,
    -0.5, -0.5, -0.5,   0.0,  1.0, 0.0,
    -0.5, 0.5, -0.5,  0.0, 0.0, 1.0,
    
    0.5, 0.5, -0.5,  1.0, 1.0, 0.0,
    0.5, -0.5, -0.5,  1.0,  0.0, 0.0,
    -0.5, 0.5, -0.5,  0.0, 0.0, 1.0
};

typedef struct
{
    matrix_float4x4 modelview_projection_matrix;
    matrix_float4x4 normal_matrix;
} uniforms_t;

@implementation METLViewController
{
    CAMetalLayer *_metalLayer;
    id <CAMetalDrawable> _currentDrawable;
    BOOL _layerSizeDidUpdate;
    MTLRenderPassDescriptor *_renderPassDescriptor;

    CADisplayLink *_timer;
    BOOL _gameLoopPaused;
    dispatch_semaphore_t _inflight_semaphore;
    id <MTLBuffer> _dynamicConstantBuffer;
    uint8_t _constantDataBufferIndex;

    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLBuffer> _vertexBuffer;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _depthTex;
    id <MTLTexture> _msaaTex;

    matrix_float4x4 _projectionMatrix;
    matrix_float4x4 _viewMatrix;
    uniforms_t _uniform_buffer;
    float _rotation;
}

- (void)dealloc
{
    [_timer invalidate];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _constantDataBufferIndex = 0;
    _inflight_semaphore = dispatch_semaphore_create(g_max_inflight_buffers);
    
    [self _setupMetal];
    [self _loadAssets];
    
    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(_gameloop)];
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)_setupMetal
{
    _device = MTLCreateSystemDefaultDevice();
    
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

    [_metalLayer setFrame:self.view.layer.frame];
    [self.view.layer addSublayer:_metalLayer];

    _commandQueue = [_device newCommandQueue];
    
    _defaultLibrary = [_device newDefaultLibrary];

    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)_loadAssets
{
    _dynamicConstantBuffer = [_device newBufferWithLength:MAX_BYTES_PER_FRAME options:0];

    _vertexBuffer = [_device newBufferWithBytes:quadVertexData length:sizeof(quadVertexData) options:MTLResourceOptionCPUCacheModeDefault];

    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"lighting_fragment"];
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"lighting_vertex"];

    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    [pipelineStateDescriptor setSampleCount: 1];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError* error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)setupRenderPassDescriptorForTexture:(id <MTLTexture>) texture
{
    if (_renderPassDescriptor == nil)
        _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    
    _renderPassDescriptor.colorAttachments[0].texture = texture;
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.65f, 0.65f, 0.65f, 1.0f);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    if (!_depthTex || (_depthTex && (_depthTex.width != texture.width || _depthTex.height != texture.height)))
    {
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat: MTLPixelFormatDepth32Float width: texture.width height: texture.height mipmapped: NO];
        _depthTex = [_device newTextureWithDescriptor: desc];

        _renderPassDescriptor.depthAttachment.texture = _depthTex;
        _renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        _renderPassDescriptor.depthAttachment.clearDepth = 1.0f;
        _renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    }
}

- (void)_render
{
    dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
    
    [self _update];
    
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];

    id <CAMetalDrawable> drawable = [self currentDrawable];
    [self setupRenderPassDescriptorForTexture:drawable.texture];

    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
    [renderEncoder setDepthStencilState:_depthState];

    [renderEncoder setRenderPipelineState:_pipelineState];
    [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:_dynamicConstantBuffer offset:(sizeof(uniforms_t) * _constantDataBufferIndex) atIndex:1 ];

    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12 instanceCount:1];

    [renderEncoder endEncoding];

    __block dispatch_semaphore_t block_sema = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];

    _constantDataBufferIndex = (_constantDataBufferIndex + 1) % g_max_inflight_buffers;

    [commandBuffer presentDrawable:drawable];

    [commandBuffer commit];
}

- (void)_reshape
{
    float aspect = fabsf(self.view.bounds.size.width / self.view.bounds.size.height);
    _projectionMatrix = matrix_from_perspective_fov_aspectLH(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0f);
    
    _viewMatrix = matrix_identity_float4x4;
}

- (void)_update
{
    matrix_float4x4 base_model = matrix_multiply(matrix_from_translation(0.0f, 0.0f, 3.0f), matrix_from_rotation(_rotation, 0.0f, 0.0f, 1.0f));
    matrix_float4x4 base_mv = matrix_multiply(_viewMatrix, base_model);
    matrix_float4x4 modelViewMatrix = base_mv;
    
    _uniform_buffer.normal_matrix = matrix_invert(matrix_transpose(modelViewMatrix));
    _uniform_buffer.modelview_projection_matrix = matrix_multiply(_projectionMatrix, modelViewMatrix);

    uint8_t *bufferPointer = (uint8_t *)[_dynamicConstantBuffer contents] + (sizeof(uniforms_t) * _constantDataBufferIndex);
    memcpy(bufferPointer, &_uniform_buffer, sizeof(uniforms_t));
    
    _rotation += 0.01f;
}

- (void)_gameloop
{
    @autoreleasepool {
        if (_layerSizeDidUpdate)
        {
            CGFloat nativeScale = self.view.window.screen.nativeScale;
            CGSize drawableSize = self.view.bounds.size;
            drawableSize.width *= nativeScale;
            drawableSize.height *= nativeScale;
            _metalLayer.drawableSize = drawableSize;
            
            [self _reshape];
            _layerSizeDidUpdate = NO;
        }
        
        [self _render];
        
        _currentDrawable = nil;
    }
}

- (void)viewDidLayoutSubviews
{
    _layerSizeDidUpdate = YES;
    [_metalLayer setFrame:self.view.layer.frame];
}

#pragma mark Utilities

- (id <CAMetalDrawable>)currentDrawable
{
    while (_currentDrawable == nil)
    {
        _currentDrawable = [_metalLayer nextDrawable];
        if (!_currentDrawable)
        {
            NSLog(@"CurrentDrawable is nil");
        }
    }
    
    return _currentDrawable;
}

static matrix_float4x4 matrix_from_perspective_fov_aspectLH(const float fovY, const float aspect, const float nearZ, const float farZ)
{
    float yscale = 1.0f / tanf(fovY * 0.5f); // 1 / tan == cot
    float xscale = yscale / aspect;
    float q = farZ / (farZ - nearZ);
    
    matrix_float4x4 m = {
        .columns[0] = { xscale, 0.0f, 0.0f, 0.0f },
        .columns[1] = { 0.0f, yscale, 0.0f, 0.0f },
        .columns[2] = { 0.0f, 0.0f, q, 1.0f },
        .columns[3] = { 0.0f, 0.0f, q * -nearZ, 0.0f }
    };
    
    return m;
}

static matrix_float4x4 matrix_from_translation(float x, float y, float z)
{
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (vector_float4) { x, y, z, 1.0 };
    return m;
}

static matrix_float4x4 matrix_from_rotation(float radians, float x, float y, float z)
{
    vector_float3 v = vector_normalize(((vector_float3){x, y, z}));
    float cos = cosf(radians);
    float cosp = 1.0f - cos;
    float sin = sinf(radians);
    
    matrix_float4x4 m = {
        .columns[0] = {
            cos + cosp * v.x * v.x,
            cosp * v.x * v.y + v.z * sin,
            cosp * v.x * v.z - v.y * sin,
            0.0f,
        },
        
        .columns[1] = {
            cosp * v.x * v.y - v.z * sin,
            cos + cosp * v.y * v.y,
            cosp * v.y * v.z + v.x * sin,
            0.0f,
        },
        
        .columns[2] = {
            cosp * v.x * v.z + v.y * sin,
            cosp * v.y * v.z - v.x * sin,
            cos + cosp * v.z * v.z,
            0.0f,
        },
        
        .columns[3] = { 0.0f, 0.0f, 0.0f, 1.0f
        }
    };
    return m;
}

@end
