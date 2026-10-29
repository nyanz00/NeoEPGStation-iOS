#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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
}
- (void)neo_connectedPresent:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
  if ([controller isKindOfClass:NSClassFromString(@"NeoPlayerController")]) {
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
  }
  [self neo_connectedPresent:controller animated:animated completion:completion];
}
@end
