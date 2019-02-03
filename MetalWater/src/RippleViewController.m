//
//  RippleViewController.m
//  MetalWater
//
// Copyright (c) 2015 L.Y.Mesentsev, all rights reserved
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "RippleViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "RippleModel.h"


@interface RippleViewController () {
    RippleModel *_model;
    
    id<MTLDevice>  _device;
    
    id<MTLCommandQueue>  _commandQueue;
    id<MTLRenderPipelineState> _renderPipelineState;
    id<MTLComputePipelineState> _computePipelineState;
    id<MTLTexture> _texture;
    
    id<MTLBuffer> _vertexBuffer;
    id<MTLBuffer> _texcoordsBuffer;
    id<MTLBuffer> _indexBuffer;
    
    id<MTLBuffer> _rippleSourceBuffer;
    id<MTLBuffer> _rippleDestBuffer;
    id<MTLBuffer> _rippleCoeffBuffer;
    id<MTLBuffer> _modelDataBuffer;
    
    dispatch_queue_t _timerQueue;
    dispatch_source_t _randomDropTimer;

    AVAudioPlayer *audioPlayer;
}

@property (nonatomic) dispatch_semaphore_t semaphore;

@end


@implementation RippleViewController


- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}


- (void)viewDidLoad
{
    [super viewDidLoad];

    NSURL *musicUrl = [[NSBundle mainBundle] URLForResource:@"serenade" withExtension:@"mp3"];
    
    audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:musicUrl error:nil];
    [audioPlayer prepareToPlay];
    audioPlayer.numberOfLoops = -1;
    [audioPlayer play];
    
    if (_device == nil)
    {
        _device = MTLCreateSystemDefaultDevice();
    }
    
    CGRect frame = self.view.bounds;
    _metalView = [[MTKView alloc] initWithFrame:frame device:_device];
    _metalView.delegate = (id<MTKViewDelegate>)self;
    _metalView.framebufferOnly = YES;
    _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    [self.view addSubview:_metalView];
    
    _semaphore = dispatch_semaphore_create(1);
    _commandQueue = [_metalView.device newCommandQueue];
    
    NSError *error = nil;
    NSString *fileName = [NSBundle.mainBundle pathForResource:@"background" ofType:@"png"];
    _texture = [self loadTextureWithFileName:fileName];
    
    id<MTLLibrary> library = _device.newDefaultLibrary;
    
    // RENDER PIPELINE
    MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
    pipelineDescriptor.sampleCount = 1;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
    pipelineDescriptor.vertexFunction = [library newFunctionWithName:@"vertexTexture"];
    pipelineDescriptor.fragmentFunction = [library newFunctionWithName:@"fragmentTexture"];
    _renderPipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if ( error )
    {
        NSLog(@"Error: %@", error.localizedDescription);
    }
    
    // COMPUTING PIPELINE
    id<MTLFunction> kernelFunction = [library newFunctionWithName:@"runSimulation"];
    _computePipelineState = [_device  newComputePipelineStateWithFunction:kernelFunction error:&error];
    if ( error )
    {
        NSLog(@"Error: %@", error.localizedDescription);
    }
    
    _timerQueue = dispatch_queue_create("com.lymes.LiquifyDesktop2.timerQueue", 0);
    _randomDropTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _timerQueue);
}


- (void)dealloc
{
}


- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self mtkView:_metalView drawableSizeWillChange:self.view.bounds.size];
}


- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    unsigned int meshFactor;
    if ( UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad )
    {
        meshFactor = 8;
    }
    else
    {
        meshFactor = 6;
    }
    
    _model = [[RippleModel alloc] initWithScreenWidth:self.view.frame.size.width
                                              screenHeight:self.view.frame.size.height
                                                meshFactor:meshFactor
                                               touchRadius:5.0
                                              textureWidth:(unsigned)_texture.width
                                             textureHeight:(unsigned)_texture.height];

    _vertexBuffer = [_device newBufferWithBytes:_model.getVertices length:_model.getVertexSize options:MTLResourceCPUCacheModeDefaultCache];
    _texcoordsBuffer = [_device newBufferWithBytes:_model.getTexCoords length:_model.getVertexSize options:MTLResourceCPUCacheModeDefaultCache];
    _indexBuffer = [_device newBufferWithBytes:_model.getIndices length:_model.getIndexSize options:MTLResourceCPUCacheModeDefaultCache];
    _rippleSourceBuffer = [_device newBufferWithBytes:_model.getRippleSource length:_model.getRippleSize options:MTLResourceCPUCacheModeDefaultCache];
    _rippleDestBuffer = [_device newBufferWithBytes:_model.getRippleDest length:_model.getRippleSize options:MTLResourceCPUCacheModeDefaultCache];
    _rippleCoeffBuffer = [_device newBufferWithBytes:_model.getRippleCoeff length:_model.getRippleCoeffSize options:MTLResourceCPUCacheModeDefaultCache];
    ModelData modelData = _model.getModelData;
    _modelDataBuffer = [_device newBufferWithBytes:&modelData length:sizeof(ModelData) options:MTLResourceStorageModeShared];
    
    [self randomDrops];
}



#pragma mark -
#pragma mark Random drops


- (void)randomDrops
{
    CGPoint randomPoint = CGPointMake( rand() % (int)self.view.frame.size.width,
                                       rand() % (int)self.view.frame.size.height );

    [self initiateRippleAtLocation:randomPoint];
    [self performSelector:@selector(randomDrops) withObject:nil afterDelay:rand() % 3];
}



#pragma mark -
#pragma mark Touches


- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesEnded:touches withEvent:event];
    UITouch *touch = (UITouch *)[touches anyObject];
    CGPoint point = [touch locationInView:self.view];

    [self initiateRippleAtLocation:point];
}


- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesEnded:touches withEvent:event];
    UITouch *touch = (UITouch *)[touches anyObject];
    CGPoint point = [touch locationInView:self.view];

    [self initiateRippleAtLocation:point];
}


- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    for ( int i = 0; i < 50; i++ )
    {
        CGPoint randomPoint = CGPointMake( rand() % (int)self.view.frame.size.width,
                                           rand() % (int)self.view.frame.size.height );

        [self initiateRippleAtLocation:randomPoint];
    }
}


- (void)initiateRippleAtLocation:(CGPoint)location
{
    ModelData modelData = _model.getModelData;
    modelData.location.x = location.x / self.view.bounds.size.width;
    modelData.location.y = location.y / self.view.bounds.size.height;
    memcpy(_modelDataBuffer.contents, &modelData, sizeof(ModelData));
}



#pragma mark -
#pragma mark Rendering


- (void)drawInMTKView:(MTKView *)view
{
    static int counter = 0;
    
    @autoreleasepool
    {
        if (dispatch_semaphore_wait(_semaphore, 0)) { return; }
        
        MTLRenderPassDescriptor *currentRenderPassDescriptor = _metalView.currentRenderPassDescriptor;
        id<MTLDrawable> currentDrawable = _metalView.currentDrawable;
        id<MTLCommandBuffer> commandBuffer = _commandQueue.commandBuffer;
        
        if ( !_model || !currentRenderPassDescriptor || !currentDrawable )
        {
            dispatch_semaphore_signal(_semaphore);
            return;
        }
        
        id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
        [computeEncoder pushDebugGroup:@"ComputeModel"];
        [computeEncoder setComputePipelineState:_computePipelineState];
        [computeEncoder setBuffer:_texcoordsBuffer offset:0 atIndex:0];
        [computeEncoder setBuffer:_modelDataBuffer offset:0 atIndex:1];
        [computeEncoder setBuffer:_rippleDestBuffer offset:0 atIndex:(counter % 2) ? 2 : 3];
        [computeEncoder setBuffer:_rippleSourceBuffer offset:0 atIndex:(counter % 2) ? 3 : 2];
        [computeEncoder setBuffer:_rippleCoeffBuffer offset:0 atIndex:4];
        counter++;
        [computeEncoder popDebugGroup];
        
        MTLSize threadsPerThreadgroup = MTLSizeMake(1, 1, 1);
        MTLSize threadgroupsPerGrid = MTLSizeMake(1, 1, 1);
        [computeEncoder dispatchThreadgroups:threadgroupsPerGrid
                       threadsPerThreadgroup:threadsPerThreadgroup];
        [computeEncoder endEncoding];
        
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:currentRenderPassDescriptor];
        [renderEncoder pushDebugGroup:@"RenderFrame"];
        [renderEncoder setRenderPipelineState:_renderPipelineState];
        [renderEncoder setVertexBuffer:_vertexBuffer    offset:0 atIndex:0];
        [renderEncoder setVertexBuffer:_texcoordsBuffer offset:0 atIndex:1];
        [renderEncoder setFragmentTexture:_texture      atIndex:0];
        [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:_model.getIndexCount indexType:MTLIndexTypeUInt16 indexBuffer:_indexBuffer indexBufferOffset:0 instanceCount:1];
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        
        __weak typeof(self) weakSelf = self;
        [commandBuffer addScheduledHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
            dispatch_semaphore_signal(weakSelf.semaphore);
        }];
        
        [commandBuffer presentDrawable:currentDrawable];
        [commandBuffer commit];
    }
}


#pragma mark -
#pragma mark Utilities


- (id<MTLTexture>)loadTextureWithFileName:(NSString *)fileName
{
    NSError *error;
    UIImage *image = [UIImage imageWithContentsOfFile:fileName];
    
    image = rotateUIImage( image, -90 );
    MTKTextureLoader *texLoader = [[MTKTextureLoader alloc] initWithDevice:_device];

    id<MTLTexture> tex = [texLoader newTextureWithCGImage:image.CGImage options:nil error:&error];
    
    if ( tex == nil )
    {
        NSLog( @"Error loading texture: %@", [error localizedDescription] );
    }
    
    return tex;
}


UIImage *rotateUIImage( const UIImage *src, float angleDegrees )
{
    UIView *rotatedViewBox = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, src.size.width, src.size.height )];
    float angleRadians = angleDegrees * ((float)M_PI / 180.0f);
    CGAffineTransform t = CGAffineTransformMakeRotation( angleRadians );
    
    rotatedViewBox.transform = t;
    CGSize rotatedSize = rotatedViewBox.frame.size;
    rotatedViewBox = nil;
    
    UIGraphicsBeginImageContext( rotatedSize );
    CGContextRef bitmap = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM( bitmap, rotatedSize.width / 2, rotatedSize.height / 2 );
    CGContextRotateCTM( bitmap, angleRadians );
    
    CGContextScaleCTM( bitmap, 1.0, -1.0 );
    CGContextDrawImage( bitmap, CGRectMake( -src.size.width / 2, -src.size.height / 2, src.size.width, src.size.height ), [src CGImage] );
    
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return newImage;
}

@end
