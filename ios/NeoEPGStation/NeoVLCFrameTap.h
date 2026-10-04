#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN
@protocol NeoVideoFrameSink <NSObject>
- (void)receiveVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

// Adapter for the pinned VLC 4 sample-buffer output. Apple classes are not
// patched: only VLC's own display-view factory returns our layer subclass.
@interface NeoVLCFrameTap : NSObject
+ (BOOL)install;
+ (void)bindView:(UIView *)view sink:(nullable id<NeoVideoFrameSink>)sink;
@end
NS_ASSUME_NONNULL_END
