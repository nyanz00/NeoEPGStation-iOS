#import "NeoVLCFrameTap.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

@interface NeoTappedVideoLayer : AVSampleBufferDisplayLayer
@property (atomic, weak) id<NeoVideoFrameSink> frameSink;
@property (atomic) BOOL appBackground;
@property (atomic) double monitorUntil;
@property (atomic) double lastFingerprintHost;
@property (atomic) double changedHost;
@property (atomic) double scheduledHost;
@property (atomic) NSUInteger changes;
@property (atomic) NSUInteger samples;
@property (atomic) uint64_t fingerprint;
@property (atomic) BOOL hasFingerprint;
@end
@implementation NeoTappedVideoLayer
- (instancetype)init {
  self = [super init];
  if (self) {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded)
      name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foregrounded)
      name:UIApplicationDidBecomeActiveNotification object:nil];
  }
  return self;
}
- (void)backgrounded { self.appBackground = YES; }
- (void)foregrounded {
  self.appBackground = NO;
  // flush keeps the paused image, but removes stale scheduled frames even
  // when AVFoundation has not marked the renderer failed.
  [self prepareResume];
}
- (void)prepareResume {
  @synchronized(self) { [super flush]; self.monitorUntil = CACurrentMediaTime()+60; self.hasFingerprint = NO; }
}
- (void)flushQueue { @synchronized(self) { [super flush]; } }
- (NSDictionary *)snapshot {
  @synchronized(self) {
    double now = CACurrentMediaTime();
    return @{ @"samples": @(self.samples), @"changes": @(self.changes),
      @"contentAge": @(self.changedHost > 0 ? now-self.changedHost : -1),
      @"scheduledInMs": @((self.scheduledHost-now)*1000), @"layerStatus": @(super.status),
      @"layerReady": @(super.readyForMoreMediaData), @"requiresFlush": @(self.requiresFlushToResumeDecoding) };
  }
}
- (void)observeContent:(CMSampleBufferRef)sample {
  self.samples += 1;
  double now = CACurrentMediaTime(); self.scheduledHost = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
  if (now > self.monitorUntil || now-self.lastFingerprintHost < 0.1) { return; }
  CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample); if (!pixel) { return; }
  if (CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) { return; }
  BOOL planar = CVPixelBufferIsPlanar(pixel);
  size_t width = planar ? CVPixelBufferGetWidthOfPlane(pixel,0) : CVPixelBufferGetWidth(pixel);
  size_t height = planar ? CVPixelBufferGetHeightOfPlane(pixel,0) : CVPixelBufferGetHeight(pixel);
  size_t row = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel,0) : CVPixelBufferGetBytesPerRow(pixel);
  const uint8_t *base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixel,0) : CVPixelBufferGetBaseAddress(pixel);
  OSType format = CVPixelBufferGetPixelFormatType(pixel);
  size_t step = planar ? (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 2 : 1) : 4;
  uint64_t hash = 1469598103934665603ULL;
  if (base && width > 0 && height > 0 && width*step <= row) {
    for (int y=0; y<8; y++) { for (int x=0; x<8; x++) {
      hash ^= base[(height*(2*y+1)/16)*row+(width*(2*x+1)/16)*step]; hash *= 1099511628211ULL;
    } }
    if (!self.hasFingerprint || hash != self.fingerprint) { self.changedHost = now; self.changes += 1; }
    self.hasFingerprint = YES; self.fingerprint = hash; self.lastFingerprintHost = now;
  }
  CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
}
- (AVQueuedSampleBufferRenderingStatus)status {
  AVQueuedSampleBufferRenderingStatus status = super.status;
  // The inactive inline layer can lose renderer resources in the background.
  // VLC must still deliver decoded frames to the separate active PiP source.
  if (status == AVQueuedSampleBufferRenderingStatusFailed && (self.appBackground || self.frameSink.capturingForPiP)) {
    return AVQueuedSampleBufferRenderingStatusUnknown;
  }
  return status;
}
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  [self observeContent:sampleBuffer];
  id<NeoVideoFrameSink> sink = self.frameSink;
  if (sink && CMSampleBufferGetImageBuffer(sampleBuffer)) {
    [sink receiveVideoSampleBuffer:sampleBuffer];
  }
  // Background audio also keeps VLC decoding without feeding an inactive
  // inline AV renderer. PiP, if active, receives the same decoded stream.
  if (!self.appBackground) { [super enqueueSampleBuffer:sampleBuffer]; }
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

static Class NeoVideoLayerClass(id object, SEL selector) { return NeoTappedVideoLayer.class; }

@implementation NeoVLCFrameTap
+ (NeoTappedVideoLayer *)layerIn:(UIView *)view {
  if ([view.layer isKindOfClass:NeoTappedVideoLayer.class]) { return (NeoTappedVideoLayer *)view.layer; }
  for (UIView *child in view.subviews) { NeoTappedVideoLayer *layer = [self layerIn:child]; if (layer) { return layer; } }
  return nil;
}
+ (void)prepareForeground:(UIView *)view { [[self layerIn:view] prepareResume]; }
+ (void)flushVideoQueue:(UIView *)view { [[self layerIn:view] flushQueue]; }
+ (NSDictionary *)snapshot:(UIView *)view { return [[self layerIn:view] snapshot] ?: @{}; }
+ (BOOL)install {
  static BOOL installed;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class viewClass = NSClassFromString(@"VLCSampleBufferDisplayView");
    Method factory = class_getClassMethod(viewClass, @selector(layerClass));
    if (!viewClass || !factory || ![viewClass isSubclassOfClass:UIView.class]) { return; }
    Class (*original)(id, SEL) = (void *)method_getImplementation(factory);
    if (original(viewClass, @selector(layerClass)) != AVSampleBufferDisplayLayer.class) { return; }
    class_replaceMethod(object_getClass(viewClass), @selector(layerClass),
      (IMP)NeoVideoLayerClass, method_getTypeEncoding(factory));
    installed = YES;
  });
  return installed;
}
+ (void)bindView:(UIView *)view sink:(id<NeoVideoFrameSink>)sink {
  NSAssert(NSThread.isMainThread, @"Bind VLC views on the main thread");
  if ([view.layer isKindOfClass:NeoTappedVideoLayer.class]) {
    ((NeoTappedVideoLayer *)view.layer).frameSink = sink;
  }
  for (UIView *child in view.subviews) { [self bindView:child sink:sink]; }
}
#if TARGET_OS_SIMULATOR
+ (UIView *)videoViewInView:(UIView *)view {
  if ([view.layer isKindOfClass:NeoTappedVideoLayer.class]) { return view; }
  for (UIView *child in view.subviews) {
    UIView *found = [self videoViewInView:child]; if (found) { return found; }
  }
  return nil;
}
#endif
@end
