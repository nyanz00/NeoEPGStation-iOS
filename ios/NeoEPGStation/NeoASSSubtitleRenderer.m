#import "NeoASSSubtitleRenderer.h"
#import "NeoEPGStation-Swift.h"

// Compatibility bridge for both engines and the PiP compositor. Ordinary
// captions use Web layout rules instead of libass opaque-box glyph images.
@implementation NeoASSSubtitleRenderer {
  NeoCanvasCaptionRenderer *_canvas;
}
- (instancetype)init { if ((self = [super init])) { _canvas = [NeoCanvasCaptionRenderer new]; } return self; }
- (BOOL)loadText:(NSString *)text { return [_canvas loadText:text]; }
- (void)addFont:(NSData *)font name:(NSString *)name { /* Web ignores ASS font attachments for ordinary captions too. */ }
- (UIImage *)imageAtMilliseconds:(int64_t)time size:(CGSize)size { return [_canvas imageAtMilliseconds:time size:size]; }
- (void)clear { [_canvas clear]; }
@end
