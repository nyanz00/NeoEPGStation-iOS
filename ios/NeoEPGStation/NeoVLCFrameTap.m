#import "NeoVLCFrameTap.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

@interface NeoTappedVideoLayer : AVSampleBufferDisplayLayer
@property (atomic, weak) id<NeoVideoFrameSink> frameSink;
@end
@implementation NeoTappedVideoLayer
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  id<NeoVideoFrameSink> sink = self.frameSink;
  if (sink && CMSampleBufferGetImageBuffer(sampleBuffer)) {
    [sink receiveVideoSampleBuffer:sampleBuffer];
  }
  [super enqueueSampleBuffer:sampleBuffer];
}
@end

static Class NeoVideoLayerClass(id object, SEL selector) { return NeoTappedVideoLayer.class; }

@implementation NeoVLCFrameTap
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
@end
