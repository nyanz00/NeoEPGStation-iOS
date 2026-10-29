#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#include <stdlib.h>

static __weak UIViewController *neoConnectedPlayer;
static int64_t neoTime(id backend) { return [[backend valueForKey:@"timeMs"] longLongValue]; }
static NSInteger neoOutput(id backend) { return [[[backend valueForKey:@"snapshot"] objectForKey:@"outputID"] integerValue]; }
static void neoSetIntent(UIViewController *player, BOOL playing) {
  ((void(*)(id,SEL,BOOL))objc_msgSend)(player,NSSelectorFromString(@"setPlaybackIntent:"),playing);
}

// Diagnostic-only A/B: test whether AVFoundation's hasNew flag suppresses an
// already decoded paused picture. Never enabled for final validation or the IPA.
@implementation AVPlayerItemVideoOutput (NeoPausedPixelProbe)
+ (void)load {
  if (![NSProcessInfo.processInfo.environment[@"NEO_EPG_NATIVE_PIXEL_PROBE"] isEqual:@"1"]) { return; }
  method_exchangeImplementations(class_getInstanceMethod(self,@selector(hasNewPixelBufferForItemTime:)),
    class_getInstanceMethod(self,@selector(neo_pausedHasNewPixelBufferForItemTime:)));
}
- (BOOL)neo_pausedHasNewPixelBufferForItemTime:(CMTime)time {
  BOOL available = [self neo_pausedHasNewPixelBufferForItemTime:time];
  id backend = [neoConnectedPlayer valueForKey:@"aether"];
  BOOL diagnostic = backend && ![[backend valueForKey:@"ready"] boolValue] &&
    ![[neoConnectedPlayer valueForKey:@"wantsPlayback"] boolValue];
  return available || diagnostic;
}
@end

// The original probe paused only the backend while the controller still wanted
// to play. Exercise production intent handling on the already-built app instead.
// This harness is simulator-only and is never part of the IPA.
static void neoInstallRecoveryProbe(void) {
  if (![NSProcessInfo.processInfo.environment[@"NEO_EPG_RECOVERY_CHECKS"] isEqual:@"1"]) { return; }
  Class backendClass = NSClassFromString(@"NeoAetherBackend");
  SEL selector = NSSelectorFromString(@"runDetachedPiPFeedProbe:");
  Method method = class_getInstanceMethod(backendClass,selector);
  if (!method) { return; }
  IMP implementation = imp_implementationWithBlock(^(id backend, void (^completion)(NSDictionary *)) {
    UIViewController *player = neoConnectedPlayer;
    UIView *surface = [[backend valueForKey:@"view"] subviews].firstObject;
    id sink = [backend valueForKey:@"frameSink"];
    int64_t start = neoTime(backend); NSInteger output = neoOutput(backend);
    NSInteger captured = [[sink valueForKey:@"capturedFrameCount"] integerValue];
    [backend setValue:@YES forKey:@"pipActive"]; surface.hidden = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
      NSMutableDictionary *checks = [NSMutableDictionary new];
      checks[@"detachedPiPVideoAdvances"] = @(surface.hidden && neoTime(backend)-start > 4500 && neoOutput(backend) == output);
      checks[@"independentPiPFeed"] = @([[sink valueForKey:@"capturedFrameCount"] integerValue] > captured+40);
      int64_t target = neoTime(backend)+3000;
      ((void(*)(id,SEL,int64_t,void(^)(BOOL)))objc_msgSend)(backend,NSSelectorFromString(@"seekMilliseconds:completion:"),target,^(BOOL ok) {
        checks[@"detachedPiPSeekReachesTarget"] = @(ok && llabs(neoTime(backend)-target) < 500 && neoOutput(backend) == output);
        // The same common action used by the production pause button.
        neoSetIntent(player,NO);
        checks[@"controllerPauseUsed"] = @(player != nil && ![[player valueForKey:@"wantsPlayback"] boolValue]);
        [backend setValue:@NO forKey:@"pipActive"]; surface.hidden = NO;
        ((void(*)(id,SEL))objc_msgSend)(backend,NSSelectorFromString(@"background"));
        ((void(*)(id,SEL))objc_msgSend)(backend,NSSelectorFromString(@"foreground"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
          checks[@"presentationRestoreDoesNotReopenInput"] = @(neoOutput(backend) == output);
          checks[@"presentationRestoreKeepsPause"] = @(![[backend valueForKey:@"playing"] boolValue] &&
            ![[player valueForKey:@"wantsPlayback"] boolValue] && [[backend valueForKey:@"effectiveVolume"] floatValue] > 0 &&
            llabs(neoTime(backend)-target) < 1000);
          completion(checks);
        });
      });
    });
  });
  class_replaceMethod(backendClass,selector,implementation,method_getTypeEncoding(method));
}

// Simulator harness only, never linked or packaged into either application.
// NeoShell presents production players fullScreen. The standalone probe was
// introduced without that flag; adapt its presentation while reusing the exact
// already-built binary, so the horizontal dismissal gets its destination view.
@implementation UIViewController (NeoConnectedPresentation)
+ (void)load {
  if (!NSProcessInfo.processInfo.environment[@"NEO_EPG_AETHER_CONNECTED"]) { return; }
  Method original = class_getInstanceMethod(self, @selector(presentViewController:animated:completion:));
  Method harness = class_getInstanceMethod(self, @selector(neo_connectedPresent:animated:completion:));
  method_exchangeImplementations(original, harness);
  neoInstallRecoveryProbe();
}
- (void)neo_connectedPresent:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
  if ([controller isKindOfClass:NSClassFromString(@"NeoPlayerController")]) {
    neoConnectedPlayer = controller;
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
  }
  [self neo_connectedPresent:controller animated:animated completion:completion];
}
@end
