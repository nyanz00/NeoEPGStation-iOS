#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
// Objective-C adapter keeps VLCKit's drawable/PiP protocols at the native boundary.
@interface NeoPlayerController : UIViewController
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title
                  username:(NSString *)username password:(NSString *)password
            networkCaching:(NSInteger)networkCaching;
#if TARGET_OS_SIMULATOR
- (NSDictionary<NSString *, id> *)runLayoutSmokeChecks;
- (BOOL)startPiPSmoke;
- (NSDictionary<NSString *, id> *)piPSmokeState;
#endif
@end
NS_ASSUME_NONNULL_END
