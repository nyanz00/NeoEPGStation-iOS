#import "NeoVLCFrameTap.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char NeoARIBStateKey, NeoARIBPictureKey, NeoARIBTimerKey;
static void (*NeoOriginalSubtitleDraw)(id, SEL, id);
static void NeoDrawARIBSubtitle(id view, SEL selector, id picture) {
  NSInteger (^state)(void) = objc_getAssociatedObject(view, &NeoARIBStateKey);
  if (!state) {
    // Track selection and the app's first UI update are asynchronous. Keep the
    // image already on this view so binding after its first draw loses nothing.
    if (picture) { objc_setAssociatedObject(view, &NeoARIBPictureKey, picture, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    NeoOriginalSubtitleDraw(view, selector, picture); return;
  }
  NSInteger active = state();
  NSArray *regions = picture && [picture respondsToSelector:@selector(regions)] ?
    ((id (*)(id, SEL))objc_msgSend)(picture, @selector(regions)) : nil;
  if (regions.count > 0) {
    objc_setAssociatedObject(view, &NeoARIBPictureKey, picture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NeoOriginalSubtitleDraw(view, selector, picture);
  } else {
    id retained = active > 0 ? objc_getAssociatedObject(view, &NeoARIBPictureKey) : nil;
    NeoOriginalSubtitleDraw(view, selector, retained ?: picture);
    if (!retained) { objc_setAssociatedObject(view, &NeoARIBPictureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    // A known broadcast clear must still clear a retained image, including
    // when VLC has stopped issuing callbacks after its premature expiration.
    if (retained && !objc_getAssociatedObject(view, &NeoARIBTimerKey)) {
      __weak id weakView = view;
      NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        id target = weakView;
        NSInteger (^provider)(void) = target ? objc_getAssociatedObject(target, &NeoARIBStateKey) : nil;
        if (!provider || provider() <= 0) {
          if (target) {
            NeoOriginalSubtitleDraw(target, selector, nil);
            objc_setAssociatedObject(target, &NeoARIBPictureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(target, &NeoARIBTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          }
          [timer invalidate];
        }
      }];
      [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
      objc_setAssociatedObject(view, &NeoARIBTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
}

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
@property (atomic) NSUInteger outputID;
@property (atomic) double arrivalHost;
@property (atomic) BOOL resourceInterrupted;
@end
@implementation NeoTappedVideoLayer
- (instancetype)init {
  self = [super init];
  if (self) {
    static NSUInteger nextOutputID;
    @synchronized(NeoTappedVideoLayer.class) { self.outputID = ++nextOutputID; }
    // A decoder repair creates a new layer after the foreground notification.
    // Arm monitoring at creation too, without flushing its empty queue.
    self.monitorUntil = CACurrentMediaTime()+60;
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
  @synchronized(self) {
    // flush clears AVFoundation's error, but cannot rebuild VLC's decoder.
    // Preserve evidence of revoked resources across notification ordering.
    if (super.requiresFlushToResumeDecoding || super.error.code == AVErrorOperationInterrupted) {
      self.resourceInterrupted = YES;
    }
    [super flush]; self.monitorUntil = CACurrentMediaTime()+60; self.hasFingerprint = NO;
  }
}
- (void)flushQueue { @synchronized(self) { [super flush]; } }
- (void)monitorContent { @synchronized(self) { self.monitorUntil = CACurrentMediaTime()+60; } }
- (NSDictionary *)snapshot {
  @synchronized(self) {
    double now = CACurrentMediaTime();
    return @{ @"outputID": @(self.outputID), @"samples": @(self.samples), @"changes": @(self.changes),
      @"monitoring": @(now <= self.monitorUntil), @"arrivalAge": @(self.arrivalHost > 0 ? now-self.arrivalHost : -1),
      @"resourceInterrupted": @(self.resourceInterrupted),
      @"layerErrorCode": @(super.error.code),
      @"contentAge": @(self.changedHost > 0 ? now-self.changedHost : -1),
      @"scheduledInMs": @((self.scheduledHost-now)*1000), @"layerStatus": @(super.status),
      @"layerReady": @(super.readyForMoreMediaData), @"requiresFlush": @(self.requiresFlushToResumeDecoding) };
  }
}
- (void)observeContent:(CMSampleBufferRef)sample {
  self.samples += 1;
  double now = CACurrentMediaTime(); self.arrivalHost = now; self.scheduledHost = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
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
  if (status == AVQueuedSampleBufferRenderingStatusFailed &&
      (super.requiresFlushToResumeDecoding || super.error.code == AVErrorOperationInterrupted)) {
    self.resourceInterrupted = YES;
  }
  // The inactive inline layer can lose renderer resources in the background.
  // VLC must still deliver decoded frames to the separate active PiP source.
  if (status == AVQueuedSampleBufferRenderingStatusFailed && (self.appBackground || self.frameSink.capturingForPiP)) {
    return AVQueuedSampleBufferRenderingStatusUnknown;
  }
  return status;
}
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  @synchronized(self) { [self observeContent:sampleBuffer]; }
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
+ (void)bindARIBView:(UIView *)view state:(NSInteger (^)(void))state {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class type = NSClassFromString(@"VLCSampleBufferSubpictureView");
    Method method = class_getInstanceMethod(type, NSSelectorFromString(@"drawSubpicture:"));
    if (method) { NeoOriginalSubtitleDraw = (void *)method_getImplementation(method); method_setImplementation(method, (IMP)NeoDrawARIBSubtitle); }
  });
  if (!NeoOriginalSubtitleDraw) { return; }
  if ([NSStringFromClass(view.class) isEqualToString:@"VLCSampleBufferSubpictureView"]) {
    id old = objc_getAssociatedObject(view, &NeoARIBStateKey);
    if (!state && old) { [self clearARIBView:view]; }
    objc_setAssociatedObject(view, &NeoARIBStateKey, state, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (state && !old && state() > 0 && objc_getAssociatedObject(view, &NeoARIBPictureKey)) {
      NeoDrawARIBSubtitle(view, NSSelectorFromString(@"drawSubpicture:"), nil);
    }
  }
  for (UIView *child in view.subviews) { [self bindARIBView:child state:state]; }
}
+ (void)clearARIBView:(UIView *)view {
  if (objc_getAssociatedObject(view, &NeoARIBStateKey)) {
    [(NSTimer *)objc_getAssociatedObject(view, &NeoARIBTimerKey) invalidate];
    objc_setAssociatedObject(view, &NeoARIBTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &NeoARIBPictureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NeoOriginalSubtitleDraw(view, NSSelectorFromString(@"drawSubpicture:"), nil);
  }
  for (UIView *child in view.subviews) { [self clearARIBView:child]; }
}
+ (NeoTappedVideoLayer *)layerIn:(UIView *)view {
  if ([view.layer isKindOfClass:NeoTappedVideoLayer.class]) { return (NeoTappedVideoLayer *)view.layer; }
  for (UIView *child in view.subviews) { NeoTappedVideoLayer *layer = [self layerIn:child]; if (layer) { return layer; } }
  return nil;
}
+ (void)prepareForeground:(UIView *)view { [[self layerIn:view] prepareResume]; }
+ (void)flushVideoQueue:(UIView *)view { [[self layerIn:view] flushQueue]; }
+ (void)monitorContent:(UIView *)view { [[self layerIn:view] monitorContent]; }
+ (NSDictionary *)snapshot:(UIView *)view { return [[self layerIn:view] snapshot] ?: @{}; }
#if TARGET_OS_SIMULATOR
+ (void)simulateResourceInterruption:(UIView *)view {
  // Exercise the real decoder/output replacement while the media is paused.
  [self layerIn:view].resourceInterrupted = YES;
}
#endif
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
+ (NSDictionary<NSString *, NSNumber *> *)monitoringSmoke {
  NeoTappedVideoLayer *old = [NeoTappedVideoLayer new], *layer = [NeoTappedVideoLayer new];
  BOOL fresh = [[layer snapshot][@"monitoring"] boolValue] && old.outputID != layer.outputID;
  old.resourceInterrupted = YES; [old prepareResume];
  BOOL interrupted = [[old snapshot][@"resourceInterrupted"] boolValue] && ![[layer snapshot][@"resourceInterrupted"] boolValue];
  CVPixelBufferRef pixel = NULL; CMVideoFormatDescriptionRef format = NULL; CMSampleBufferRef sample = NULL;
  if (CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, NULL, &pixel) != kCVReturnSuccess) {
    return @{@"freshOutputMonitored": @(fresh), @"freshOutputContentChangesMeasured": @NO};
  }
  CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &format);
  CMSampleTimingInfo timing = { kCMTimeInvalid, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000), kCMTimeInvalid };
  CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, format, &timing, &sample);
  if (sample) {
    for (int i=0; i<3; i++) {
      CVPixelBufferLockBaseAddress(pixel, 0);
      memset(CVPixelBufferGetBaseAddress(pixel), 20+i, CVPixelBufferGetBytesPerRow(pixel)*16);
      CVPixelBufferUnlockBaseAddress(pixel, 0);
      layer.lastFingerprintHost = 0;
      [layer observeContent:sample];
    }
  }
  NSDictionary *stats = [layer snapshot];
  BOOL measured = [stats[@"changes"] integerValue] == 3 && [stats[@"contentAge"] doubleValue] >= 0;
  if (sample) { CFRelease(sample); } if (format) { CFRelease(format); } CVPixelBufferRelease(pixel);
  return @{@"freshOutputMonitored": @(fresh), @"freshOutputContentChangesMeasured": @(measured), @"interruptedResourceSurvivesDisplayFlush": @(interrupted)};
}
+ (UIView *)videoViewInView:(UIView *)view {
  if ([view.layer isKindOfClass:NeoTappedVideoLayer.class]) { return view; }
  for (UIView *child in view.subviews) {
    UIView *found = [self videoViewInView:child]; if (found) { return found; }
  }
  return nil;
}
#endif
@end
