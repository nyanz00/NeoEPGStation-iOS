#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
// Ordinary-caption Web layout bridge, independently of the video decoder.
@interface NeoASSSubtitleRenderer : NSObject
- (BOOL)loadText:(NSString *)text;
- (void)addFont:(NSData *)font name:(NSString *)name;
- (nullable UIImage *)imageAtMilliseconds:(int64_t)time size:(CGSize)size;
- (void)clear;
@end
NS_ASSUME_NONNULL_END
