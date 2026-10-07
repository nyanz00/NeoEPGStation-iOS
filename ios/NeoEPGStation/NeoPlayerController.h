#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
// Objective-C adapter keeps VLCKit's drawable/PiP protocols at the native boundary.
@interface NeoPlayerController : UIViewController
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onNavigate)(NSString *route);
@property (nonatomic, copy, nullable) void (^onRecording)(NSInteger recordingID);
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *recordingContext;
- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title
                  username:(NSString *)username password:(NSString *)password
            networkCaching:(NSInteger)networkCaching;
#if TARGET_OS_SIMULATOR
- (void)runVideoTapSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion NS_SWIFT_NAME(runVideoTapSmoke(completion:));
- (void)closeTapSmoke;
- (void)runRecoverySmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion NS_SWIFT_NAME(runRecoverySmoke(completion:));
- (void)runEndedSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion NS_SWIFT_NAME(runEndedSmoke(completion:));
- (NSDictionary<NSString *, id> *)runSeekStateSmokeChecks;
- (void)runControlsSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion NS_SWIFT_NAME(runControlsSmoke(completion:));
- (NSDictionary<NSString *, id> *)runLayoutSmokeChecks;
- (NSDictionary<NSString *, id> *)finishLayoutSmokeSnapshot;
- (BOOL)startPiPSmoke;
- (NSDictionary<NSString *, id> *)piPSmokeState;
- (void)runReloadSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion NS_SWIFT_NAME(runReloadSmoke(completion:));
- (void)runExitSmokeFromHost:(UIViewController *)host completion:(void (^)(NSDictionary<NSString *, id> *))completion NS_SWIFT_NAME(runExitSmoke(host:completion:));
#endif
@end
NS_ASSUME_NONNULL_END
