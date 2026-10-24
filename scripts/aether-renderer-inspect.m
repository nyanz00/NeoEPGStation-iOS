#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

// Test-only observer, injected into the unchanged synthetic simulator app.
// No changes to the engine or its clocks, callbacks, buffers or rendering.
static void InspectLayer(CALayer *layer, NSMutableArray *rows, NSURL *directory) {
    if ([layer isKindOfClass:AVSampleBufferDisplayLayer.class]) {
        AVSampleBufferDisplayLayer *display = (id)layer;
        AVSampleBufferVideoRenderer *renderer = display.sampleBufferRenderer;
        CVPixelBufferRef pixel = [renderer copyDisplayedPixelBuffer];
        CFTypeRef pts = pixel ? CVBufferCopyAttachment(pixel, CFSTR("NeoAetherSourcePTS"), NULL) : NULL;
        CFTypeRef gen = pixel ? CVBufferCopyAttachment(pixel, CFSTR("NeoAetherPictureGeneration"), NULL) : NULL;
        [rows addObject:@{@"kind":@"sample", @"ready":@(display.isReadyForDisplay),
            @"status":@(renderer.status), @"pixel":@(pixel != NULL), @"pts":@(pts != NULL), @"generation":@(gen != NULL),
            @"width":@(layer.bounds.size.width), @"height":@(layer.bounds.size.height)}];
        if (pixel) {
            CIImage *input = [CIImage imageWithCVPixelBuffer:pixel];
            CGImageRef image = [[CIContext context] createCGImage:input fromRect:input.extent];
            if (image) { [UIImagePNGRepresentation([UIImage imageWithCGImage:image]) writeToURL:[directory URLByAppendingPathComponent:@"aether-renderer-picture.png"] atomically:YES]; CGImageRelease(image); }
            CFRelease(pixel);
        }
        if (pts) CFRelease(pts); if (gen) CFRelease(gen);
    }
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        [rows addObject:@{@"kind":@"native", @"ready":@(((AVPlayerLayer *)layer).readyForDisplay)}];
    }
    for (CALayer *child in layer.sublayers) InspectLayer(child, rows, directory);
}
__attribute__((constructor)) static void BeginInspection(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSURL *directory = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSMutableArray *rows = [NSMutableArray array];
        NSMutableSet<UIWindow *> *windows = [NSMutableSet setWithArray:UIApplication.sharedApplication.windows];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        for (UIWindow *window in windows) InspectLayer(window.layer, rows, directory);
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"layers":rows} options:NSJSONWritingPrettyPrinted error:NULL];
        [json writeToURL:[directory URLByAppendingPathComponent:@"aether-renderer-inspection.json"] atomically:YES];
    });
}
