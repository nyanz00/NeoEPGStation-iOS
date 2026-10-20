// Diagnostic-only application. Uses the exact VLCKit from an existing build.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface VLCTime : NSObject
+ (instancetype)timeWithInt:(int)value;
@property(nonatomic, readonly) NSNumber *value;
@end
@interface VLCMedia : NSObject
+ (instancetype)mediaWithURL:(NSURL *)url;
- (void)addOption:(NSString *)option;
@property(nonatomic, readonly) VLCTime *length;
@end
@interface VLCMediaPlayer : NSObject
@property(nonatomic, strong) VLCMedia *media;
@property(nonatomic, strong) id drawable;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) VLCTime *time;
@property(nonatomic, readonly) BOOL isPlaying;
@property(nonatomic, readonly) BOOL isSeekable;
@property(nonatomic, readonly) NSInteger state;
@property(nonatomic, readonly) void *libVLCMediaPlayer;
- (void)play;
@end
extern int64_t libvlc_media_player_get_time(void *);

@interface ClockProbe : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) VLCMediaPlayer *player;
@property(nonatomic, strong) NSMutableArray *rows;
@property(nonatomic) double began, readyAt;
@property(nonatomic) BOOL issued;
@end
@implementation ClockProbe
- (NSURL *)resultURL {
  return [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"clock-probe.json"];
}
- (void)save:(BOOL)finished {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"finished": @(finished), @"rows": self.rows} options:0 error:nil];
  [data writeToURL:self.resultURL atomically:YES];
}
- (void)mediaPlayerBufferingChanged:(float)progress {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.rows addObject:@{@"event": @"buffer", @"elapsed": @(CACurrentMediaTime()-self.began), @"progress": @(progress)}];
    if (progress >= 1 && self.readyAt == 0) { self.readyAt = CACurrentMediaTime(); }
  });
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.rows = [NSMutableArray new]; self.began = CACurrentMediaTime();
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController *controller = [UIViewController new];
  controller.view.backgroundColor = UIColor.blackColor;
  self.window.rootViewController = controller; [self.window makeKeyAndVisible];
  UIView *video = [[UIView alloc] initWithFrame:controller.view.bounds];
  video.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [controller.view addSubview:video];
  self.player = [VLCMediaPlayer new]; self.player.drawable = video; self.player.delegate = self;
  VLCMedia *media = [VLCMedia mediaWithURL:[NSURL URLWithString:NSProcessInfo.processInfo.environment[@"HLS_PROBE_URL"]]];
  [media addOption:@":network-caching=8000"]; [media addOption:@":adaptive-maxbuffer=8000"];
  self.player.media = media; [self.player play];
  [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
    double elapsed = CACurrentMediaTime()-self.began;
    int64_t native = libvlc_media_player_get_time(self.player.libVLCMediaPlayer)/1000;
    [self.rows addObject:@{@"event": @"sample", @"elapsed": @(elapsed), @"nativeMs": @(native),
      @"wrapperMs": self.player.time.value ?: @(-1), @"lengthMs": self.player.media.length.value ?: @0,
      @"state": @(self.player.state), @"seekable": @(self.player.isSeekable)}];
    BOOL seek = [NSProcessInfo.processInfo.environment[@"HLS_PROBE_SEEK"] isEqualToString:@"1"];
    if (seek && !self.issued && self.readyAt > 0 && CACurrentMediaTime()-self.readyAt > 0.15 && self.player.isSeekable && self.player.media.length.value.longLongValue > 0) {
      self.issued = YES;
      [self.rows addObject:@{@"event": @"seek", @"elapsed": @(elapsed), @"targetMs": @49000}];
      self.player.time = [VLCTime timeWithInt:49000];
    }
    [self save:elapsed >= 12];
    if (elapsed >= 12) { exit(0); }
  }];
  return YES;
}
@end
int main(int argc, char **argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ClockProbe.class)); }
}
