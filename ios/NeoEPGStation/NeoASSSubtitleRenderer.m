#import "NeoASSSubtitleRenderer.h"
// Public libass ABI (libass/ass.h and ass_types.h), already linked by VLCKit.
// Handles are opaque; only the documented ASS_Image prefix is consumed.
typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;
typedef struct ass_image {
  int w, h, stride; unsigned char *bitmap; uint32_t color;
  int dst_x, dst_y; struct ass_image *next;
} ASS_Image;
extern ASS_Library *ass_library_init(void);
extern void ass_library_done(ASS_Library *);
extern ASS_Renderer *ass_renderer_init(ASS_Library *);
extern void ass_renderer_done(ASS_Renderer *);
extern void ass_set_fonts(ASS_Renderer *, const char *, const char *, int, const char *, int);
extern void ass_set_frame_size(ASS_Renderer *, int, int);
extern void ass_set_storage_size(ASS_Renderer *, int, int);
extern ASS_Track *ass_read_memory(ASS_Library *, char *, size_t, char *);
extern void ass_free_track(ASS_Track *);
extern void ass_add_font(ASS_Library *, char *, char *, int);
extern ASS_Image *ass_render_frame(ASS_Renderer *, ASS_Track *, long long, int *);

@implementation NeoASSSubtitleRenderer {
  ASS_Library *_library; ASS_Renderer *_renderer; ASS_Track *_track;
  UIImage *_image; CGSize _size; BOOL _rendered;
}
- (instancetype)init {
  if ((self = [super init])) {
    _library = ass_library_init();
    if (_library) { _renderer = ass_renderer_init(_library); }
    if (_renderer) { ass_set_fonts(_renderer, NULL, "Arial", 1, NULL, 1); }
  }
  return self;
}
- (void)clear { if (_track) { ass_free_track(_track); _track = NULL; } _image = nil; _rendered = NO; }
- (void)addFont:(NSData *)font name:(NSString *)name {
  if (_library && font.length > 0 && font.length <= INT_MAX) {
    ass_add_font(_library,(char *)name.UTF8String,(char *)font.bytes,(int)font.length);
    if (_renderer) { ass_set_fonts(_renderer,NULL,"Arial",1,NULL,1); }
  }
}
- (BOOL)loadText:(NSString *)text {
  [self clear]; if (!_renderer) { return NO; }
  NSMutableData *bytes = [[text dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  NSUInteger length = bytes.length; [bytes appendBytes:"\0" length:1];
  _track = ass_read_memory(_library, bytes.mutableBytes, length, "UTF-8");
  return _track != NULL;
}
- (UIImage *)imageAtMilliseconds:(int64_t)time size:(CGSize)size {
  if (!_track || !_renderer || !isfinite(size.width) || !isfinite(size.height) || size.width < 1 || size.height < 1) { return nil; }
  double scale = MIN(1, MIN(1920/size.width, 1080/size.height));
  int width = MAX(2, (int)lrint(size.width*scale)), height = MAX(2, (int)lrint(size.height*scale));
  CGSize output = CGSizeMake(width,height);
  BOOL resized = !CGSizeEqualToSize(_size,output);
  if (resized) { _size = output; ass_set_frame_size(_renderer,width,height); ass_set_storage_size(_renderer,width,height); }
  int changed = 0; ASS_Image *images = ass_render_frame(_renderer,_track,time,&changed);
  if (!changed && !resized && _rendered) { return _image; }
  _rendered = YES; _image = nil;
  if (!images) { return nil; }
  NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width*height*4];
  unsigned char *base = pixels.mutableBytes;
  for (ASS_Image *image = images; image; image = image->next) {
    if (!image->bitmap || image->w <= 0 || image->h <= 0 || image->stride < image->w) { continue; }
    unsigned a = 255-(image->color&255), r = image->color>>24, g = (image->color>>16)&255, b = (image->color>>8)&255;
    int left = MAX(0,image->dst_x), right = MIN(width,image->dst_x+image->w);
    int top = MAX(0,image->dst_y), bottom = MIN(height,image->dst_y+image->h);
    for (int y=top; y<bottom; y++) {
      const unsigned char *mask = image->bitmap+(y-image->dst_y)*image->stride;
      unsigned char *row = base+((size_t)y*width)*4;
      for (int x=left; x<right; x++) {
        unsigned alpha = (mask[x-image->dst_x]*a+127)/255, inv = 255-alpha;
        unsigned char *p = row+x*4;
        p[0] = (b*alpha+p[0]*inv+127)/255; p[1] = (g*alpha+p[1]*inv+127)/255;
        p[2] = (r*alpha+p[2]*inv+127)/255; p[3] = alpha+(p[3]*inv+127)/255;
      }
    }
  }
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
  CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
  CGImageRef image = CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,NO,kCGRenderingIntentDefault);
  if (image) { _image = [UIImage imageWithCGImage:image]; CGImageRelease(image); }
  CGColorSpaceRelease(color); CGDataProviderRelease(provider); return _image;
}
- (void)dealloc { [self clear]; if (_renderer) { ass_renderer_done(_renderer); } if (_library) { ass_library_done(_library); } }
@end
