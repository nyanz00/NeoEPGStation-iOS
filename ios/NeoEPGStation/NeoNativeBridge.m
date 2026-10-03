#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(NeoNative, NSObject)
RCT_EXTERN_METHOD(loadConnection:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(saveConnection:(NSDictionary *)value resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(play:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
