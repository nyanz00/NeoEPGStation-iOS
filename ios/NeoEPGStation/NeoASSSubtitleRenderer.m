#import "NeoASSSubtitleRenderer.h"
#import "NeoEPGStation-Swift.h"
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
  ASS_Library *_library; ASS_Renderer *_renderer, *_bandRenderer; ASS_Track *_track, *_bands;
  UIImage *_image; CGSize _size; BOOL _rendered;
  NSString *_source, *_font; double _aspect;
  NSArray<NSArray<NSNumber *> *> *_intervals;
}
- (instancetype)init {
  if ((self = [super init])) {
    _library = ass_library_init();
    if (_library) { _renderer = ass_renderer_init(_library); _bandRenderer = ass_renderer_init(_library); }
    // Same iOS font chain as Web subtitleFont.ts. Do not force the comment
    // worker's bundled Noto Sans JP onto ordinary captions.
    UIFont *font = [UIFont fontWithName:@"HiraginoMaruGothicProN-W4" size:20] ?: [UIFont fontWithName:@"HiraginoSans-W3" size:20] ?: [UIFont systemFontOfSize:20];
    _font = font.familyName;
    if (_renderer) { ass_set_fonts(_renderer, NULL, _font.UTF8String, 1, NULL, 1); }
    if (_bandRenderer) { ass_set_fonts(_bandRenderer, NULL, _font.UTF8String, 1, NULL, 1); }
  }
  return self;
}
- (void)clear { @synchronized(self) { if (_track) { ass_free_track(_track); _track = NULL; } if (_bands) { ass_free_track(_bands); _bands = NULL; } _source = nil; _intervals = nil; _image = nil; _rendered = NO; } }
- (void)addFont:(NSData *)font name:(NSString *)name {
  @synchronized(self) {
  if (_library && font.length > 0 && font.length <= INT_MAX) {
    ass_add_font(_library,(char *)name.UTF8String,(char *)font.bytes,(int)font.length);
    if (_renderer) { ass_set_fonts(_renderer,NULL,_font.UTF8String,1,NULL,1); }
    if (_bandRenderer) { ass_set_fonts(_bandRenderer,NULL,_font.UTF8String,1,NULL,1); }
  }
  }
}
- (ASS_Track *)readScript:(NSString *)text {
  NSMutableData *bytes = [[text dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  NSUInteger length = bytes.length; [bytes appendBytes:"\0" length:1];
  return ass_read_memory(_library, bytes.mutableBytes, length, "UTF-8");
}
- (BOOL)prepareAspect:(double)aspect {
  if (_track) { ass_free_track(_track); _track = NULL; }
  if (_bands) { ass_free_track(_bands); _bands = NULL; }
  NSArray<NSString *> *scripts = [NeoCaptionStyle scripts:_source font:_font aspect:aspect];
  _track = [self readScript:scripts[0]]; _bands = [self readScript:scripts[1]];
  _aspect = aspect; _rendered = NO; return _track != NULL;
}
- (BOOL)loadText:(NSString *)text {
  @synchronized(self) { [self clear]; if (!_renderer || !_bandRenderer) { return NO; }
    _source = [text copy]; _intervals = [NeoCaptionStyle intervals:text]; return [self prepareAspect:16.0/9.0];
  }
}
- (UIImage *)imageAtMilliseconds:(int64_t)time size:(CGSize)size {
  @synchronized(self) {
  if (!_track || !_renderer || !isfinite(size.width) || !isfinite(size.height) || size.width < 1 || size.height < 1) { return nil; }
  double aspect = size.width/size.height;
  if (fabs(aspect-_aspect) > 0.001 && ![self prepareAspect:aspect]) { return nil; }
  // Screen and composited PiP share one script/image cache at a stable size.
  int width = MAX(2,(int)lrint(MIN(1920,1080*aspect))), height = MAX(2,(int)lrint(MIN(1080,1920/aspect)));
  CGSize output = CGSizeMake(width,height);
  BOOL resized = !CGSizeEqualToSize(_size,output);
  if (resized || !_rendered) { _size = output; ass_set_frame_size(_renderer,width,height); ass_set_storage_size(_renderer,width,height);
    ass_set_frame_size(_bandRenderer,width,height); ass_set_storage_size(_bandRenderer,width,height); }
  int changed = 0; ASS_Image *images = ass_render_frame(_renderer,_track,time,&changed);
  int bandChanged = 0; ASS_Image *bands = _bands ? ass_render_frame(_bandRenderer,_bands,time,&bandChanged) : NULL;
  if (!changed && !bandChanged && !resized && _rendered) { return _image; }
  _rendered = YES; _image = nil;
  if (!images && !bands) { return nil; }
  NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width*height*4];
  unsigned char *base = pixels.mutableBytes;
  // Canvas fills the union of equally colored bands once. Taking maximum mask
  // coverage avoids darker seams where translucent line/ruby boxes overlap.
  NSMutableOrderedSet<NSNumber *> *colors = [NSMutableOrderedSet new];
  NSMutableSet<NSArray<NSNumber *> *> *activeIntervals = [NSMutableSet new]; BOOL positioned = YES;
  for (NSArray<NSNumber *> *interval in _intervals) {
    if (interval[0].doubleValue <= time/1000.0 && time/1000.0 < interval[1].doubleValue) {
      [activeIntervals addObject:[interval subarrayWithRange:NSMakeRange(0,3)]]; positioned = positioned && interval[3].boolValue;
    }
  }
  for (ASS_Image *band = bands; band; band = band->next) { if ((band->color&255) < 255) { [colors addObject:@(band->color)]; } }
  for (NSNumber *color in colors) {
    uint32_t rgba = color.unsignedIntValue; unsigned a = 255-(rgba&255), r = rgba>>24, g = (rgba>>16)&255, b = (rgba>>8)&255;
    NSMutableData *coverage = [NSMutableData dataWithLength:(NSUInteger)width*height]; unsigned char *mask = coverage.mutableBytes;
    for (ASS_Image *band = bands; band; band = band->next) {
      if (band->color != rgba || !band->bitmap || band->stride < band->w) { continue; }
      for (int y=MAX(0,band->dst_y); y<MIN(height,band->dst_y+band->h); y++) {
        for (int x=MAX(0,band->dst_x); x<MIN(width,band->dst_x+band->w); x++) {
          unsigned char value = band->bitmap[(y-band->dst_y)*band->stride+x-band->dst_x];
          mask[(size_t)y*width+x] = MAX(mask[(size_t)y*width+x],value);
        }
      }
    }
    // Join a small positioned ruby band to the body only when all active
    // fragments share one exact interval/layer, as required by Web. Skip
    // ambiguous overlaps from independent simultaneous caption intervals.
    if (positioned && activeIntervals.count == 1) {
      for (ASS_Image *ruby = bands; ruby; ruby = ruby->next) {
        if (ruby->color != rgba || ruby->h <= 0) { continue; }
        int bodyTop = INT_MAX;
        for (ASS_Image *body = bands; body; body = body->next) {
          if (body == ruby || body->color != rgba || ruby->h > body->h*0.65 || ruby->dst_x >= body->dst_x+body->w || ruby->dst_x+ruby->w <= body->dst_x) { continue; }
          int gap = body->dst_y-(ruby->dst_y+ruby->h);
          if (gap >= 0 && gap <= body->h) { bodyTop = MIN(bodyTop,body->dst_y); }
        }
        if (bodyTop == INT_MAX) { continue; }
        for (int y=MAX(0,ruby->dst_y+ruby->h); y<MIN(height,bodyTop); y++) {
          for (int x=MAX(0,ruby->dst_x); x<MIN(width,ruby->dst_x+ruby->w); x++) { mask[(size_t)y*width+x] = 255; }
        }
      }
    }
    for (size_t i=0; i<(size_t)width*height; i++) {
      unsigned alpha = (mask[i]*a+127)/255, inv = 255-alpha; unsigned char *p = base+i*4;
      p[0]=(b*alpha+p[0]*inv+127)/255; p[1]=(g*alpha+p[1]*inv+127)/255; p[2]=(r*alpha+p[2]*inv+127)/255; p[3]=alpha+(p[3]*inv+127)/255;
    }
  }
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
}
- (void)dealloc { [self clear]; if (_renderer) { ass_renderer_done(_renderer); } if (_bandRenderer) { ass_renderer_done(_bandRenderer); } if (_library) { ass_library_done(_library); } }
@end
