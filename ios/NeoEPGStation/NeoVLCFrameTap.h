#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN
@protocol NeoVideoFrameSink <NSObject>
@property (nonatomic, readonly) BOOL capturingForPiP;
- (void)receiveVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

// Adapter for the pinned VLC 4 sample-buffer output. Apple classes are not
// patched: only VLC's own display-view factory returns our layer subclass.
@interface NeoVLCFrameTap : NSObject
+ (BOOL)install;
+ (void)prepareForeground:(UIView *)view;
+ (void)flushVideoQueue:(UIView *)view;
+ (void)monitorContent:(UIView *)view;
+ (NSDictionary<NSString *, NSNumber *> *)snapshot:(UIView *)view;
+ (void)bindView:(UIView *)view sink:(nullable id<NeoVideoFrameSink>)sink;
+ (void)bindARIBView:(UIView *)view state:(nullable NSInteger (^)(void))state;
+ (void)clearARIBView:(UIView *)view;
#if TARGET_OS_SIMULATOR
+ (void)simulateResourceInterruption:(UIView *)view;
+ (nullable UIView *)videoViewInView:(UIView *)view;
+ (NSDictionary<NSString *, NSNumber *> *)monitoringSmoke;
+ (NSDictionary *)aribSmokeStatistics;
#endif
@end
NS_ASSUME_NONNULL_END
