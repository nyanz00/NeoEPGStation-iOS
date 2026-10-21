#import "NeoPlayerController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <VLCKit/VLCKit.h>
#import "NeoEPGStation-Swift.h"
#import "NeoVLCFrameTap.h"
#import <stdio.h>

// Pinned VLCKit 4.0.0a25 uses this block internally for jumpWithOffset.
// Its public position setter has no completion overload. Guard the setter
// before using the same one-shot notification for a position-based TS seek.
@interface VLCMediaPlayer (NeoPositionSeekCompletion)
@property (nonatomic, copy, nullable) dispatch_block_t onSeekCompletion;
@end

// Observe VLCKit's existing time watcher; registering a second libVLC watcher
// would replace/break the wrapper's seek and pause handling. This ABI is pinned
// by VLCKit.podspec (4.0.0a25). Always forward both notifications unchanged.
typedef struct {
  double position, rate;
  int64_t ts_us, length_us, system_date_us;
} NeoNativeTimePoint;
extern int64_t libvlc_clock(void);
extern int64_t libvlc_media_player_get_time(void *);
extern int libvlc_media_player_time_point_interpolate(const NeoNativeTimePoint *, int64_t, int64_t *, double *);
@interface VLCMediaPlayer (NeoNativeTimeObserver)
@property (nonatomic, readonly, getter=isSeeking) BOOL seeking;
- (void)setSeeking:(BOOL)seeking;
- (void)mediaPlayerLastTimePointUpdated:(const NeoNativeTimePoint)point;
- (void *)libVLCMediaPlayer;
@end
@interface NeoObservedMediaPlayer : VLCMediaPlayer {
  NeoNativeTimePoint _observedPoint;
  int64_t _observedAt;
  int64_t _progressAt;
  BOOL _hasObservedPoint;
  uint64_t _observedSequence;
}
#if TARGET_OS_SIMULATOR
@property (nonatomic) BOOL smokeUntrustedTime;
#endif
- (NSDictionary<NSString *, NSNumber *> *)observedClock;
- (int64_t)nativeTimeMs;
@end
@implementation NeoObservedMediaPlayer
- (int64_t)nativeTimeMs {
  // LibVLC's getter accounts for pause_date/discontinuities in the player
  // timer. The wrapper caches a separate interpolation which can be stale.
  void *instance = self.libVLCMediaPlayer;
  if (!instance) { return -1; }
  int64_t microseconds = libvlc_media_player_get_time(instance);
  return microseconds < 0 ? -1 : microseconds/1000;
}
#if TARGET_OS_SIMULATOR
- (VLCTime *)time {
  return self.smokeUntrustedTime ? [VLCTime timeWithInt:34000] : super.time;
}
#endif
- (void)setMedia:(VLCMedia *)media {
  @synchronized(self) { _hasObservedPoint = NO; }
  [super setMedia:media];
}
- (void)mediaPlayerLastTimePointUpdated:(const NeoNativeTimePoint)point {
  [super mediaPlayerLastTimePointUpdated:point];
  if (point.ts_us < 0) { return; }
  @synchronized(self) {
    int64_t now = libvlc_clock();
    if (!_hasObservedPoint || point.ts_us != _observedPoint.ts_us) { _progressAt = now; }
    _observedPoint = point; _observedAt = now; _hasObservedPoint = YES; _observedSequence++;
  }
}
- (void)setSeeking:(BOOL)seeking {
  // VLCKit publishes the synthetic requested point BEFORE setting seeking=YES.
  // Discard it here. A subsequent on_update is real output, even if seeking
  // remains true until the following on_seek(NULL) notification.
  if (seeking) { @synchronized(self) { _hasObservedPoint = NO; } }
  [super setSeeking:seeking];
}
- (NSDictionary<NSString *, NSNumber *> *)observedClock {
  @synchronized(self) {
    if (!_hasObservedPoint) { return @{}; }
    int64_t position = 0; double fraction = 0;
    // Capture a confirmed point, not the wrapper's indefinitely extrapolated
    // value after its input loop stops publishing statistics/time updates.
    int result = libvlc_media_player_time_point_interpolate(&_observedPoint, _observedAt, &position, &fraction);
    if (result < 0) { return @{}; }
    return @{@"positionMs": @(MAX(0, position/1000)),
      @"sequence": @(_observedSequence), @"age": @(MAX(0, libvlc_clock()-_progressAt)/1000000.0)};
  }
}
@end

// Only fixed-format numeric timing messages leave libVLC. Never export its raw
// debug messages: they can contain the server URL, credentials or track text.
@interface NeoNativePlaybackLogger : NSObject <VLCLogging>
@property (nonatomic) VLCLogLevel level;
+ (void)install;
@end
@implementation NeoNativePlaybackLogger
+ (void)install {
  // Empty player options use the shared library. Keep its stateless logger
  // installed: VLCKit's setter unsets libVLC's callback on logSyncQueue while
  // in-flight callbacks synchronously wait for that very queue (RCU deadlock).
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NeoNativePlaybackLogger *logger = [NeoNativePlaybackLogger new]; logger.level = kVLCLogLevelDebug;
    VLCLibrary.sharedLibrary.loggers = @[logger];
  });
}
- (void)handleMessage:(NSString *)message logLevel:(VLCLogLevel)level context:(VLCLogContext *)context {
  // This fixed input-loop message distinguishes EOF from a warning/error.
  if ([message isEqualToString:@"EOF reached"]) { [NeoPlaybackDiagnostics record:@"vlc.inputEOF" fields:@{}]; }
  if (level == kVLCLogLevelError || level == kVLCLogLevelWarning) {
    // Classify locally; raw libVLC messages can include private URLs/text.
    NSInteger kind = [message containsString:@"PCR"] || [message containsString:@"pts_delay"] || [message containsString:@"clock"] || [message containsString:@"timestamp"] ? 7
      : [message containsString:@"late"] || [message containsString:@"dropp"] ? 8
      : [message containsString:@"VideoToolbox"] || [message containsString:@"VTDecompression"] ? 9
      : [message containsString:@"INPUT_CONTROL_SET_TIME"] || [message containsString:@"seek"] ? 1
      : [message containsString:@"EOF"] || [message containsString:@"end of file"] ? 2
      : [message containsString:@"read"] ? 3
      : [message containsString:@"connect"] || [message containsString:@"HTTP"] ? 4
      : [message containsString:@"decod"] ? 5 : [message containsString:@"demux"] ? 6 : 0;
    [NeoPlaybackDiagnostics nativeError:kind level:level];
  }
  NSString *event = nil; long long first = 0, second = 0;
  unsigned long long position = 0;
  if ([message hasPrefix:@"seek: preroll{ req: "] &&
      sscanf(message.UTF8String, "seek: preroll{ req: %lld, start-pts: %lld, start-fpos: %llu}", &first, &second, &position) == 3) {
    [NeoPlaybackDiagnostics record:@"mkv.nativeSeek" fields:@{@"targetTicks": @(first), @"startTicks": @(second), @"offset": @(position)}];
  }
  if ([message hasPrefix:@"Stream buffering done ("] &&
      sscanf(message.UTF8String, "Stream buffering done (%lld ms in %lld ms)", &first, &second) == 2) {
    event = @"vlc.bufferReady";
  } else if ([message hasPrefix:@"Decoder wait done in "] &&
      sscanf(message.UTF8String, "Decoder wait done in %lld ms", &first) == 1) {
    event = @"vlc.decoderReady";
  } else if ([message hasPrefix:@"seeking with "] &&
      sscanf(message.UTF8String, "seeking with %lldms preroll (use input-fast-seek to avoid) to %lld", &first, &second) == 2) {
    event = @"vlc.seekPreroll";
  }
  if (event) {
    NSDictionary *fields = [event isEqualToString:@"vlc.seekPreroll"]
      ? @{@"prerollMs": @(first), @"targetTicks": @(second)}
      : @{@"durationMs": @(first), @"wallMs": @(second)};
    [NeoPlaybackDiagnostics record:event fields:fields];
  }
}
@end

@interface NeoPlayerController () <VLCDrawable, VLCMediaPlayerDelegate, VLCCustomDialogRendererProtocol>
@property (nonatomic) NSURL *sourceURL;
@property (nonatomic) NSString *mediaTitle;
@property (nonatomic) NSString *username;
@property (nonatomic) NSString *password;
@property (nonatomic) NSInteger networkCaching;
@property (nonatomic) NeoObservedMediaPlayer *player;
@property (nonatomic) VLCDialogProvider *dialogs;
@property (nonatomic) NSValue *loginReference;
@property (nonatomic) UIAlertController *loginAlert;
@property (nonatomic) UIView *movieView;
@property (nonatomic) UIView *inlineBacking;
@property (nonatomic, weak) UIView *videoOutputView;
@property (nonatomic) NeoBufferingUpdates *bufferingUpdates;
@property (nonatomic) NeoNowPlaying *nowPlaying;
@property (nonatomic) BOOL inputBufferReady;
@property (nonatomic) NSTimeInterval lastIntentCommandAt;
@property (nonatomic) BOOL lastIssuedIntent;
@property (nonatomic) UILabel *statusLabel;
@property (nonatomic, copy) NSString *lastPresentedWarning;
@property (nonatomic) UILabel *timeLabel;
@property (nonatomic) UIButton *playButton;
@property (nonatomic) UIButton *pipButton;
@property (nonatomic) UIButton *subtitleButton;
@property (nonatomic) UIButton *commentButton;
@property (nonatomic) UILabel *commentLabel;
@property (nonatomic) NeoCommentOverlay *comments;
@property (nonatomic) NeoARIBCaptionClock *aribClock;
@property (nonatomic) NSMutableSet<NSString *> *suppressedCommentTracks;
@property (nonatomic) BOOL buffering;
@property (nonatomic) UISlider *timeline;
@property (nonatomic) NeoCommentPiP *commentPiP;
@property (nonatomic) BOOL frameTapInstalled;
@property (nonatomic) UIView *header;
@property (nonatomic) NeoPlayerChrome *chrome;
@property (nonatomic) UIInterfaceOrientationMask orientationMask;
@property (nonatomic) BOOL reloading;
@property (nonatomic) BOOL restoringReload;
@property (nonatomic) int64_t reloadTime;
@property (nonatomic) BOOL reloadPlaying;
@property (nonatomic) float playbackRate;
@property (nonatomic) NSArray<NSString *> *reloadTextTracks;
@property (nonatomic, copy) NSString *pendingRoute;
@property (nonatomic) NSInteger pendingRecording;
@property (nonatomic) UIView *controls;
@property (nonatomic) BOOL landscape;
@property (nonatomic) NSTimer *controlsHideTimer;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) BOOL pipActive;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL finishedClosing;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL resumeAfterInterruption;
@property (nonatomic) NeoPlaybackCache *rewindCache;
@property (nonatomic) NeoStreamingSession *streamingSession;
@property (nonatomic) NeoStreamingClock *streamClock;
@property (nonatomic) NeoStreamingSubtitles *streamingSubtitles;
@property (nonatomic) NSMutableSet<NSURL *> *attachedSubtitles;
@property (nonatomic) BOOL streamSubtitleUserSelected;
@property (nonatomic) NSURL *playbackURL;
@property (nonatomic) NeoPlaybackHistory *history;
@property (nonatomic) BOOL wantsPlayback;
@property (nonatomic) BOOL seeking;
@property (nonatomic) BOOL playbackEnded;
@property (nonatomic) BOOL playbackFailed;
@property (nonatomic) NSInteger seekGeneration;
@property (nonatomic, copy) dispatch_block_t seekCompletion;
@property (nonatomic) NSTimer *seekTimer;
@property (nonatomic) BOOL tsPositionWaitForPause;
@property (nonatomic) NSTimeInterval tsPositionResumeAt;
@property (nonatomic) NSTimer *reloadTimer;
@property (nonatomic) int64_t lastObservedTime;
@property (nonatomic) int64_t lastObservedLength;
@property (nonatomic) BOOL hasInputLength;
@property (nonatomic) BOOL lastSeekFailed;
@property (nonatomic) BOOL transportSuspended;
@property (nonatomic) BOOL awaitingEndpoint;
@property (nonatomic) BOOL transportRecoveryAttempted;
@property (nonatomic) BOOL awaitingComments;
@property (nonatomic) NSInteger reloadGeneration;
@property (nonatomic) int64_t backgroundTime;
@property (nonatomic) BOOL backgroundPositionValid;
@property (nonatomic) BOOL inputInBackground;
@property (nonatomic) int64_t inputStartTime;
@property (nonatomic) BOOL tsPositionPending, tsPositionIssued, tsPositionCallback;
@property (nonatomic) int64_t tsPositionTarget;
@property (nonatomic) NSTimer *tsPositionTimer;
@property (nonatomic) NSTimeInterval tsPositionDeadline;
@property (nonatomic) uint64_t tsPositionSequence, tsPositionDecoded;
@property (nonatomic) NSUInteger tsPositionSamples, tsPositionOutputID;
@property (nonatomic) NSTimeInterval tsPositionLastDiagnostic;
#if TARGET_OS_SIMULATOR
@property (nonatomic) NSInteger smokeTSRepairReloadBaseline;
#endif
@property (nonatomic) BOOL reloadTimedOut;
@property (nonatomic) BOOL networkReloadWaiting, networkProbePending, restoreMuted, restorePreviousMute;
@property (nonatomic) NSTimer *networkRetryTimer;
@property (nonatomic) uint64_t restoreDecoded, restoreLost;
@property (atomic) BOOL invalidClockReported;
@property (nonatomic) NSTimeInterval inputClockGuardUntil;
@property (nonatomic, copy) dispatch_block_t reloadCompletion;
@property (nonatomic, copy) NSString *subtitleSignature;
@property (nonatomic) NSTimeInterval lastDiagnosticSample;
@property (nonatomic) NSTimeInterval seekStartedAt;
@property (nonatomic) BOOL awaitingSeekVideo;
@property (nonatomic) BOOL videoWatchPending;
@property (nonatomic) NeoVideoRecovery *videoRecovery;
@property (nonatomic) NeoNetworkPlaybackFlow *networkFlow;
@property (nonatomic) int64_t flowHoldTime;
@property (nonatomic) BOOL flowResyncing;
@property (nonatomic) BOOL flowMuted, flowPreviousMute;
@property (nonatomic) double flowVerifyDeadline;
@property (nonatomic) uint64_t flowDecodedVideo;
@property (nonatomic) NSTimeInterval flowDecodedAt;
@property (nonatomic) uint64_t flowPlayedAudio;
@property (nonatomic) NSTimeInterval flowAudioAt;
@property (nonatomic) NSTimeInterval flowStaleThreshold;
@property (nonatomic) NSInteger lastVideoOutputID;
@property (nonatomic) BOOL repairingVideo;
@property (nonatomic) BOOL videoResuming;
@property (nonatomic) BOOL videoReloadRecovery;
@property (nonatomic) BOOL videoRecoveryFallbackAttempted;
@property (nonatomic) NSTimeInterval videoReloadDeadline;
@property (nonatomic) BOOL videoResumePriming;
@property (nonatomic) BOOL videoResumeSeekFinished;
@property (nonatomic) NSInteger videoResumeStage;
@property (nonatomic) NSInteger videoResumeGeneration;
@property (nonatomic) NSInteger videoResumeOldOutput;
@property (nonatomic) NSTimeInterval videoResumeDeadline;
@property (nonatomic) int64_t videoResumeTime;
@property (nonatomic) VLCMedia *videoResumeMedia;
@property (nonatomic, copy) NSString *videoResumeTrack;
@property (nonatomic) NSNumber *videoResumeDeferredTime;
@property (nonatomic, copy) dispatch_block_t videoResumeDeferredCompletion;
@property (nonatomic) NeoPlayerTransition *playerTransition;
@property (nonatomic) UIView *rotationContainer;
@property (nonatomic) UIViewPropertyAnimator *rotationAnimator;
@property (nonatomic) BOOL rotatingPlayer;
@property (nonatomic) NSInteger rotationGeneration;
@property (nonatomic) NSInteger orientationRequestGeneration;
@property (nonatomic) BOOL internalOrientation;
@property (nonatomic) NSTimeInterval playerRotationDuration;
@property (nonatomic) CGFloat rotationHandoffDelta;
@property (nonatomic) NSTimeInterval systemRotationDuration;
@property (nonatomic) BOOL dismissingPlayer;
@property (nonatomic, weak) UIViewController *dismissalPresenter;
@property (nonatomic, weak) UIWindowScene *dismissalScene;
@property (nonatomic) NeoPlayerController *closingRetain;
#if TARGET_OS_SIMULATOR
@property (nonatomic) CGRect smokeSavedFrame;
@property (nonatomic) BOOL smokeStopVideoResume;
#endif
@end

@implementation NeoPlayerController
- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title username:(NSString *)username
                  password:(NSString *)password networkCaching:(NSInteger)networkCaching {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _sourceURL = url; _mediaTitle = title; _username = username;
    _password = password; _networkCaching = networkCaching;
    _orientationMask = UIInterfaceOrientationMaskAllButUpsideDown; _playbackRate = 1;
    _playerTransition = [NeoPlayerTransition new]; self.transitioningDelegate = _playerTransition;
  }
  return self;
}


- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
  self.initialPosition = isfinite(self.initialPosition) ? MAX(0, self.initialPosition) : 0;
  self.lastObservedTime = (int64_t)llround(self.initialPosition * 1000);
  [NeoPlaybackDiagnostics begin];
  [NeoPlaybackDiagnostics record:@"player.start" fields:@{@"networkCachingMs": @(self.networkCaching)}];
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  self.chrome = [[NeoPlayerChrome alloc] initWithTitle:self.mediaTitle];
  self.chrome.frame = self.view.bounds; self.chrome.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.rotationContainer = [[UIView alloc] initWithFrame:self.view.bounds];
  [self.view addSubview:self.rotationContainer]; [self.rotationContainer addSubview:self.chrome];
  __weak typeof(self) transitionSelf = self;
  self.playerTransition.onCompletion = ^(BOOL completed) {
    transitionSelf.dismissingPlayer = NO;
    if (completed) { [transitionSelf completePlayerDismissal]; }
  };
  if (self.recordingContext) { [self.chrome configure:self.recordingContext]; }
  self.movieView = self.chrome.videoView;
  __weak typeof(self) zoomOwner = self;
  self.chrome.onZoom = ^(CGFloat scale) { [zoomOwner applyVideoZoom:scale]; };
  self.chrome.onVideoLayout = ^{ [zoomOwner layoutVideoOutputIfNeeded]; };
  self.statusLabel = self.chrome.statusLabel; self.statusLabel.text = @"PLAY · 準備中";
  self.timeLabel = self.chrome.timeLabel; self.commentLabel = self.chrome.commentLabel;
  self.playButton = self.chrome.playButton; self.pipButton = self.chrome.pipButton;
  self.subtitleButton = self.chrome.subtitleButton; self.commentButton = self.chrome.commentButton;
  self.timeline = self.chrome.timeline; self.header = self.chrome.header; self.controls = self.chrome.controls;
  self.pipButton.enabled = NO;
  __weak typeof(self) uiSelf = self;
  self.chrome.onAction = ^(NSString *action) { [uiSelf performPlayerAction:action]; };
  [self applyPlayerLayout:self.view.bounds.size];
  AVAudioSession *audio = AVAudioSession.sharedInstance;
  NSError *error;
  if (![audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&error] ||
      ![audio setActive:YES error:&error]) {
    self.statusLabel.text = @"音声セッションを開始できませんでした。"; return;
  }
  self.player = [[NeoObservedMediaPlayer alloc] initWithOptions:@[]];
  [NeoNativePlaybackLogger install];
  self.dialogs = [[VLCDialogProvider alloc] initWithLibrary:self.player.libraryInstance customUI:YES];
  self.dialogs.customRenderer = self;
  self.player.delegate = self; self.player.drawable = self;
  // The comment display link samples VLC's native clock, not the 0.5s UI timer.
  self.player.timeChangeUpdateInterval = 1.0 / 60.0;
  self.playbackURL = self.sourceURL;
  self.wantsPlayback = YES;
  self.nowPlaying = [[NeoNowPlaying alloc] initWithTitle:self.mediaTitle channel:self.recordingContext[@"channelName"] ?: @""];
  __weak typeof(self) remoteSelf = self;
  self.nowPlaying.playAction = ^{ [remoteSelf setPlaybackIntent:YES]; };
  self.nowPlaying.pauseAction = ^{ [remoteSelf setPlaybackIntent:NO]; };
  self.nowPlaying.toggleAction = ^{ [remoteSelf setPlaybackIntent:!remoteSelf.wantsPlayback]; };
  self.nowPlaying.seekAction = ^BOOL(double seconds) {
    if (!remoteSelf || remoteSelf.closing || remoteSelf.reloading || remoteSelf.reloadTimedOut || !remoteSelf.player.isSeekable || !isfinite(seconds)) { return NO; }
    double bounded = fmin(fmax(0, seconds), [remoteSelf mediaLength] / 1000.0);
    [remoteSelf seekBy:(int64_t)(bounded*1000)-[remoteSelf mediaTime] completion:^{}]; return YES;
  };
  self.nowPlaying.skipAction = ^BOOL(double seconds) {
    if (!remoteSelf || remoteSelf.closing || remoteSelf.reloading || remoteSelf.reloadTimedOut || !remoteSelf.player.isSeekable || !isfinite(seconds)) { return NO; }
    double bounded = fmin(fmax(-[remoteSelf mediaLength] / 1000.0, seconds), [remoteSelf mediaLength] / 1000.0);
    [remoteSelf seekBy:(int64_t)(bounded*1000) completion:^{}]; return YES;
  };
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(interrupted:)
    name:AVAudioSessionInterruptionNotification object:audio];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded)
    name:UIApplicationDidEnterBackgroundNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foregrounded) name:UIApplicationDidBecomeActiveNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive) name:UIApplicationWillResignActiveNotification object:nil];
  __weak typeof(self) weakSelf = self;
  self.bufferingUpdates = [NeoBufferingUpdates new];
  self.networkFlow = [NeoNetworkPlaybackFlow new];
  self.bufferingUpdates.onUpdate = ^(float progress, NSInteger count) { [weakSelf applyBufferingProgress:progress notifications:count]; };
  self.suppressedCommentTracks = [NSMutableSet new];
  self.comments = [[NeoCommentOverlay alloc] initWithFrame:self.movieView.bounds];
  self.comments.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.comments.rateProvider = ^double { return weakSelf.playbackRate; };
  self.comments.timeProvider = ^double { return weakSelf.initialPosition > 0 ? weakSelf.initialPosition : (double)[weakSelf mediaTime] / 1000.0; };
  self.comments.wantsPlaybackProvider = ^BOOL { return weakSelf.wantsPlayback && !weakSelf.playbackEnded && !weakSelf.closing; };
  self.comments.runningProvider = ^BOOL {
    // Brief buffering/state notifications must not interrupt already moving
    // comments while due video frames keep arriving. The presentation clock
    // freezes on actual video inactivity; explicit pause remains immediate.
    double due = weakSelf.commentPiP.videoPresentationHostTime;
    BOOL videoStillAdvancing = due > 0 && CACurrentMediaTime()-due < 0.1;
    return weakSelf.inputBufferReady && weakSelf.player.isPlaying && weakSelf.wantsPlayback &&
      (!weakSelf.buffering || videoStillAdvancing) && !weakSelf.networkFlow.holding && !weakSelf.networkFlow.verifying &&
      !weakSelf.seeking && !weakSelf.scrubbing && !weakSelf.closing && !weakSelf.reloading && !weakSelf.tsPositionPending &&
      !weakSelf.networkReloadWaiting && !weakSelf.videoReloadRecovery;
  };
  self.comments.onChange = ^{ [weakSelf updateCommentState]; [weakSelf updateLoadingState]; };
  [self.chrome bindCommentSettings:self.comments];
  [self.chrome.commentViewport addSubview:self.comments];
  self.frameTapInstalled = [NeoVLCFrameTap install];
  if (self.frameTapInstalled) { self.comments.videoHostProvider = ^double { return weakSelf.commentPiP.videoActivityHostTime; }; }
  self.commentPiP = [NeoCommentPiP new];
  self.commentPiP.view.frame = self.movieView.bounds;
  self.commentPiP.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.movieView insertSubview:self.commentPiP.view atIndex:0];
  // Keep AVKit's source attached for automatic PiP, but never let its priming
  // frame become the background of the normal VLC output after a resize.
  self.inlineBacking = [[UIView alloc] initWithFrame:self.movieView.bounds];
  self.inlineBacking.backgroundColor = UIColor.blackColor; self.inlineBacking.userInteractionEnabled = NO;
  self.inlineBacking.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.movieView insertSubview:self.inlineBacking aboveSubview:self.commentPiP.view];
  self.commentPiP.timeProvider = self.comments.timeProvider;
  self.commentPiP.lengthProvider = ^double { return [weakSelf mediaLength] / 1000.0; };
  self.commentPiP.runningProvider = self.comments.runningProvider;
  self.commentPiP.rateProvider = self.comments.rateProvider;
  self.commentPiP.wantsPlaybackProvider = ^BOOL { return weakSelf.wantsPlayback && !weakSelf.playbackEnded && !weakSelf.closing; };
  self.commentPiP.playAction = ^{ [weakSelf setPlaybackIntent:YES]; };
  self.commentPiP.pauseAction = ^{ [weakSelf setPlaybackIntent:NO]; };
  self.commentPiP.seekAction = ^(double seconds, void (^completion)(void)) {
    [weakSelf seekBy:(int64_t)(seconds * 1000) completion:completion];
  };
  self.commentPiP.onChange = ^{ [weakSelf updatePiPState]; };
  [self.commentPiP updateAutomaticPlayback];
#if TARGET_OS_SIMULATOR
  if (self.sourceURL.isFileURL && [NSProcessInfo.processInfo.environment[@"NEO_EPG_STORAGE_SMOKE"] isEqualToString:@"1"]) {
    [self.comments loadSmokeComments];
    [self.commentPiP beginCompositionSmoke];
  } else
#endif
  { [self.comments configureWithSource:self.sourceURL username:self.username password:self.password
      jikkyo:[self.recordingContext[@"videoFileType"] isEqual:@"ts"]]; }
  if ([self.recordingContext[@"videoFileType"] isEqual:@"ts"]) { self.aribClock = [NeoARIBCaptionClock new]; }
#if TARGET_OS_SIMULATOR
  if (self.aribClock && self.sourceURL.isFileURL) {
    NSData *data = [NSData dataWithContentsOfURL:self.sourceURL];
    if (data) { [self.aribClock observeData:data offset:0]; }
  }
#endif
  [self updateCommentState];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf updateControls]; }];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
  NSNumber *recordingID = self.recordingContext[@"id"];
  NSURL *base = [NSURL URLWithString:self.recordingContext[@"baseURL"] ?: @""];
  if (![self.recordingContext[@"disableHistory"] boolValue] && base && recordingID.integerValue > 0) {
    self.history = [[NeoPlaybackHistory alloc] initWithBase:base recordingID:recordingID.integerValue
      user:self.recordingContext[@"user"] ?: @"master" username:self.username password:self.password];
    self.history.onChange = ^{ [weakSelf updateControls]; };
    self.history.onDiagnostic = ^(NSDictionary *fields) { [NeoPlaybackDiagnostics record:@"history.sendFailure" fields:fields]; };
  }
  [self showControls];
  if ([self isStreaming]) {
    if (![self.recordingContext[@"videoFileType"] isEqual:@"ts"]) {
      self.streamingSubtitles = [[NeoStreamingSubtitles alloc] initWithSource:self.sourceURL username:self.username password:self.password];
      self.streamingSubtitles.onChange = ^{ [weakSelf attachStreamingSubtitles]; };
      [self.streamingSubtitles start];
    }
    [self prepareStreamingAt:self.initialPosition completion:^(NSURL *url, NSString *message) {
      if (!weakSelf || weakSelf.closing) { return; }
      if (!url) {
        weakSelf.playbackFailed = YES; weakSelf.statusLabel.text = message;
        [weakSelf.chrome updateDiagnostics]; [weakSelf updateLoadingState]; [weakSelf showControls]; return;
      }
      weakSelf.playbackURL = url; [weakSelf startWhenCommentsReady];
    }];
  }
  else if (self.sourceURL.isFileURL || [self.recordingContext[@"isRecording"] boolValue]) { [self startWhenCommentsReady]; }
  else {
    self.rewindCache = [[NeoPlaybackCache alloc] initWithSource:self.sourceURL username:self.username password:self.password];
    self.rewindCache.onSourceData = ^(NSData *data, int64_t offset) { [weakSelf.aribClock observeData:data offset:offset]; };
    self.rewindCache.onChange = ^{ [weakSelf updateControls]; };
    self.rewindCache.onTransportFailure = ^{
      if (!weakSelf || weakSelf.closing || weakSelf.transportSuspended || weakSelf.reloading || weakSelf.networkReloadWaiting) { return; }
      weakSelf.videoReloadRecovery = YES;
      weakSelf.videoResumeOldOutput = [[NeoVLCFrameTap snapshot:weakSelf.movieView][@"outputID"] integerValue];
      weakSelf.transportSuspended = YES;
      if (weakSelf.inputInBackground && !weakSelf.wantsPlayback) { return; }
      weakSelf.transportRecoveryAttempted = YES;
      [weakSelf reloadPlaybackAtTime:MAX(weakSelf.lastObservedTime, weakSelf.backgroundPositionValid ? weakSelf.backgroundTime : 0) completion:nil];
    };
    [self.rewindCache fetchDuration:^(double duration) {
      if (weakSelf.closing) { return; }
      if (duration > 0 && weakSelf.lastObservedLength <= 0) { weakSelf.lastObservedLength = (int64_t)llround(duration * 1000); }
      [weakSelf updateControls]; [weakSelf.commentPiP invalidatePlaybackState];
    }];
    [self.rewindCache start:^(NSURL *url, NSString *message) {
      if (weakSelf.closing) { return; }
      if (!url) {
        weakSelf.statusLabel.text = message; [weakSelf.chrome updateDiagnostics];
        // Preserve the direct PLAY/authentication route if Range is unavailable.
        [weakSelf startWhenCommentsReady]; return;
      }
      weakSelf.playbackURL = url; [weakSelf startWhenCommentsReady];
    }];
  }
}

- (void)attachStreamingSubtitles {
  if (self.closing || !self.inputBufferReady || !self.streamingSubtitles) { return; }
  if (!self.attachedSubtitles) { self.attachedSubtitles = [NSMutableSet new]; }
  for (NSURL *url in self.streamingSubtitles.files) {
    if ([self.attachedSubtitles containsObject:url]) { continue; }
    NSNumber *chosen = self.recordingContext[@"streamSubtitleIndex"];
    BOOL selected = !self.streamSubtitleUserSelected && chosen && chosen.integerValue >= 0 &&
      [[url.lastPathComponent componentsSeparatedByString:@"-"].firstObject integerValue] == chosen.integerValue;
    if ([self.player addPlaybackSlave:url type:VLCMediaPlaybackSlaveTypeSubtitle enforce:selected] == 0) { [self.attachedSubtitles addObject:url]; }
  }
}
- (void)armStreamingClockAt:(int64_t)time {
  if (![self isStreaming]) { return; }
  if (!self.streamClock) { self.streamClock = [NeoStreamingClock new]; }
  [self.streamClock resetAt:time host:CACurrentMediaTime()];
}
- (int64_t)guardStreamingTime:(int64_t)time {
  if (!self.streamClock || ![self isStreaming]) { return time; }
  return [self.streamClock positionAt:time host:CACurrentMediaTime()
    running:self.wantsPlayback && self.player.isPlaying && !self.reloading && !self.tsPositionPending rate:self.playbackRate];
}
- (BOOL)isStreaming { return [self.recordingContext[@"streaming"] boolValue]; }
- (BOOL)wholeFileClock { return [self isStreaming] || [self.recordingContext[@"videoFileType"] isEqual:@"ts"]; }
- (void)prepareStreamingAt:(double)time completion:(void (^)(NSURL *, NSString *))completion {
  __weak typeof(self) weakSelf = self;
  BOOL fresh = self.streamingSession == nil;
  if (fresh) {
    NSArray *qualities = self.recordingContext[@"streamQualities"];
    NSInteger mode = [self.recordingContext[@"streamMode"] integerValue];
    if (mode < 0 || mode >= qualities.count) { completion(nil, @"配信の画質設定がありません。"); return; }
    self.streamingSession = [[NeoStreamingSession alloc] initWithSource:self.sourceURL
      ts:[self.recordingContext[@"videoFileType"] isEqual:@"ts"] mode:mode quality:qualities[mode] username:self.username password:self.password];
    self.streamingSession.onChange = ^{ [weakSelf updateControls]; };
    self.streamingSession.onTransportFailure = ^{
      if (!weakSelf || weakSelf.closing || weakSelf.reloading || weakSelf.networkReloadWaiting) { return; }
      [weakSelf reloadPlaybackAtTime:weakSelf.lastObservedTime completion:nil];
    };
  }
  void (^ready)(NSURL *, NSString *) = ^(NSURL *url, NSString *message) {
    if (!weakSelf || weakSelf.closing) { return; }
    if (url) {
      weakSelf.networkCaching = weakSelf.streamingSession.networkCaching;
      weakSelf.lastObservedLength = llround(weakSelf.streamingSession.duration*1000);
    }
    completion(url, message);
  };
  if (fresh) { [self.streamingSession startAt:time completion:ready]; }
  else { [self.streamingSession reopenAt:time completion:ready]; }
}
- (void)applyPlayerLayout:(CGSize)size {
  if (self.rotatingPlayer) { return; }
  BOOL wide = size.width > size.height, requestedWide = self.orientationMask == UIInterfaceOrientationMaskLandscapeRight;
  BOOL padLocked = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
    (self.orientationMask == UIInterfaceOrientationMaskPortrait || self.orientationMask == UIInterfaceOrientationMaskLandscapeRight);
  BOOL swap = (self.internalOrientation || padLocked) && requestedWide != wide;
  CGSize contentSize = swap ? CGSizeMake(size.height, size.width) : size;
  CGFloat angle = swap ? (requestedWide ? M_PI_2 : -M_PI_2) : 0;
  BOOL changed = self.landscape != (contentSize.width > contentSize.height);
  self.landscape = contentSize.width > contentSize.height;
  self.rotationContainer.bounds = (CGRect){CGPointZero, contentSize}; self.rotationContainer.center = CGPointMake(size.width/2, size.height/2);
  self.rotationContainer.transform = CGAffineTransformMakeRotation(angle);
  self.chrome.transform = CGAffineTransformIdentity; self.chrome.frame = (CGRect){CGPointZero, contentSize};
  UIEdgeInsets safe = self.view.safeAreaInsets;
  if (angle > 0) { safe = UIEdgeInsetsMake(safe.right, safe.top, safe.left, safe.bottom); }
  else if (angle < 0) { safe = UIEdgeInsetsMake(safe.left, safe.bottom, safe.right, safe.top); }
  [self.chrome holdRotationInsets:safe];
  [self.chrome setNeedsLayout]; [self.chrome layoutIfNeeded];
  [self alignVideoOutput];
  if (changed) { [self setNeedsStatusBarAppearanceUpdate]; }
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self applyPlayerLayout:self.view.bounds.size]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  CGFloat angle = atan2(coordinator.targetTransform.b, coordinator.targetTransform.a);
  BOOL padLocked = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
    (self.orientationMask == UIInterfaceOrientationMaskPortrait || self.orientationMask == UIInterfaceOrientationMaskLandscapeRight);
  if (fabs(angle) > 0.01 && !self.internalOrientation && !padLocked && !self.closing && !self.dismissingPlayer) {
    [self animatePlayerRotationToSize:size coordinator:coordinator]; return;
  }
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    [self.chrome finishOrientationTransition];
    [self applyPlayerLayout:size];
  } completion:nil];
}
- (void)animatePlayerRotationToSize:(CGSize)size coordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [self.rotationAnimator stopAnimation:YES];
  self.rotatingPlayer = YES; NSInteger generation = ++self.rotationGeneration;
  self.systemRotationDuration = coordinator.transitionDuration;
  self.playerRotationDuration = UIAccessibilityIsReduceMotionEnabled() ? 0.01 : MIN(0.28, coordinator.transitionDuration*0.8);
  self.landscape = size.width > size.height; [self setNeedsStatusBarAppearanceUpdate];
  self.chrome.autoresizingMask = UIViewAutoresizingNone;
  CGAffineTransform rotation = coordinator.targetTransform;
  // Cancel UIKit's window rotation on an owned child, never on the controller's
  // root view. Its live video/UI then rotate with a separate, shorter animator.
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    // UIKit has installed the destination safe area here. Keep it stable while
    // the owned content rotates, instead of relaying intermediate root insets.
    [self.chrome holdRotationInsets:self.view.safeAreaInsets];
    // The root already uses destination coordinates. Rebase centers together;
    // animating this rebase on a different timeline makes the movie drift.
    [UIView performWithoutAnimation:^{
      self.rotationContainer.bounds = (CGRect){CGPointZero, size};
      self.rotationContainer.center = CGPointMake(size.width/2, size.height/2);
      self.chrome.center = CGPointMake(size.width/2, size.height/2);
    }];
    self.rotationContainer.transform = CGAffineTransformInvert(rotation);
    // Start outside the coordinator's inherited animation transaction.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self.rotatingPlayer || self.rotationGeneration != generation) { return; }
      self.rotationAnimator = [[UIViewPropertyAnimator alloc] initWithDuration:self.playerRotationDuration
        curve:UIViewAnimationCurveEaseInOut animations:^{
          [self.chrome finishOrientationTransition];
          // Bounds, video fitting and angle share the shorter timeline.
          self.chrome.bounds = (CGRect){CGPointZero, size}; self.chrome.transform = rotation;
          [self.chrome setNeedsLayout]; [self.chrome layoutIfNeeded]; [self alignVideoOutput];
        }];
      [self.rotationAnimator startAnimation];
    });
  } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    if (self.rotationGeneration != generation) { return; }
    [self.rotationAnimator stopAnimation:YES]; self.rotationAnimator = nil;
    [UIView performWithoutAnimation:^{
      CGRect before = [self.movieView convertRect:self.movieView.bounds toView:self.view];
      // Rebase equal composed transforms without doing a second content layout.
      self.rotationContainer.transform = CGAffineTransformIdentity; self.chrome.transform = CGAffineTransformIdentity;
      self.rotationContainer.frame = (CGRect){CGPointZero, size}; self.chrome.frame = (CGRect){CGPointZero, size};
      self.chrome.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      self.rotatingPlayer = NO; [self.chrome holdRotationInsets:self.view.safeAreaInsets];
      [self.chrome setNeedsLayout]; [self.chrome layoutIfNeeded]; [self alignVideoOutput];
      CGRect after = [self.movieView convertRect:self.movieView.bounds toView:self.view];
      self.rotationHandoffDelta = MAX(MAX(fabs(before.origin.x-after.origin.x), fabs(before.origin.y-after.origin.y)),
        MAX(fabs(before.size.width-after.size.width), fabs(before.size.height-after.size.height)));
      [NeoPlaybackDiagnostics record:@"ui.rotationHandoff" fields:@{@"delta": @(self.rotationHandoffDelta), @"wide": @(self.landscape)}];
    }];
  }];
  [NeoPlaybackDiagnostics record:@"ui.orientationAnimation" fields:@{@"durationMs": @(self.playerRotationDuration*1000),
    @"systemMs": @(self.systemRotationDuration*1000), @"angle": @(atan2(rotation.b, rotation.a))}];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad ? UIInterfaceOrientationMaskAll : self.orientationMask; }
- (BOOL)shouldAutorotate { return !self.dismissingPlayer; }
- (BOOL)prefersStatusBarHidden { return self.landscape; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersHomeIndicatorAutoHidden { return self.landscape && !self.chrome.controlsVisible; }
- (void)scheduleControlsHide {
  [self.controlsHideTimer invalidate]; self.controlsHideTimer = nil;
  if (self.closing || self.playbackEnded || !self.chrome.controlsVisible || !self.chrome.autoHide) { return; }
  __weak typeof(self) weakSelf = self;
  self.controlsHideTimer = [NSTimer timerWithTimeInterval:2.5 repeats:NO block:^(NSTimer *timer) {
    typeof(self) self = weakSelf;
    if (!self || self.closing) { return; }
    self.controlsHideTimer = nil;
    if (self.playbackEnded || !self.chrome.autoHide) { return; }
    if (self.scrubbing || self.chrome.interactionOpen || self.chrome.controlTracking || self.presentedViewController) {
      [self scheduleControlsHide]; return;
    }
    [self hideControls];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.controlsHideTimer forMode:NSRunLoopCommonModes];
}
- (void)hideControls {
  [self.controlsHideTimer invalidate]; self.controlsHideTimer = nil;
  [self.chrome showControls:NO]; [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)showControls {
  [self.chrome showControls:YES]; [self setNeedsUpdateOfHomeIndicatorAutoHidden];
  [self scheduleControlsHide];
}
- (void)toggleControls {
  if (self.chrome.controlsVisible) { [self hideControls]; }
  else { [self showControls]; }
}
- (void)performPlayerAction:(NSString *)action {
  if (self.closing) { return; }
  if ([action hasPrefix:@"back-"]) {
    if ([action isEqualToString:@"back-begin"]) { [self beginPlayerDismissal:YES]; }
    else if ([action hasPrefix:@"back-progress:"]) { [self.playerTransition updateInteractiveDismissal:[action substringFromIndex:14].doubleValue]; }
    else if ([action isEqualToString:@"back-finish"] || [action isEqualToString:@"back-cancel"]) {
      [self.playerTransition endInteractiveDismissal:[action isEqualToString:@"back-finish"]];
    }
    return;
  }
  if (self.dismissingPlayer) { return; }
  if ([action isEqualToString:@"toggle-controls"]) { [self toggleControls]; return; }
  if ([action isEqualToString:@"orientation-begin"] || [action hasPrefix:@"orientation:"]) {
    [self.chrome clearTransientNotice];
    [self hideControls];
    if ([action hasPrefix:@"orientation:"]) { [self setOrientation:[action substringFromIndex:12]]; }
    return;
  }
  [self showControls];
  if ((self.reloading || self.reloadTimedOut) && ([action hasPrefix:@"jump:"] || [action hasPrefix:@"seekto:"] || [action hasPrefix:@"scrub-"])) { return; }
  if ([action isEqualToString:@"back"]) { [self closePlayer]; }
  else if ([action isEqualToString:@"play"]) { [self togglePlayback]; }
  else if ([action isEqualToString:@"pip"]) { [self startPiP]; }
  else if ([action isEqualToString:@"subtitles"]) { [self showSubtitles]; }
  else if ([action isEqualToString:@"comments-settings"]) { [self showComments]; }
  else if ([action isEqualToString:@"comment-list"]) { [self updateCommentState]; }
  else if ([action isEqualToString:@"scrub-begin"]) { [self beginScrubbing]; }
  else if ([action isEqualToString:@"scrub-end"]) { [self endScrubbing]; }
  else if ([action isEqualToString:@"scrub-cancel"]) { [self cancelScrubbing]; }
  else if ([action isEqualToString:@"reload"]) { [self reloadPlayback]; }
  else if ([action isEqualToString:@"export-diagnostics"]) {
    NSURL *url = [NeoPlaybackDiagnostics exportURL];
    if (url) {
      UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
      share.popoverPresentationController.sourceView = self.chrome;
      share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.chrome.bounds), CGRectGetMidY(self.chrome.bounds), 1, 1);
      [self presentViewController:share animated:YES completion:nil];
    }
  }
  else if ([action isEqualToString:@"rotate"]) { [self setOrientation:self.landscape ? @"portrait" : @"landscape"]; }
  else if ([action hasPrefix:@"orientation:"]) { [self setOrientation:[action substringFromIndex:12]]; }
  else if ([action hasPrefix:@"jump:"]) { [self seekBy:[action substringFromIndex:5].longLongValue * 1000 completion:^{}]; }
  else if ([action hasPrefix:@"seekto:"]) {
    int64_t target = (int64_t)([action substringFromIndex:7].doubleValue * 1000);
    [self seekBy:target - [self mediaTime] completion:^{}];
  } else if ([action hasPrefix:@"rate:"]) {
    self.playbackRate = [action substringFromIndex:5].floatValue; self.player.rate = self.playbackRate;
  } else if ([action hasPrefix:@"cache:"]) { self.networkCaching = MAX(1000, MIN(30000, [action substringFromIndex:6].integerValue * 1000)); }
  else if ([action hasPrefix:@"retention:"]) {
    NSInteger value = [action substringFromIndex:10].integerValue;
    if (self.rewindCache) { [self.rewindCache setSeconds:value]; }
    else { [NSUserDefaults.standardUserDefaults setInteger:value forKey:@"player.rewind.seconds"]; }
  }
  else if ([action isEqualToString:@"streambuffer"] && self.streamingSession) {
    BOOL ts = [self.recordingContext[@"videoFileType"] isEqual:@"ts"];
    NSString *base = [NSString stringWithFormat:@"player.streaming.%@.", ts ? @"ts" : @"encoded"];
    NSInteger ahead = [NSUserDefaults.standardUserDefaults integerForKey:[base stringByAppendingString:@"ahead"]];
    NSInteger rewind = [NSUserDefaults.standardUserDefaults objectForKey:[base stringByAppendingString:@"rewind"]] ? [NSUserDefaults.standardUserDefaults integerForKey:[base stringByAppendingString:@"rewind"]] : (ts ? 10 : 15);
    [self.streamingSession setAhead:ahead ?: 2 rewind:rewind];
    [self reloadPlayback];
  }
  else if ([action hasPrefix:@"quality:"] && [self isStreaming]) {
    NSInteger mode = [action substringFromIndex:8].integerValue;
    NSArray *qualities = self.recordingContext[@"streamQualities"];
    if (self.reloading || mode < 0 || mode >= qualities.count || [qualities[mode] length] == 0 || mode == [self.recordingContext[@"streamMode"] integerValue]) { [self.chrome updateStreamQuality:[self.recordingContext[@"streamMode"] integerValue]]; return; }
    int64_t target = [self mediaTime];
    NSMutableDictionary *context = [self.recordingContext mutableCopy]; context[@"streamMode"] = @(mode); self.recordingContext = context;
    [self.streamingSession close]; self.streamingSession.onChange = nil; self.streamingSession.onTransportFailure = nil; self.streamingSession = nil;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:[@"player.streaming.mode." stringByAppendingString:self.recordingContext[@"videoFileType"]]];
    [self reloadPlaybackAtTime:target completion:nil];
  }
  else if ([action hasPrefix:@"subtitle:"]) {
    self.streamSubtitleUserSelected = YES;
    NSInteger index = [action substringFromIndex:9].integerValue;
    if (index < 0) {
      [NeoSubtitlePreference save:@""]; self.subtitleSignature = nil;
      for (VLCMediaPlayerTrack *track in self.player.textTracks) {
        if (![NeoCommentOverlay isCommentName:track.trackName ?: @""] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) { track.selected = NO; }
      }
    } else if (index < self.player.textTracks.count) {
      VLCMediaPlayerTrack *track = self.player.textTracks[index];
      if (![NeoCommentOverlay isCommentName:track.trackName ?: @""] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) { [NeoSubtitlePreference save:track.trackName ?: @"字幕"]; self.subtitleSignature = nil; [self.player selectTextTracks:@[track]]; }
    }
    [self updateSubtitleSettings];
  } else if ([action hasPrefix:@"navigate:"]) { self.pendingRoute = [action substringFromIndex:9]; [self closePlayer]; }
  else if ([action hasPrefix:@"recording:"]) { self.pendingRecording = [action substringFromIndex:10].integerValue; [self closePlayer]; }
}
- (void)setOrientation:(NSString *)mode {
  NSInteger request = ++self.orientationRequestGeneration;
  [self.chrome clearTransientNotice];
  self.orientationMask = [mode isEqualToString:@"portrait"] ? UIInterfaceOrientationMaskPortrait
    : [mode isEqualToString:@"landscape"] ? UIInterfaceOrientationMaskLandscapeRight : UIInterfaceOrientationMaskAllButUpsideDown;
  BOOL pad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  if (pad && self.internalOrientation && ![mode isEqualToString:@"auto"]) { [self.chrome finishOrientationTransition]; [self applyPlayerLayout:self.view.bounds.size]; }
  if (pad && [mode isEqualToString:@"auto"]) { self.internalOrientation = NO; [self.chrome finishOrientationTransition]; [self applyPlayerLayout:self.view.bounds.size]; }
  [self setNeedsUpdateOfSupportedInterfaceOrientations];
  [self.presentingViewController setNeedsUpdateOfSupportedInterfaceOrientations];
  [self.view.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
  UIWindowScene *scene = self.view.window.windowScene;
  if (!scene) { [self.chrome cancelOrientationPreview]; return; }
  [NeoPlaybackDiagnostics record:@"orientation.request" fields:[self orientationDiagnosticFields]];
  UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:self.orientationMask];
  __weak typeof(self) weakSelf = self;
  [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!weakSelf || weakSelf.orientationRequestGeneration != request || weakSelf.closing || weakSelf.dismissingPlayer) { return; }
      NSMutableDictionary *fields = [[weakSelf orientationDiagnosticFields] mutableCopy];
      fields[@"errorDomain"] = error.domain; fields[@"errorCode"] = @(error.code);
      // Fixed categories avoid exporting OS descriptions that could contain window titles.
      NSString *description = error.localizedDescription.lowercaseString;
      fields[@"reason"] = [description containsString:@"orientation"] ? @"orientationDenied" : [description containsString:@"geometry"] ? @"geometryDenied" : @"other";
      [NeoPlaybackDiagnostics record:@"orientation.denied" fields:fields];
      if (pad && ![mode isEqualToString:@"auto"]) { [weakSelf useInternalOrientation]; }
      else { [weakSelf.chrome cancelOrientationPreview]; [weakSelf.chrome showTransientNotice:@"この表示環境では向きを変更できません。"]; }
    });
  }];
  if (pad && ![mode isEqualToString:@"auto"]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 650*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      if (!weakSelf || weakSelf.orientationRequestGeneration != request || weakSelf.closing || weakSelf.dismissingPlayer || weakSelf.rotatingPlayer || weakSelf.transitionCoordinator) { return; }
      BOOL requestedWide = weakSelf.orientationMask == UIInterfaceOrientationMaskLandscapeRight;
      if (requestedWide != (weakSelf.view.bounds.size.width > weakSelf.view.bounds.size.height) && !weakSelf.internalOrientation) {
        [NeoPlaybackDiagnostics record:@"orientation.notApplied" fields:[weakSelf orientationDiagnosticFields]];
        [weakSelf useInternalOrientation];
      }
    });
  }
}
- (NSDictionary *)orientationDiagnosticFields {
  UIWindowScene *scene = self.view.window.windowScene;
  return @{@"requestedMask": @(self.orientationMask), @"playerMask": @(self.supportedInterfaceOrientations),
    @"hostMask": @(self.view.window.rootViewController.supportedInterfaceOrientations),
    @"sceneOrientation": @(scene.interfaceOrientation), @"windowWidth": @(self.view.bounds.size.width),
    @"windowHeight": @(self.view.bounds.size.height), @"ipad": @(self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad),
    @"contentWidth": @(self.chrome.bounds.size.width), @"contentHeight": @(self.chrome.bounds.size.height),
    @"internal": @(self.internalOrientation), @"osMajor": @(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion)};
}
- (void)useInternalOrientation {
  self.internalOrientation = YES; [self.chrome finishOrientationTransition]; [self.chrome clearTransientNotice];
  [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.22 animations:^{ [self applyPlayerLayout:self.view.bounds.size]; }];
  [NeoPlaybackDiagnostics record:@"orientation.internalApplied" fields:[self orientationDiagnosticFields]];
}
- (void)reloadPlayback {
  if (self.reloading) { return; }
  if (self.pipActive) {
    self.statusLabel.text = @"再読み込み · PiPを閉じてから実行してください。"; [self.chrome updateDiagnostics]; return;
  }
  // An explicit retry starts a new bounded recovery attempt.
  self.videoRecoveryFallbackAttempted = NO; self.videoReloadRecovery = NO;
  [self.videoRecovery reset];
  [self reloadPlaybackAtTime:[self mediaTime] completion:nil];
}
- (void)reloadPlaybackAtTime:(int64_t)time completion:(dispatch_block_t)completion {
  if (self.closing || self.reloading) { if (completion) { completion(); } return; }
  self.networkReloadWaiting = NO; [self.networkRetryTimer invalidate]; self.networkRetryTimer = nil;
  self.tsPositionPending = NO; [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
  self.reloadTimedOut = NO;
  [NeoPlaybackDiagnostics record:@"input.reloadRequested" fields:@{@"targetMs": @(time), @"videoResume": @(self.videoResuming), @"videoRepairStage": @(self.videoRecovery.stage)}];
  [self cancelVideoResume];
  NSInteger generation = ++self.reloadGeneration;
  [self sampleHistory]; [self.history flush];
  self.reloadTime = MAX(0, time); self.reloadPlaying = self.wantsPlayback;
  self.reloadCompletion = completion;
  self.transportSuspended = NO; self.playbackFailed = NO;
  // Prevent a cancelled seek from issuing play/pause to the input being retired.
  self.reloading = YES;
  [self completeSeek:self.seekGeneration failed:YES];
  NSMutableArray *tracks = [NSMutableArray new];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) { if (track.isSelected) { [tracks addObject:track.trackId]; } }
  self.scrubbing = NO; self.reloadTextTracks = tracks; self.reloading = YES; self.restoringReload = NO;
  self.statusLabel.text = @"プレイヤーを再読み込みしています…"; [self.chrome updateDiagnostics];
  [self.commentPiP resetVideo];
  [self armReloadDeadline];
  __weak typeof(self) weakSelf = self;
  if ([self isStreaming]) {
    self.awaitingEndpoint = YES; [self.player stop];
    [self prepareStreamingAt:self.reloadTime/1000.0 completion:^(NSURL *url, NSString *message) {
      if (!weakSelf || weakSelf.closing || !weakSelf.reloading || weakSelf.reloadGeneration != generation) { return; }
      if (!url) {
        weakSelf.statusLabel.text = message; [weakSelf.chrome updateDiagnostics];
        if (weakSelf.streamingSession.retryableFailure) { [weakSelf waitForStreamingNetwork]; }
        else { [weakSelf finishReload:YES]; [weakSelf showControls]; }
        return;
      }
      weakSelf.playbackURL = url; [weakSelf restartInputAfterEndpointReady];
    }];
  } else if (self.rewindCache) {
    self.awaitingEndpoint = YES;
    [self.player stop];
    [self.rewindCache reopen:^(NSURL *url, NSString *message) {
      if (!weakSelf || weakSelf.closing || !weakSelf.reloading || weakSelf.reloadGeneration != generation) { return; }
      weakSelf.playbackURL = url ?: weakSelf.sourceURL;
      if (!url) { weakSelf.statusLabel.text = message; }
      [weakSelf restartInputAfterEndpointReady];
    }];
  } else { [self restartInputAfterEndpointReady]; }
}
- (void)updateLoadingState {
  NSString *message = nil;
  if (!self.closing && !self.playbackEnded && !self.playbackFailed) {
    if (self.awaitingComments) { message = self.comments.preparationStage.length ? self.comments.preparationStage : @"コメントを準備中"; }
    else if (self.networkReloadWaiting) { message = @"通信の復帰を待機中"; }
    else if (self.reloading || self.transportSuspended) { message = @"再接続中"; }
    else if (self.repairingVideo || self.videoReloadRecovery) { message = @"映像を復旧中"; }
    else if (self.seeking || self.awaitingSeekVideo || self.tsPositionPending) { message = @"シーク先を読み込み中"; }
    else if (self.networkFlow.holding) { message = @"通信を待機中"; }
    else if (self.networkFlow.verifying) { message = @"映像を再開中"; }
    else if (self.awaitingEndpoint || self.player.state == VLCMediaPlayerStateOpening ||
      (self.wantsPlayback && self.commentPiP.capturedFrameCount == 0)) { message = @"動画を読み込み中"; }
  }
  if (self.playbackEnded || self.playbackFailed || self.closing) { [self.chrome updateBuffering:NO progress:1]; }
  [self.chrome updateLoading:message];
}
- (void)checkVideoRecovery {
  if (self.networkReloadWaiting) { return; }
  NSTimeInterval now = CACurrentMediaTime();
  if (self.videoReloadRecovery && !self.reloading && !self.inputInBackground) {
    NSDictionary *stats = [NeoVLCFrameTap snapshot:self.movieView];
    VLCMediaPlayerState state = self.player.state;
    BOOL positioned = self.wantsPlayback || llabs([self mediaTime]-self.reloadTime) < 1000;
    BOOL fresh = [stats[@"outputID"] integerValue] > 0 && [stats[@"outputID"] integerValue] != self.videoResumeOldOutput &&
      [stats[@"samples"] integerValue] > 0 && ![stats[@"resourceInterrupted"] boolValue] &&
      [stats[@"layerStatus"] integerValue] != AVQueuedSampleBufferRenderingStatusFailed &&
      stats[@"scheduledInMs"] && fabs([stats[@"scheduledInMs"] doubleValue]) < 500;
    if (self.wantsPlayback) {
      VLCMediaStats native = self.player.media.statistics;
      uint64_t decoded = native.decodedVideo >= self.restoreDecoded ? native.decodedVideo-self.restoreDecoded : 0;
      uint64_t lost = native.lostPictures >= self.restoreLost ? native.lostPictures-self.restoreLost : 0;
      // Repeated paused/black pictures may have fresh host timestamps while
      // every newly decoded picture is dropped. Static scenes remain valid.
      fresh = fresh && decoded >= 3 && lost*2 < decoded;
    }
    if ((state == VLCMediaPlayerStatePlaying || state == VLCMediaPlayerStatePaused) && positioned && fresh) {
      self.videoReloadRecovery = NO; self.repairingVideo = NO; self.awaitingSeekVideo = NO;
      [self releaseRestoreMute];
      [self resetNetworkFlow];
      [self.videoRecovery reset]; self.videoWatchPending = YES;
      [NeoPlaybackDiagnostics record:@"video.reloadConfirmed" fields:@{@"mediaMs": @([self mediaTime]), @"paused": @(!self.wantsPlayback)}];
      [self updateLoadingState];
    } else if (now >= self.videoReloadDeadline) { [self failVideoRecovery]; return; }
    else { return; }
  }
  BOOL selectedVideo = NO;
  for (VLCMediaPlayerTrack *track in self.player.videoTracks) { selectedVideo |= track.isSelected; }
  if (!selectedVideo || self.closing || self.inputInBackground || self.pipActive || self.reloading || self.tsPositionPending || self.videoResuming || self.seeking ||
      self.buffering || self.networkFlow.holding || !self.wantsPlayback || !self.player.isPlaying) {
    [self.videoRecovery hold:now]; return;
  }
  if (self.videoWatchPending) {
    self.videoWatchPending = NO;
    if (!self.videoRecovery) { self.videoRecovery = [NeoVideoRecovery new]; }
    [self.videoRecovery begin:now timeout:self.networkCaching/1000.0+10];
    [NeoVLCFrameTap monitorContent:self.movieView];
  }
  NSMutableDictionary *stats = [[NeoVLCFrameTap snapshot:self.movieView] mutableCopy];
  VLCMediaStats health = self.player.media.statistics;
  stats[@"nativeDecoded"] = @(health.decodedVideo); stats[@"nativeLost"] = @(health.lostPictures);
  if (self.flowDecodedAt > 0 && (![((self.streamingSession ? self.streamingSession.flowState : self.rewindCache.flowState))[@"waiting"] boolValue] || now-self.flowAudioAt < 1.5)) {
    stats[@"nativeDecodeAge"] = @(now-self.flowDecodedAt);
    stats[@"nativeDecodeStaleAfter"] = @(MAX(8, self.flowStaleThreshold));
  }
  NSInteger outputID = [stats[@"outputID"] integerValue];
  if (outputID != self.lastVideoOutputID) {
    self.lastVideoOutputID = outputID;
    NSMutableDictionary *fields = [stats mutableCopy] ?: [NSMutableDictionary new];
    fields[@"mediaMs"] = @([self mediaTime]); fields[@"outputID"] = @(outputID);
    [NeoPlaybackDiagnostics record:@"video.outputChanged" fields:fields];
  }
  NSInteger action = [self.videoRecovery evaluate:stats ?: @{} mediaMs:[self mediaTime] now:now];
  if (!action) { return; }
  NSMutableDictionary *fields = [stats mutableCopy] ?: [NSMutableDictionary new];
  VLCMediaStats native = self.player.media.statistics;
  fields[@"decodedVideo"] = @(native.decodedVideo); fields[@"displayedPictures"] = @(native.displayedPictures);
  fields[@"lostPictures"] = @(native.lostPictures); fields[@"stage"] = @(self.videoRecovery.stage);
  fields[@"action"] = @(action); fields[@"mediaMs"] = @([self mediaTime]);
  [NeoPlaybackDiagnostics record:action == 1 ? @"video.recoveryConfirmed" : action == 5 ? @"video.recoveryFailed" : @"video.repair" fields:fields];
  if (action == 1 || action == 5) {
    self.repairingVideo = NO;
    if (action == 1) { [self resetNetworkFlow]; }
    if (action == 5) { [self failVideoRecovery]; }
    return;
  }
  self.repairingVideo = YES;
  [NeoVLCFrameTap monitorContent:self.movieView];
  if (action == 2) { [NeoVLCFrameTap flushVideoQueue:self.movieView]; [self alignVideoOutput]; return; }
  if (action == 4) {
    // A bounded fallback only after the output repair failed verification.
    self.videoResumeTime = [self mediaTime]; [self fallbackVideoResume:4]; return;
  }
  [self rebuildVideoAtCurrentPosition];
}
// Replace only the video decoder/output after iOS revoked its resources.
// Deselect/select are asynchronous: wait for the old output to be removed,
// rather than selecting again after an arbitrary 200 ms delay. The paused
// position seek feeds a keyframe into the fresh decoder without opening HTTP
// or playing the beginning of the file. Audio, demux and cache stay intact.
- (void)rebuildVideoAtCurrentPosition {
  if (self.videoResuming || self.closing || self.reloading || self.inputInBackground || self.pipActive) { return; }
  VLCMediaPlayerTrack *selected = nil;
  for (VLCMediaPlayerTrack *track in self.player.videoTracks) { if (track.isSelected) { selected = track; break; } }
  if (!selected || !self.player.isSeekable) { return; }
  // Read the retained paused position before enabling the repair path, which
  // intentionally bypasses the ordinary paused-clock guard.
  int64_t retained = [self mediaTime];
  if ([self wholeFileClock]) {
    // A TS byte seek after reselecting only paused video can leave the audio
    // master clock anchored to the pre-suspension host date. On play it skips
    // the paused interval. Recreate the damaged input once at the retained
    // position so audio/video share a fresh clock; healthy pauses keep input.
    self.videoResumeTime = retained;
    self.videoResumeOldOutput = [[NeoVLCFrameTap snapshot:self.movieView][@"outputID"] integerValue];
    [NeoPlaybackDiagnostics record:@"video.tsClockReopen" fields:@{@"targetMs": @(retained)}];
    [self fallbackVideoResume:5]; return;
  }
  self.videoResuming = YES; self.repairingVideo = YES;
  self.videoResumeMedia = self.player.media; self.videoResumeTrack = selected.trackId;
  self.videoResumeTime = retained; self.videoResumeStage = 0; self.videoResumeSeekFinished = NO;
  self.videoResumeOldOutput = [[NeoVLCFrameTap snapshot:self.movieView][@"outputID"] integerValue];
  NSInteger generation = ++self.videoResumeGeneration;
  self.videoResumeDeadline = CACurrentMediaTime()+4;
  [NeoPlaybackDiagnostics record:@"video.resumeRebuild" fields:@{@"mediaMs": @(self.videoResumeTime), @"outputID": @(self.videoResumeOldOutput), @"wantsPlayback": @(self.wantsPlayback)}];
  [self.player pause]; selected.selected = NO;
  [self updateLoadingState];
  [self pollVideoResume:generation];
}
- (void)pollVideoResume:(NSInteger)generation {
  if (!self.videoResuming || self.videoResumeGeneration != generation || self.closing ||
      self.inputInBackground || self.player.media != self.videoResumeMedia || self.reloading) { return; }
  VLCMediaPlayerState state = self.player.state;
  if (state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError) {
    [self fallbackVideoResume:state == VLCMediaPlayerStateStopped ? 1 : 2]; return;
  }
  NSDictionary *stats = [NeoVLCFrameTap snapshot:self.movieView];
  VLCMediaPlayerTrack *target = nil; BOOL anySelected = NO;
  for (VLCMediaPlayerTrack *track in self.player.videoTracks) {
    anySelected |= track.isSelected;
    if ([track.trackId isEqual:self.videoResumeTrack]) { target = track; }
  }
  if (CACurrentMediaTime() >= self.videoResumeDeadline) {
    [NeoPlaybackDiagnostics record:@"video.resumeTimeout" fields:@{@"stage": @(self.videoResumeStage), @"mediaMs": @(self.videoResumeTime)}];
    [self fallbackVideoResume:0]; return;
  }
  if (self.videoResumeStage == 0 && !anySelected && [stats[@"outputID"] integerValue] == 0 && target) {
    self.videoResumeStage = 1; target.selected = YES;
    [NeoPlaybackDiagnostics record:@"video.resumeOutputRetired" fields:@{@"outputID": @(self.videoResumeOldOutput)}];
  } else if (self.videoResumeStage == 1 && target.isSelected && self.player.state == VLCMediaPlayerStatePaused) {
    self.videoResumeStage = 2; self.videoResumeDeadline = CACurrentMediaTime()+10;
    self.videoResumePriming = YES;
    __weak typeof(self) weakSelf = self;
    [self seekBy:self.videoResumeTime-[self mediaTime] completion:^{
      if (!weakSelf.videoResuming || weakSelf.videoResumeGeneration != generation) { return; }
      weakSelf.videoResumeSeekFinished = !weakSelf.lastSeekFailed;
      if (weakSelf.lastSeekFailed) { [weakSelf fallbackVideoResume:3]; }
    }];
    self.videoResumePriming = NO;
#if TARGET_OS_SIMULATOR
    // Reproduce a terminal native input immediately after the priming seek.
    if (self.smokeStopVideoResume) { self.smokeStopVideoResume = NO; [self.player stop]; }
#endif
  } else if (self.videoResumeStage == 2 && self.videoResumeSeekFinished &&
      [stats[@"outputID"] integerValue] > 0 && [stats[@"outputID"] integerValue] != self.videoResumeOldOutput &&
      [stats[@"samples"] integerValue] > 0 && ![stats[@"resourceInterrupted"] boolValue] &&
      [stats[@"scheduledInMs"] doubleValue] >= -500 && [stats[@"scheduledInMs"] doubleValue] <= 100 &&
      llabs(([self wholeFileClock]
        ? self.player.nativeTimeMs : self.inputStartTime+self.player.time.value.longLongValue)-self.videoResumeTime) < 2000 &&
      [stats[@"layerStatus"] integerValue] != AVQueuedSampleBufferRenderingStatusFailed) {
    NSNumber *deferred = self.videoResumeDeferredTime;
    dispatch_block_t completion = self.videoResumeDeferredCompletion; self.videoResumeDeferredCompletion = nil;
    NSMutableDictionary *fields = [stats mutableCopy];
    fields[@"mediaMs"] = @([self mediaTime]); fields[@"decodedVideo"] = @(self.player.media.statistics.decodedVideo);
    fields[@"sameInput"] = @(self.player.media == self.videoResumeMedia);
    [NeoPlaybackDiagnostics record:@"video.resumePrepared" fields:fields];
    [self cancelVideoResume]; self.repairingVideo = NO; self.videoWatchPending = YES;
    [self alignVideoOutput]; [self applyPlaybackIntentForced:YES]; [self updateLoadingState];
    if (deferred) { [self seekBy:deferred.longLongValue-[self mediaTime] completion:completion ?: ^{}]; }
    return;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf pollVideoResume:generation]; });
}
- (void)cancelVideoResume {
  self.videoResumeGeneration++; self.videoResuming = NO; self.videoResumePriming = NO;
  self.repairingVideo = NO;
  self.videoResumeMedia = nil; self.videoResumeTrack = nil; self.videoResumeDeferredTime = nil;
  dispatch_block_t completion = self.videoResumeDeferredCompletion; self.videoResumeDeferredCompletion = nil;
  if (completion) { completion(); }
}
- (void)fallbackVideoResume:(NSInteger)reason {
  if (self.closing || self.reloading) { return; }
  if (self.videoRecoveryFallbackAttempted) { [self failVideoRecovery]; return; }
  int64_t time = self.videoResumeDeferredTime ? self.videoResumeDeferredTime.longLongValue : self.videoResumeTime;
  dispatch_block_t completion = self.videoResumeDeferredCompletion; self.videoResumeDeferredCompletion = nil;
  [NeoPlaybackDiagnostics record:@"video.resumeFallback" fields:@{@"reason": @(reason), @"stage": @(self.videoResumeStage),
    @"targetMs": @(time), @"wantsPlayback": @(self.wantsPlayback), @"state": @(self.player.state)}];
  self.videoRecoveryFallbackAttempted = YES; self.videoReloadRecovery = YES;
  [self reloadPlaybackAtTime:time completion:completion];
}
- (void)failVideoRecovery {
  [self releaseRestoreMute];
  [NeoPlaybackDiagnostics record:@"video.resumeFailed" fields:@{@"mediaMs": @([self mediaTime]), @"state": @(self.player.state)}];
  [self cancelVideoResume]; self.videoReloadRecovery = NO; self.awaitingSeekVideo = NO;
  [self.videoRecovery reset]; self.videoWatchPending = NO;
  self.playbackFailed = YES; [self setPlaybackIntent:NO];
  if (self.player.state == VLCMediaPlayerStatePlaying) { [self.player pause]; }
  self.statusLabel.text = @"映像を復旧できませんでした。再読み込みをお試しください。";
  [self updateLoadingState]; [self.chrome updateDiagnostics]; [self showControls];
}
- (void)startWhenCommentsReady {
  if (self.closing || self.transportSuspended || self.reloading) { return; }
  if (![NeoCommentOverlay waitBeforePlayback] || !self.comments.enabled) { [self restartMedia]; return; }
  self.awaitingComments = YES; [self updateLoadingState]; self.statusLabel.text = @"コメントを準備しています…";
  __weak typeof(self) weakSelf = self;
  [self.comments prepareBeforePlayback:^{
    if (!weakSelf || weakSelf.closing) { return; }
    weakSelf.awaitingComments = NO; [weakSelf updateLoadingState];
    if (!weakSelf.transportSuspended && !weakSelf.reloading) { [weakSelf restartMedia]; }
  }];
}
- (void)restartInputAfterEndpointReady {
  if (self.closing) { return; }
  self.awaitingEndpoint = NO;
  if (self.player.state == VLCMediaPlayerStateStopped || self.player.state == VLCMediaPlayerStateNothingSpecial) { [self restartMedia]; }
  else { [self.player stop]; }
}
- (void)restartMedia {
  [NeoVLCFrameTap clearARIBView:self.movieView];
  [self resetNetworkFlow];
  self.flowDecodedVideo = 0; self.flowDecodedAt = 0;
  self.flowPlayedAudio = 0; self.flowAudioAt = 0;
  self.videoWatchPending = YES;
  // Opening the replacement input is asynchronous. An older Stopped event
  // must not open it again while start-paused is still preparing it.
  if (self.reloading && self.restoringReload) { return; }
  self.restoringReload = self.reloading;
  self.reloadTimedOut = NO;
  self.playbackEnded = NO; self.playbackFailed = NO; self.buffering = NO;
  self.inputBufferReady = NO; self.hasInputLength = NO; self.lastIntentCommandAt = 0;
  [self.chrome updateBuffering:NO progress:1];
  [NeoPlaybackDiagnostics record:@"input.restart" fields:@{@"restoring": @(self.reloading), @"targetMs": @(self.reloadTime)}];
  self.subtitleSignature = nil; self.attachedSubtitles = nil;
  int64_t target = self.reloading ? self.reloadTime : (int64_t)llround(self.initialPosition * 1000);
  // TS positions and PCR-derived times refer to the whole recording. A
  // start-time option is not a new relative time origin, and HTTP TS may reject
  // that option entirely when its duration is unknown. Open paused, then seek
  // against the whole file; never add the requested target to VLC's clock.
  BOOL ts = [self wholeFileClock];
  self.inputStartTime = ts ? 0 : target;
  [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
  self.tsPositionPending = (ts && target > 0) || [self isStreaming];
  self.videoOutputView.hidden = self.tsPositionPending;
  self.tsPositionIssued = NO; self.tsPositionCallback = NO; self.tsPositionTarget = target;
  self.tsPositionWaitForPause = NO; self.tsPositionResumeAt = -100;
  self.initialPosition = 0;
  self.invalidClockReported = NO;
  self.inputClockGuardUntil = ts ? 0 : CACurrentMediaTime()+3;
  self.lastObservedTime = target; [self armStreamingClockAt:target];
  [self.rewindCache beginSeek:target / 1000.0]; [self.streamingSession beginSeek:target / 1000.0];
  if (self.reloading || self.tsPositionPending) { [self.comments beginSeek:target / 1000.0]; }
  VLCMedia *media = [VLCMedia mediaWithURL:self.playbackURL ?: self.sourceURL];
#if TARGET_OS_SIMULATOR
  // Select the fixture's known track before the first PES, not by resetting
  // a running subtitle decoder after asynchronous track discovery.
  if ([NSProcessInfo.processInfo.environment[@"NEO_EPG_ARIB_PROBE"] isEqual:@"1"]) { [media addOption:@":sub-track=0"]; }
#endif
  // Ordinary HTTP reports CAN_FASTSEEK=false. The default MKV demuxer may
  // consequently reject unverified Cues and fall back to the first cluster.
  // Opt in only after parsing video Cues and checking their file positions.
  if (self.rewindCache.hasMatroskaSeekIndex && self.playbackURL) {
    [media addOption:@":demux=mkv_trusted"];
    [NeoPlaybackDiagnostics record:@"mkv.indexSeek" fields:@{@"targetMs": @(self.inputStartTime),
      @"expectedOffset": @([self.rewindCache matroskaSeekOffset:self.inputStartTime/1000.0])}];
  }
  [media addOption:[NSString stringWithFormat:@":network-caching=%ld", (long)self.networkCaching]];
  if ([self isStreaming]) {
    [media addOption:[NSString stringWithFormat:@":adaptive-maxbuffer=%ld", (long)self.networkCaching]];
  }
  if (self.inputStartTime > 0) {
    [media addOption:[NSString stringWithFormat:@":start-time=%.3f", self.inputStartTime / 1000.0]];
  }
  // Initialise at the requested position, paused. Never play the beginning
  // to prepare a later seek, including when the user wants playback resumed.
  BOOL pausedStart = ![self isStreaming] && (self.reloading || self.tsPositionPending);
  if (pausedStart) { [media addOption:@":start-paused"]; }
  if ([self isStreaming]) {
    if (!self.restoreMuted) { self.restorePreviousMute = self.player.audio.isMuted; self.restoreMuted = YES; }
    self.player.audio.muted = YES;
  }
  [NeoPlaybackDiagnostics record:@"input.startPosition" fields:@{@"targetMs": @(target),
    @"paused": @(pausedStart), @"absoluteTS": @(ts)}];
  self.player.media = media; [self.player play];
  if (self.tsPositionPending) { [self armTSPosition]; }
}
- (void)armTSPosition {
  [self.tsPositionTimer invalidate];
  self.tsPositionDeadline = CACurrentMediaTime()+20;
  self.tsPositionLastDiagnostic = CACurrentMediaTime();
  __weak typeof(self) weakSelf = self;
  self.tsPositionTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { [weakSelf advanceTSPosition]; }];
  [NSRunLoop.mainRunLoop addTimer:self.tsPositionTimer forMode:NSRunLoopCommonModes];
  [self observeSeekFrames];
  // The timer is a watchdog, not a 100ms debounce before sending the seek.
  [self advanceTSPosition];
}
- (void)observeSeekFrames {
  __weak typeof(self) weakSelf = self;
  VLCMedia *media = self.player.media;
  NSInteger generation = self.seekGeneration;
  [NeoVLCFrameTap bindFrameArrival:self.movieView handler:^{
    if (!weakSelf || weakSelf.closing || weakSelf.player.media != media || weakSelf.seekGeneration != generation) { return; }
    if (weakSelf.tsPositionPending) { [weakSelf advanceTSPosition]; }
    [weakSelf updateSeekVideoReady];
  }];
}
- (void)updateSeekVideoReady {
  if (self.awaitingSeekVideo && !self.seeking && !self.buffering && self.commentPiP.videoPresentationHostTime > self.seekStartedAt) {
    self.awaitingSeekVideo = NO;
    [NeoPlaybackDiagnostics record:@"seek.videoResume" fields:@{@"mediaMs": @([self mediaTime]),
      @"durationMs": @((CACurrentMediaTime()-self.seekStartedAt)*1000)}];
    [self updateLoadingState];
  }
  if (!self.awaitingSeekVideo && !self.tsPositionPending) { [NeoVLCFrameTap bindFrameArrival:self.movieView handler:nil]; }
}
- (void)advanceTSPosition {
  if (!self.tsPositionPending || self.closing) {
    [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil; [NeoVLCFrameTap bindFrameArrival:self.movieView handler:nil]; return;
  }
  if (CACurrentMediaTime() > self.tsPositionDeadline) {
    self.tsPositionPending = NO; [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
    [NeoVLCFrameTap bindFrameArrival:self.movieView handler:nil];
    [NeoPlaybackDiagnostics record:@"ts.positionFailed" fields:@{@"targetMs": @(self.tsPositionTarget),
      @"nativeMs": @(self.player.time.value.longLongValue), @"issued": @(self.tsPositionIssued)}];
    if (self.seeking) { [self completeSeek:self.seekGeneration failed:YES]; return; }
    if (self.reloading) { [self finishReload:YES]; }
    else { self.playbackFailed = YES; [self setPlaybackIntent:NO]; [self.comments endSeek]; }
    self.statusLabel.text = @"再生位置を復元できませんでした。再読み込みで再試行してください。";
    [self.chrome updateDiagnostics]; [self updateLoadingState]; [self showControls]; return;
  }
  if ([self isStreaming]) {
    // set_time is synchronous at the wrapper boundary, whereas pause/play are
    // queued. Wait for an actual pause acknowledgement before priming a paused
    // seek, then for Playing before issuing it. A cached seek followed at once
    // by pause+seek must not let the earlier pause stop the new preparation.
    if (self.tsPositionWaitForPause) {
      if (self.player.state != VLCMediaPlayerStatePaused) { return; }
      self.tsPositionWaitForPause = NO;
    }
    if (self.player.state == VLCMediaPlayerStatePaused) {
      if (CACurrentMediaTime()-self.tsPositionResumeAt >= 0.25) {
        self.tsPositionResumeAt = CACurrentMediaTime();
        [NeoPlaybackDiagnostics record:@"ts.positionPrimeResume" fields:@{@"targetMs": @(self.tsPositionTarget)}];
        [self.player play];
      }
      return;
    }
  }
  if (!self.tsPositionIssued) {
    int64_t length = [self mediaLength];
    BOOL stateReady = self.player.state == VLCMediaPlayerStatePaused ||
      (([self isStreaming] || self.seeking) && self.player.state == VLCMediaPlayerStatePlaying);
    if (!self.inputBufferReady || self.buffering || !stateReady || !self.player.isSeekable || length <= 0) { return; }
    BOOL bytes = ![self isStreaming] && !self.hasInputLength && self.player.media.length.value.longLongValue <= 0;
    if (bytes && !self.seeking) {
      // Opening announces Paused before MPEG-2's first picture/PCR origin is
      // established. A byte seek at that point can anchor several seconds off.
      // Observe the first real sample, not an arbitrary startup delay. Normal
      // seeks retain their already-established input and take the fast path.
      NSDictionary *initial = [NeoVLCFrameTap snapshot:self.movieView];
      if ([initial[@"samples"] unsignedIntegerValue] == 0) { return; }
    }
    // Adaptive HLS does not output the target picture while start-paused.
    // Decode invisibly/muted at the requested time until a real due frame
    // arrives. Keep the user's playback intent separate from this preparation.
    self.tsPositionIssued = YES;
    self.tsPositionSequence = [self.player.observedClock[@"sequence"] unsignedLongLongValue];
    self.tsPositionDecoded = self.player.media.statistics.decodedVideo;
    NSDictionary *output = [NeoVLCFrameTap snapshot:self.movieView];
    self.tsPositionSamples = [output[@"samples"] unsignedIntegerValue];
    self.tsPositionOutputID = [output[@"outputID"] unsignedIntegerValue];
    __weak typeof(self) weakSelf = self;
    VLCMedia *media = self.player.media;
    self.player.onSeekCompletion = ^{
      if (weakSelf.player.media != media || !weakSelf.tsPositionPending) { return; }
      weakSelf.tsPositionCallback = YES;
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf advanceTSPosition]; });
    };
    [NeoPlaybackDiagnostics record:@"ts.positionRequested" fields:@{@"targetMs": @(self.tsPositionTarget), @"lengthMs": @(length), @"bytes": @(bytes)}];
    if (self.seeking) {
      [NeoPlaybackDiagnostics record:@"seek.issued" fields:@{@"targetMs": @(self.tsPositionTarget),
        @"afterMs": @((CACurrentMediaTime()-self.seekStartedAt)*1000)}];
    }
    if (bytes) { self.player.position = (double)self.tsPositionTarget/length; }
    else { self.player.time = [VLCTime timeWithInt:(int)self.tsPositionTarget]; }
    return;
  }
  // A seek notification alone is not proof of arrival. Read LibVLC's native
  // pause-aware clock and require fresh decoded/due video. A paused same-position
  // repair need not publish another watcher point: its timestamp is unchanged.
  NSDictionary *clock = [(NeoObservedMediaPlayer *)self.player observedClock];
  int64_t native = self.player.nativeTimeMs;
  NSDictionary *video = [NeoVLCFrameTap snapshot:self.movieView];
  if (CACurrentMediaTime()-self.tsPositionLastDiagnostic >= 2) {
    self.tsPositionLastDiagnostic = CACurrentMediaTime();
    [NeoPlaybackDiagnostics record:@"ts.positionWaiting" fields:@{@"targetMs": @(self.tsPositionTarget), @"nativeMs": @(native),
      @"point": clock, @"decoded": @(self.player.media.statistics.decodedVideo), @"baselineDecoded": @(self.tsPositionDecoded),
      @"samples": video[@"samples"] ?: @0, @"callback": @(self.tsPositionCallback), @"seeking": @(self.player.isSeeking)}];
  }
  BOOL replacedOutput = [video[@"outputID"] unsignedIntegerValue] != self.tsPositionOutputID;
  BOOL newSample = replacedOutput ? [video[@"samples"] unsignedIntegerValue] > 0 : [video[@"samples"] unsignedIntegerValue] > self.tsPositionSamples;
  if (!self.tsPositionCallback || self.player.isSeeking ||
      self.player.media.statistics.decodedVideo <= self.tsPositionDecoded || !newSample ||
      native < 0 || llabs(native-self.tsPositionTarget) > 2000 ||
      [video[@"scheduledInMs"] doubleValue] < -500 || [video[@"scheduledInMs"] doubleValue] > 100 ||
      [video[@"layerStatus"] integerValue] == AVQueuedSampleBufferRenderingStatusFailed) { return; }
  [NeoPlaybackDiagnostics record:@"ts.positionReady" fields:@{@"targetMs": @(self.tsPositionTarget), @"nativeMs": @(native),
    @"nativeClockConfirmed": @YES, @"newVideo": @YES, @"outputChanged": @(replacedOutput),
    @"newWatcherPoint": @([clock[@"sequence"] unsignedLongLongValue] > self.tsPositionSequence)}];
  self.tsPositionPending = NO; [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
  if (!self.awaitingSeekVideo) { [NeoVLCFrameTap bindFrameArrival:self.movieView handler:nil]; }
  [self armStreamingClockAt:self.tsPositionTarget];
  self.lastObservedTime = [self guardStreamingTime:native];
  if ([self isStreaming]) {
    if (self.reloading || !self.wantsPlayback) { [self.player pause]; }
    else if (!self.videoReloadRecovery) { [self releaseRestoreMute]; }
  }
  self.videoOutputView.hidden = NO;
  if (self.seeking) { [self completeSeek:self.seekGeneration failed:NO]; }
  if (self.reloading) { [self restoreReloadIfReady]; }
  else { [self.comments endSeek]; [self applyPlaybackIntentForced:YES]; [self updateLoadingState]; }
}
- (void)finishReload:(BOOL)failed {
  if (failed) { self.tsPositionPending = NO; [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil; }
  self.reloading = NO; self.restoringReload = NO;
  self.reloadTimedOut = NO;
  self.inputClockGuardUntil = [self wholeFileClock] ? 0 : CACurrentMediaTime()+3;
  [self.reloadTimer invalidate]; self.reloadTimer = nil;
  self.lastSeekFailed = failed;
  self.repairingVideo = NO; self.awaitingSeekVideo = NO;
  [self.comments endSeek];
  if (failed) {
    [self releaseRestoreMute];
    self.videoReloadRecovery = NO; self.playbackFailed = YES; [self setPlaybackIntent:NO];
    if (self.player.state == VLCMediaPlayerStatePlaying) { [self.player pause]; }
  }
  else {
    if (self.videoReloadRecovery) {
      self.videoReloadDeadline = CACurrentMediaTime()+MAX(8, self.networkCaching/1000.0+5);
      VLCMediaStats native = self.player.media.statistics;
      self.restoreDecoded = native.decodedVideo; self.restoreLost = native.lostPictures;
      if (!self.restoreMuted) { self.restorePreviousMute = self.player.audio.isMuted; self.restoreMuted = YES; }
      self.player.audio.muted = YES;
    }
    self.transportRecoveryAttempted = NO;
    if ([self isStreaming] && !self.videoReloadRecovery) { [self releaseRestoreMute]; }
    [self.player deselectAllTextTracks];
    for (VLCMediaPlayerTrack *track in self.player.textTracks) {
      if ([self.reloadTextTracks containsObject:track.trackId]) { track.selected = YES; }
    }
    if (fabs(self.player.rate-self.playbackRate) > 0.001) { self.player.rate = self.playbackRate; }
    [self applyPlaybackIntentForced:YES];
    self.statusLabel.text = self.wantsPlayback ? @"PLAY · 再生中" : @"PLAY · 一時停止";
  }
  dispatch_block_t completion = self.reloadCompletion; self.reloadCompletion = nil;
  [self.commentPiP invalidatePlaybackState];
  [self updateLoadingState];
  if (completion) { completion(); }
}
- (void)restoreReloadIfReady {
  VLCMediaPlayerState state = self.player.state;
  if (self.reloading && !self.restoringReload) { return; }
  if ((!self.reloading && !self.reloadTimedOut) || self.tsPositionPending || self.awaitingEndpoint || !self.inputBufferReady || self.buffering ||
      state != VLCMediaPlayerStatePaused) { return; }
  // Encoded inputs use start-time; TS inputs must confirm their separate
  // whole-file seek before reaching this point.
  // Opening also announces Playing before start-paused takes effect. Wait
  // for that initial pause before applying the user's latest playback intent.
  [NeoPlaybackDiagnostics record:@"input.restoreReady" fields:@{@"targetMs": @(self.reloadTime),
    @"mediaMs": @([self mediaTime]), @"bufferReady": @(self.inputBufferReady), @"wantsPlayback": @(self.wantsPlayback)}];
  // A deadline does not invalidate a healthy input still finishing decoder
  // preparation. Its late initial pause is reusable, including explicit play.
  self.playbackFailed = NO;
  [self finishReload:NO];
}
- (void)togglePlayback { [self showControls]; [self setPlaybackIntent:!self.wantsPlayback]; }
- (void)setPlaybackIntent:(BOOL)playing {
  [self sampleHistory]; [self.history flush];
  if ([self isStreaming] && playing && !self.wantsPlayback && !self.reloading && !self.tsPositionPending) { [self armStreamingClockAt:[self mediaTime]]; }
  self.wantsPlayback = playing;
  if (self.networkReloadWaiting) { [self updateLoadingState]; [self updateNowPlaying]; return; }
  [NeoPlaybackDiagnostics record:@"playback.intent" fields:@{@"playing": @(playing), @"reloading": @(self.reloading)}];
  [self.commentPiP updateAutomaticPlayback];
  if (self.reloadTimedOut && self.player.state != VLCMediaPlayerStateStopped && self.player.state != VLCMediaPlayerStateError) {
    [self restoreReloadIfReady];
    if (self.reloadTimedOut) {
      if (playing) {
        self.reloading = YES; self.reloadTimedOut = NO; self.playbackFailed = NO;
        self.restoringReload = YES; [self.comments beginSeek:self.reloadTime/1000.0]; [self armReloadDeadline];
        [self updateLoadingState];
      }
      [self updateControls]; return;
    }
  }
  if (!self.reloading && !self.awaitingComments && !self.awaitingEndpoint && playing &&
      (self.transportSuspended || self.playbackEnded || self.playbackFailed || self.player.state == VLCMediaPlayerStateStopped)) {
    if (self.playbackEnded) {
      self.backgroundPositionValid = NO; self.lastObservedTime = 0;
      [self.rewindCache beginSeek:self.initialPosition];
      if (!self.awaitingComments && !self.reloading) { [self restartMedia]; }
    } else { [self reloadPlaybackAtTime:MAX(self.lastObservedTime, self.backgroundPositionValid ? self.backgroundTime : 0) completion:nil]; }
  } else { [self applyPlaybackIntentForced:YES]; }
  [self.commentPiP invalidatePlaybackState]; [self updateControls]; [self scheduleControlsHide];
}
- (void)applyPlaybackIntent {
  [self applyPlaybackIntentForced:NO];
}
- (void)applyPlaybackIntentForced:(BOOL)force {
  if (self.closing || self.reloading || self.networkReloadWaiting || self.tsPositionPending || self.videoResuming || self.playbackEnded || self.playbackFailed) { return; }
  // Buffering/seek callbacks can arrive after EOF. Only reconcile an active
  // input; starting a stopped input belongs to an explicit play/reload action.
  if (self.player.state != VLCMediaPlayerStatePlaying && self.player.state != VLCMediaPlayerStatePaused) { return; }
  // An input blocked in HTTP cannot process pause until the read returns.
  // Do not queue automatic pause/play pairs around that blocked operation.
  BOOL playing = self.wantsPlayback;
  if (!force && self.player.isPlaying == playing) { return; }
  NSTimeInterval now = CACurrentMediaTime();
  if (!force && self.lastIssuedIntent == playing && now-self.lastIntentCommandAt < 1) { return; }
  self.lastIssuedIntent = playing; self.lastIntentCommandAt = now;
  [NeoPlaybackDiagnostics record:@"playback.command" fields:@{@"playing": @(playing), @"forced": @(force),
    @"nativePlaying": @(self.player.isPlaying), @"state": @(self.player.state), @"reload": @(self.reloadGeneration)}];
  // VLC enqueues play/pause on its own serial queue. A preceding pause may
  // still be pending even when isPlaying is true. Explicit intent must always
  // enqueue the final command behind it, including paused reload completion.
  if (playing) { [self.player play]; } else { [self.player pause]; }
}
- (void)sampleHistory {
  [self.history sample:self.playbackEnded ? self.lastObservedLength / 1000.0 : MAX(0, (double)[self mediaTime] / 1000.0)
    duration:[self mediaLength] / 1000.0
    running:self.player.isPlaying && self.wantsPlayback && !self.buffering && !self.networkFlow.holding && !self.networkFlow.verifying
    seeking:self.seeking || self.scrubbing || self.reloading rate:self.playbackRate];
}
- (void)beginScrubbing { [self showControls]; self.scrubbing = YES; }
- (void)cancelScrubbing { self.scrubbing = NO; [self.chrome finishSeekPreview]; [self showControls]; }
- (void)endScrubbing {
  [NeoVLCFrameTap clearARIBView:self.movieView];
  if (self.player.isSeekable) { [self seekBy:(int64_t)(self.timeline.value * [self mediaLength]) - [self mediaTime] completion:^{}]; }
  else { [self.chrome finishSeekPreview]; }
  self.scrubbing = NO; [self showControls];
}

- (BOOL)isOrdinarySubtitle:(VLCMediaPlayerTrack *)track {
  return ![NeoCommentOverlay isCommentName:track.trackName ?: @""] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""];
}
- (void)restoreSubtitlePreference {
  NSNumber *streamChoice = self.recordingContext[@"streamSubtitleIndex"];
  if ([self isStreaming] && streamChoice && !self.streamSubtitleUserSelected) {
    if (streamChoice.integerValue < 0) {
      for (VLCMediaPlayerTrack *track in self.player.textTracks) { if (track.isSelected) { track.selected = NO; } }
    }
    return;
  }
  NSString *name = [NeoSubtitlePreference savedName];
  if (!name) { return; }
  NSMutableArray<VLCMediaPlayerTrack *> *tracks = [NSMutableArray new];
  NSMutableArray<NSString *> *names = [NSMutableArray new];
  NSMutableArray<NSString *> *ids = [NSMutableArray new];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) {
    if (![self isOrdinarySubtitle:track]) { continue; }
    [tracks addObject:track]; [names addObject:track.trackName ?: @"字幕"]; [ids addObject:track.trackId ?: @""];
  }
  NSString *signature = [NSString stringWithFormat:@"%@|%@", name, [ids componentsJoinedByString:@"|"]];
  if ([signature isEqualToString:self.subtitleSignature]) { return; }
  self.subtitleSignature = signature;
  NSInteger chosen = [NeoSubtitlePreference preferredIndex:names];
  for (NSInteger index = 0; index < tracks.count; index++) {
    VLCMediaPlayerTrack *track = tracks[index]; BOOL selected = index == chosen;
    if (track.isSelected != selected) { track.selected = selected; }
  }
}
- (void)updateSubtitleSettings {
  [self attachStreamingSubtitles];
  [self restoreSubtitlePreference];
  NSMutableArray *tracks = [NSMutableArray new]; NSInteger index = 0;
  for (VLCMediaPlayerTrack *track in self.player.textTracks) {
    [tracks addObject:@{@"index": @(index++), @"name": track.trackName ?: @"字幕", @"detail": track.trackDescription ?: @"", @"selected": @(track.isSelected)}];
  }
  [self.chrome updateSubtitleTracks:tracks];
  BOOL arib = NO;
  for (VLCMediaPlayerTrack *track in self.player.textTracks) {
    NSString *description = [NSString stringWithFormat:@"%@ %@", track.trackName ?: @"", track.trackDescription ?: @""];
    if (track.isSelected && [description rangeOfString:@"ARIB" options:NSCaseInsensitiveSearch].location != NSNotFound) { arib = YES; }
  }
  __weak typeof(self) weakSelf = self;
  NSInteger (^provider)(void) = nil;
  if (self.aribClock && arib) { provider = ^NSInteger { return [weakSelf.aribClock stateAt:[weakSelf mediaTime]/1000.0]; }; }
  [NeoVLCFrameTap bindARIBView:self.movieView state:provider];
}
- (void)showSubtitles { [self showControls]; [self updateSubtitleSettings]; [self.chrome showSettings:@"subtitles"]; }
- (void)showComments { [self showControls]; [self.chrome showSettings:@"comments"]; }

- (void)updateCommentState {
  if (self.closing) { return; }
  self.commentLabel.text = [NSString stringWithFormat:@"%@ · %@%@", self.comments.status,
    self.frameTapInstalled ? self.commentPiP.status ?: @"PiP · 準備中" : @"PiP · VLCの映像出力を取得できません。",
    self.comments.enabled ? @"" : @" · 専用描画オフ"];
  [self.commentPiP updateCommentsFrom:self.comments];
  if (self.chrome.wantsCommentRows && self.chrome.commentVersion != self.comments.panelVersion) { [self.chrome setCommentRows:[self.comments panelComments] version:self.comments.panelVersion]; }
  [self.chrome updateCommentMessage:self.comments.status];
  [self.chrome refreshCommentSettings];
  [self.chrome updateDiagnostics];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) {
    if (![NeoCommentOverlay isCommentName:track.trackName] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) { continue; }
    if (self.comments.ready && self.comments.enabled && track.isSelected) {
      [self.suppressedCommentTracks addObject:track.trackId]; track.selected = NO;
    } else if (!self.comments.ready && self.comments.enabled && [self.suppressedCommentTracks containsObject:track.trackId]) {
      // A rendering error restores the prior VLC comment track, rather than losing it.
      track.selected = YES; [self.suppressedCommentTracks removeObject:track.trackId];
    }
  }
}

- (void)resetNetworkFlow {
  [self.networkFlow reset]; self.flowResyncing = NO; self.flowVerifyDeadline = 0;
  if (self.flowMuted) { self.player.audio.muted = self.flowPreviousMute; self.flowMuted = NO; }
}
- (void)checkNetworkFlow {
  if (!self.rewindCache && !self.streamingSession) { return; }
  if (self.flowResyncing) { return; }
  BOOL videoSelected = NO;
  for (VLCMediaPlayerTrack *track in self.player.videoTracks) { videoSelected |= track.isSelected; }
  BOOL eligible = videoSelected && self.videoOutputView && self.inputBufferReady && !self.closing &&
    !self.reloading && !self.networkReloadWaiting && !self.videoReloadRecovery && !self.tsPositionPending && !self.seeking && !self.scrubbing && !self.videoResuming && !self.playbackEnded && !self.playbackFailed &&
    (!self.inputInBackground || self.pipActive);
  double active = self.commentPiP.videoActivityHostTime;
  double now = CACurrentMediaTime();
  double age = active > 0 ? MAX(0, now-active) : -1;
  VLCMediaStats native = self.player.media.statistics;
  NSDictionary *clock = self.player.observedClock;
  double clockAge = clock[@"age"] ? [clock[@"age"] doubleValue] : 0;
  if (native.decodedVideo != self.flowDecodedVideo || self.flowDecodedAt <= 0) {
    self.flowDecodedVideo = native.decodedVideo; self.flowDecodedAt = now;
  }
  if (native.playedAudioBuffers != self.flowPlayedAudio || self.flowAudioAt <= 0) {
    self.flowPlayedAudio = native.playedAudioBuffers; self.flowAudioAt = now;
  }
  // VLC can keep re-enqueuing a paused picture with new host timestamps while
  // buffering. Its actual decoded-video counter distinguishes that path from
  // genuinely advancing pictures without comparing any image pixels.
  if (self.buffering) { age = MAX(age, MIN(now-self.flowDecodedAt, clockAge)); }
  VLCMediaVideoTrack *video = self.player.media.videoTracks.firstObject.video;
  double threshold = video.frameRate > 0 ? MAX(1.5, 3.0*MAX(1,video.frameRateDenominator)/video.frameRate) : 1.5;
  self.flowStaleThreshold = threshold;
  // With a blocked read VLC may announce buffering only when that read
  // returns and PCR is already late. Detect both native pipelines starving
  // before that notification, so the eventual data does not inherit a clock
  // that ran ahead throughout the blackout. Healthy queued video with audio
  // still advancing is not classified by this extra condition.
  if (self.player.media.audioTracks.count > 0) {
    age = MAX(age, MIN(clockAge, MIN(now-self.flowDecodedAt, now-self.flowAudioAt)));
  }
  NSDictionary *flow = self.streamingSession ? self.streamingSession.flowState : self.rewindCache.flowState;
  int64_t before = [self mediaTime];
  NSInteger action = [self.networkFlow updateWithWaiting:[flow[@"waiting"] boolValue]
    delivery:[flow[@"delivery"] longLongValue] video:native.decodedVideo
    videoAge:age staleAfter:threshold eligible:eligible wantsPlayback:self.wantsPlayback];
  if (!eligible) {
    [self resetNetworkFlow]; return;
  }
  if (!action) {
    if (self.networkFlow.verifying && now >= self.flowVerifyDeadline) {
      // A seek acknowledgement is not proof that video output recovered.
      // Repair only that decoder; the existing bounded fallback handles failure.
      [NeoPlaybackDiagnostics record:@"network.videoDeadline" fields:@{@"mediaMs": @(self.flowHoldTime)}];
      [self rebuildVideoAtCurrentPosition]; [self resetNetworkFlow];
      if (!self.videoResuming) { [self failVideoRecovery]; }
    }
    return;
  }
  if (action == 1) {
    self.flowHoldTime = before;
    if (clock[@"positionMs"] && ![self wholeFileClock]) {
      self.flowHoldTime = MIN(before, self.inputStartTime+[clock[@"positionMs"] longLongValue]);
    }
    self.flowPreviousMute = self.player.audio.isMuted; self.flowMuted = YES; self.player.audio.muted = YES;
  }
  [NeoPlaybackDiagnostics record:action == 1 ? @"network.presentationHeld" : action == 2 ? @"network.bytesResumed" : @"network.videoResumed"
    fields:@{@"mediaMs": @([self mediaTime]), @"delivery": flow[@"delivery"] ?: @0,
      @"videoAge": @(age), @"decodedVideo": @(native.decodedVideo), @"wantsPlayback": @(self.wantsPlayback)}];
  if (action == 2) {
    // Rebase the existing demux/decoders at the confirmed presentation point.
    // This discards late queued A/V and resets their native clock together,
    // without opening HTTP from zero or replacing the media/input.
    if (!self.player.isSeekable) { [self resetNetworkFlow]; [self failVideoRecovery]; return; }
    self.flowResyncing = YES; self.flowVerifyDeadline = now+MAX(12, self.networkCaching/1000.0+10);
    VLCMedia *input = self.player.media; int64_t target = self.flowHoldTime;
    __weak typeof(self) weakSelf = self;
    [self seekBy:target-[self mediaTime] completion:^{
      if (!weakSelf || weakSelf.closing || weakSelf.player.media != input) { return; }
      weakSelf.flowResyncing = NO;
      [NeoPlaybackDiagnostics record:@"network.inputResynced" fields:@{@"targetMs": @(target),
        @"nativeMs": @(weakSelf.inputStartTime+MAX(0,weakSelf.player.time.value.longLongValue)),
        @"failed": @(weakSelf.lastSeekFailed), @"sameInput": @(weakSelf.player.media == input)}];
      if (weakSelf.lastSeekFailed || !weakSelf.wantsPlayback) { [weakSelf resetNetworkFlow]; }
      else { weakSelf.flowVerifyDeadline = CACurrentMediaTime()+MAX(12, weakSelf.networkCaching/1000.0+10); }
      [weakSelf applyPlaybackIntentForced:YES]; [weakSelf updateLoadingState];
    }];
  } else if (action == 3) { [self resetNetworkFlow]; }
  [self updateLoadingState];
}
- (void)updateControls {
  if (self.closing) { return; }
  [self checkNetworkFlow];
  [self restoreReloadIfReady];
  [self applyPlaybackIntent];
  [self updateNowPlaying];
  [self sampleHistory];
  self.timeline.enabled = self.player.isSeekable && !self.reloading && !self.reloadTimedOut; self.playButton.enabled = YES;
  int64_t current = MAX(0, [self mediaTime] / 1000);
  int64_t length = [self mediaLength] / 1000;
  if (!self.scrubbing && length > 0) { self.timeline.value = self.playbackEnded ? 1 : MIN(1, MAX(0, (double)[self mediaTime] / [self mediaLength])); }
  [self rememberPlaybackTime];
  if (self.inputBufferReady && !self.tsPositionPending && !self.reloading && !self.networkReloadWaiting && !self.awaitingComments) {
    [self.streamingSession observeTime:current running:self.player.isPlaying];
  }
  [self.rewindCache observeTime:current running:self.player.isPlaying && !self.buffering && !self.seeking];
  [self.chrome updatePlayback:self.wantsPlayback && !self.playbackEnded current:self.playbackEnded ? self.lastObservedLength / 1000 : current duration:length > 0 ? length : self.lastObservedLength / 1000];
  [self.chrome updateDownloadedRanges:(self.streamingSession ? self.streamingSession.downloadedRanges : self.rewindCache.downloadedRanges) ?: @[]];
  NSString *cacheStatus = self.streamingSession ? self.streamingSession.status : self.rewindCache.status;
  NSString *warning = cacheStatus.length ? cacheStatus : self.history.status;
  if (warning.length) { self.statusLabel.text = warning; }
  else if (self.lastPresentedWarning.length && [self.statusLabel.text isEqualToString:self.lastPresentedWarning]) {
    self.statusLabel.text = self.playbackEnded ? @"PLAY · 再生終了" : self.wantsPlayback ? @"PLAY · 再生中" : @"PLAY · 一時停止";
  }
  self.lastPresentedWarning = warning;
  self.subtitleButton.enabled = !self.reloading;
  [self updateSubtitleSettings];
  CGSize size = self.player.videoSize;
  VLCMediaVideoTrack *video = self.player.media.videoTracks.firstObject.video;
  if (video.sourceAspectRatio > 0 && video.sourceAspectRatioDenominator > 0) {
    size.width *= (double)video.sourceAspectRatio / video.sourceAspectRatioDenominator;
  }
  self.comments.videoSize = size;
  [self.comments updateDuration:[self mediaLength] / 1000.0];
  [self checkVideoRecovery];
  [self updateLoadingState];
  [self updateCommentState];
  [self.chrome updateDiagnostics];
  NSTimeInterval now = CACurrentMediaTime();
  [self updateSeekVideoReady];
  if (now - self.lastDiagnosticSample >= 1) {
    self.lastDiagnosticSample = now;
    [NeoPlaybackDiagnostics record:@"video.sample" fields:[NeoVLCFrameTap snapshot:self.movieView]];
    VLCMediaStats nativeStats = self.player.media.statistics;
    [NeoPlaybackDiagnostics record:@"player.sample" fields:@{@"mediaMs": @([self mediaTime]),
      @"state": @(self.player.state), @"buffering": @(self.buffering), @"seeking": @(self.seeking),
      @"nativePlaying": @(self.player.isPlaying), @"appState": @(UIApplication.sharedApplication.applicationState),
      @"decodedVideo": @(nativeStats.decodedVideo), @"decodedAudio": @(nativeStats.decodedAudio),
      @"readBytes": @(nativeStats.readBytes), @"demuxBytes": @(nativeStats.demuxReadBytes),
      @"latePictures": @(nativeStats.latePictures), @"playedAudio": @(nativeStats.playedAudioBuffers),
      @"displayedPictures": @(nativeStats.displayedPictures), @"lostPictures": @(nativeStats.lostPictures),
      @"outputArrivalAge": @(self.commentPiP.videoDecodeHostTime > 0 ? MAX(0, now-self.commentPiP.videoDecodeHostTime) : -1),
      @"decodeAge": @(self.commentPiP.videoDecodeHostTime > 0 ? MAX(0, now-self.commentPiP.videoDecodeHostTime) : -1),
      @"videoWidth": @(self.movieView.bounds.size.width), @"videoHeight": @(self.movieView.bounds.size.height),
      @"wantsPlayback": @(self.wantsPlayback), @"pip": @(self.pipActive),
      @"commentTime": @(self.comments.renderedTime), @"commentsReady": @(self.comments.ready), @"videoHook": @(self.frameTapInstalled),
      @"videoAge": @(MAX(0, now - self.commentPiP.videoPresentationHostTime)),
      @"capturedFrames": @(self.commentPiP.capturedFrameCount)}];
  }
}

- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)state {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NeoPlaybackDiagnostics record:@"player.state" fields:@{@"state": @(state), @"mediaMs": @([self mediaTime])}];
    if (self.closing) {
      if (state == VLCMediaPlayerStateStopped) { [self finishClosing]; }
      return;
    }
    if (self.networkReloadWaiting) { [self updateLoadingState]; return; }
    if ([self isStreaming] && state == VLCMediaPlayerStatePaused && !self.tsPositionPending && !self.reloading && !self.videoReloadRecovery) { [self releaseRestoreMute]; }
    if (state == VLCMediaPlayerStatePaused && self.player.state == state && !self.seeking && !self.reloading &&
        !self.tsPositionPending && !self.videoResuming && [self wholeFileClock]) {
      int64_t paused = [self guardStreamingTime:self.player.nativeTimeMs];
      if (paused >= 0 && ([self mediaLength] <= 0 || paused <= [self mediaLength]+1500)) { self.lastObservedTime = paused; }
    }
    if ((state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError) && self.player.state != state) {
      [NeoPlaybackDiagnostics record:@"player.staleTerminalState" fields:@{@"state": @(state), @"currentState": @(self.player.state)}];
      return;
    }
    if (state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError) {
      [self.bufferingUpdates reset];
      self.buffering = NO; [self.chrome updateBuffering:NO progress:1];
    }
    if (self.videoResuming && (state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError)) {
      [self fallbackVideoResume:state == VLCMediaPlayerStateStopped ? 1 : 2]; return;
    }
    if (self.videoReloadRecovery && !self.reloading && (state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError)) {
      [self failVideoRecovery]; return;
    }
    if (self.reloading && state == VLCMediaPlayerStateStopped && !self.restoringReload && !self.awaitingEndpoint) { [self restartMedia]; return; }
    if (state == VLCMediaPlayerStateError && (self.transportSuspended || self.awaitingEndpoint || self.player.state != state)) { return; }
    if ([self isStreaming] && !self.reloading && !self.playbackFailed &&
        (state == VLCMediaPlayerStateError || (state == VLCMediaPlayerStateStopped && self.lastObservedTime < [self mediaLength]-1500))) {
      int64_t retained = self.networkFlow.holding || self.networkFlow.verifying ? self.flowHoldTime : self.lastObservedTime;
      self.transportRecoveryAttempted = YES;
      [NeoPlaybackDiagnostics record:@"hls.inputInterrupted" fields:@{@"targetMs": @(retained)}];
      [self reloadPlaybackAtTime:retained completion:nil]; return;
    }
    if (state == VLCMediaPlayerStateError && !self.playbackFailed && self.backgroundPositionValid && !self.reloading && !self.transportRecoveryAttempted) {
      self.transportSuspended = YES;
      if (!self.inputInBackground || self.wantsPlayback) {
        self.transportRecoveryAttempted = YES;
        [self reloadPlaybackAtTime:MAX(self.backgroundTime, self.lastObservedTime) completion:nil];
      }
      return;
    }
    if (state == VLCMediaPlayerStateError) {
      self.playbackFailed = YES; self.wantsPlayback = NO;
      [self completeSeek:self.seekGeneration failed:YES];
      if (self.reloading) { [self finishReload:YES]; }
      [self.reloadTimer invalidate]; self.reloadTimer = nil; [self showControls]; [self.history flush];
    }
    if (state == VLCMediaPlayerStateStopping) { [self rememberPlaybackTime]; }
    if (state == VLCMediaPlayerStateStopped) { self.lastObservedTime = MAX(self.lastObservedTime, [self mediaTime]); }
    if (state == VLCMediaPlayerStateStopped && !self.playbackFailed && !self.reloading &&
      self.lastObservedLength > 0 && self.lastObservedTime >= self.lastObservedLength - 1500) {
      self.playbackEnded = YES; self.wantsPlayback = NO;
      [self completeSeek:self.seekGeneration failed:NO];
      [self.history sample:self.lastObservedLength / 1000.0 duration:self.lastObservedLength / 1000.0 running:NO seeking:NO rate:self.playbackRate];
      [self.history flush]; [self showControls];
    }
    if (state == VLCMediaPlayerStateStopped && !self.playbackFailed && !self.playbackEnded && !self.reloading && self.lastObservedTime > 0) {
      if (self.backgroundPositionValid && !self.transportRecoveryAttempted) {
        self.transportSuspended = YES;
        if (!self.inputInBackground || self.wantsPlayback) {
          self.transportRecoveryAttempted = YES;
          [self reloadPlaybackAtTime:MAX(self.backgroundTime, self.lastObservedTime) completion:nil];
        }
        return;
      }
      self.playbackFailed = YES; self.wantsPlayback = NO;
      [self completeSeek:self.seekGeneration failed:YES]; [self.history flush]; [self showControls];
    }

    if ((state == VLCMediaPlayerStatePlaying || state == VLCMediaPlayerStatePaused) && self.player.state == state) {
      if (self.tsPositionPending) { [self advanceTSPosition]; }
      else { [self applyPlaybackIntent]; }
    }
    self.statusLabel.text = state == VLCMediaPlayerStateError || self.playbackFailed
      ? @"再生エラー · 接続・ファイル形式・認証を確認してください。"
      : [NSString stringWithFormat:@"PLAY · %@ · キャッシュ %ld秒", VLCMediaPlayerStateToString(state), (long)self.networkCaching / 1000];
    [self.commentPiP invalidatePlaybackState]; [self updateControls];
    [self.commentPiP updateAutomaticPlayback];
    if (state == VLCMediaPlayerStateStopped) { [self.commentPiP resetVideo]; }
  });
}

- (void)mediaPlayerBufferingChanged:(float)progress {
  [self.bufferingUpdates submit:progress];
}
- (void)applyBufferingProgress:(float)progress notifications:(NSInteger)count {
    if (self.closing) { return; }
    BOOL changed = self.buffering != (progress < 1);
    self.buffering = progress < 1;
    if (progress >= 1) { self.inputBufferReady = YES; }
    [NeoPlaybackDiagnostics record:@"player.buffering" fields:@{@"progress": @(progress), @"notifications": @(count),
      @"nativePlaying": @(self.player.isPlaying), @"mediaMs": @([self mediaTime])}];
    [self.chrome updateBuffering:self.buffering progress:progress];
    [self updateLoadingState];
    if (!self.closing) {
      self.statusLabel.text = progress < 1 ? [NSString stringWithFormat:@"バッファリング %.0f%%", progress * 100]
        : self.reloading ? @"プレイヤーを再読み込みしています…" : @"PLAY · 再生準備完了";
    }
    if (changed && !self.buffering) { [self applyPlaybackIntent]; }
    if (changed) { [self.commentPiP invalidatePlaybackState]; }
}
- (void)mediaPlayerLengthChanged:(int64_t)length {
  dispatch_async(dispatch_get_main_queue(), ^{
    // VLC 4 reports input duration here even when VLCMedia has not been parsed.
    // The pinned VLCKit delegate already converts microseconds to milliseconds.
    if (length > 0) { self.lastObservedLength = length + self.inputStartTime; self.hasInputLength = YES; }
    [self.commentPiP invalidatePlaybackState];
  });
}
- (void)rememberPlaybackTime {
  VLCMediaPlayerState state = self.player.state;
  if (self.playbackEnded || self.seeking || self.reloading ||
      (state != VLCMediaPlayerStatePlaying && state != VLCMediaPlayerStatePaused && state != VLCMediaPlayerStateStopping)) { return; }
  int64_t length = [self mediaLength];
  if (length > 0) {
    self.lastObservedLength = length;
    self.lastObservedTime = MAX(0, [self mediaTime]);
  }
}
- (void)mediaPlayerTimeChanged:(NSNotification *)notification {
  // Discontinuity callbacks can run on VLC's decoder thread while its player
  // lock is held. Never query isSeekable/isPlaying or UIKit from that callback.
  // Now Playing is updated by the UI timer and explicit state/intent changes.
  if (NSThread.isMainThread) { [self rememberPlaybackTime]; }
  else { dispatch_async(dispatch_get_main_queue(), ^{ if (!self.closing) { [self rememberPlaybackTime]; } }); }
}
- (void)updateNowPlaying {
  [self.nowPlaying updateWithPosition:self.reloading ? self.reloadTime/1000.0 : (self.playbackEnded ? self.lastObservedLength/1000.0 : MAX(0, (double)[self mediaTime]/1000.0))
    duration:[self mediaLength]/1000.0 rate:self.playbackRate
    playing:self.wantsPlayback && self.player.isPlaying && !self.buffering && !self.reloading && !self.networkReloadWaiting && !self.videoReloadRecovery && !self.playbackEnded
    seekable:self.player.isSeekable && !self.reloading artwork:self.chrome.channelArtwork];
}

- (void)interrupted:(NSNotification *)notification {
  if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
    self.resumeAfterInterruption = self.wantsPlayback; [self setPlaybackIntent:NO];
  } else if (self.resumeAfterInterruption &&
    ([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume)) {
    [AVAudioSession.sharedInstance setActive:YES error:nil]; [self setPlaybackIntent:YES]; self.resumeAfterInterruption = NO;
  }
}
- (void)inactive { if (!self.closing) { [self.commentPiP prepareForInactive]; } }
- (void)backgrounded {
  [self.history flush];
  [NeoPlaybackDiagnostics record:@"lifecycle.background" fields:@{@"wantsPlayback": @(self.wantsPlayback), @"pip": @(self.pipActive), @"mediaMs": @([self mediaTime])}];
  if (self.closing) { return; }
  if (self.videoResuming) {
    // Do not leave a deselected track behind if another background transition
    // interrupts preparation. The next foreground will retry its saved track.
    self.videoResumeGeneration++;
  }
  [self.videoRecovery reset]; self.videoWatchPending = NO; self.repairingVideo = NO;
  self.inputInBackground = YES;
  self.backgroundTime = self.reloading ? self.reloadTime : MAX(0, [self mediaTime]);
  self.backgroundPositionValid = YES;
  [self.commentPiP enterBackground];
  // A paused app can be suspended by iOS without destroying its input.
  // Keep the listener, retained data and VLC demux/decoder state intact.
}
- (void)foregrounded {
  if (self.closing) { return; }
  BOOL returningFromBackground = self.inputInBackground;
  [NeoPlaybackDiagnostics record:@"lifecycle.foreground" fields:@{@"wantsPlayback": @(self.wantsPlayback), @"needsRecovery": @(self.transportSuspended), @"mediaMs": @([self mediaTime])}];
  if (self.inputInBackground) { [self.rewindCache resumeFetching]; [self.streamingSession resumeFetching]; }
  self.inputInBackground = NO;
  if (returningFromBackground && !self.videoResuming && !self.videoReloadRecovery && !self.reloading) {
    self.videoRecoveryFallbackAttempted = NO;
  }
  if (self.videoReloadRecovery && !self.reloading) { self.videoReloadDeadline = CACurrentMediaTime()+10; }
  [self.commentPiP enterForeground];
  [AVAudioSession.sharedInstance setActive:YES error:nil];
  [self alignVideoOutput];
  [NeoVLCFrameTap prepareForeground:self.movieView];
  [self.videoRecovery reset]; self.videoWatchPending = YES;
  self.repairingVideo = NO;
  [NeoPlaybackDiagnostics record:@"video.foregroundFlush" fields:[NeoVLCFrameTap snapshot:self.movieView]];
  VLCMediaPlayerState state = self.player.state;
  if (!self.reloading && !self.playbackEnded && self.backgroundPositionValid &&
      (self.transportSuspended || state == VLCMediaPlayerStateError || state == VLCMediaPlayerStateStopped)) {
    self.transportRecoveryAttempted = YES;
    [self reloadPlaybackAtTime:MAX(self.backgroundTime, self.lastObservedTime) completion:nil];
  } else if (self.videoResuming) {
    self.repairingVideo = YES;
    if (!returningFromBackground) { return; }
    if (self.videoResumeStage == 2) {
      [self completeSeek:self.seekGeneration failed:YES];
      self.videoResumeStage = 1; self.videoResumeSeekFinished = NO;
    }
    self.repairingVideo = YES;
    self.videoResumeDeadline = CACurrentMediaTime()+4;
    [self pollVideoResume:++self.videoResumeGeneration];
  } else if (returningFromBackground && !self.pipActive && [[NeoVLCFrameTap snapshot:self.movieView][@"resourceInterrupted"] boolValue]) {
    [self rebuildVideoAtCurrentPosition];
    if (!self.videoResuming) { [self applyPlaybackIntentForced:YES]; }
  } else { [self applyPlaybackIntentForced:YES]; }
}

// VLC 4's HTTP access uses authentication dialogs, not the old http-user/pwd options.
- (void)showLoginWithTitle:(NSString *)title message:(NSString *)message defaultUsername:(NSString *)username
         askingForStorage:(BOOL)askingForStorage withReference:(NSValue *)reference {
  if (self.closing || self.loginReference) { [self.dialogs dismissDialogWithReference:reference]; return; }
  self.loginReference = reference;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"再生の認証" message:message preferredStyle:UIAlertControllerStyleAlert];
  self.loginAlert = alert;
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = @"ユーザー名"; field.text = self.username.length ? self.username : username;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = @"パスワード"; field.secureTextEntry = YES; field.text = self.password;
  }];
  __weak typeof(self) weakSelf = self;
  __weak UIAlertController *weakAlert = alert;
  [alert addAction:[UIAlertAction actionWithTitle:@"認証" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    if (!weakSelf.loginReference) { return; }
    [weakSelf.dialogs postUsername:weakAlert.textFields[0].text ?: @"" andPassword:weakAlert.textFields[1].text ?: @""
      forDialogReference:reference store:NO];
    weakSelf.loginReference = nil; weakSelf.loginAlert = nil;
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    [weakSelf.dialogs dismissDialogWithReference:reference]; weakSelf.loginReference = nil; weakSelf.loginAlert = nil;
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}
- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
  if (!self.closing) { self.statusLabel.text = @"再生エラー · 接続・ファイル形式・認証を確認してください。"; }
}
- (void)showQuestionWithTitle:(NSString *)title message:(NSString *)message type:(VLCDialogQuestionType)type
                cancelString:(NSString *)cancelString action1String:(NSString *)action1String
               action2String:(NSString *)action2String withReference:(NSValue *)reference {
  // Never silently accept certificate exceptions or other access questions.
  [self.dialogs dismissDialogWithReference:reference];
}
- (void)showProgressWithTitle:(NSString *)title message:(NSString *)message isIndeterminate:(BOOL)isIndeterminate
                    position:(float)position cancelString:(NSString *)cancelString withReference:(NSValue *)reference {}
- (void)updateProgressWithReference:(NSValue *)reference message:(NSString *)message position:(float)position {}
- (void)cancelDialogWithReference:(NSValue *)reference {
  if ([reference isEqual:self.loginReference]) {
    [self.loginAlert dismissViewControllerAnimated:YES completion:nil]; self.loginAlert = nil; self.loginReference = nil;
  }
}

- (void)addSubview:(UIView *)view {
  // VLC's UIView output forwards taps as mouse events (including pause/play).
  // Recorded PLAY has one input owner: the app's controls on the ancestor.
  // Apply this to each output replacement, including TS and reloads.
  view.userInteractionEnabled = NO;
  if (self.videoOutputView && self.videoOutputView != view) { [self.videoOutputView removeFromSuperview]; }
  self.videoOutputView = view;
  // Geometry is assigned in the untransformed coordinate system by the
  // chrome's layout callback, including panel resize and pinch zoom.
  view.autoresizingMask = UIViewAutoresizingNone;
  view.hidden = self.tsPositionPending;
  view.frame = self.movieView.bounds;
  [self.movieView addSubview:view];
  [self alignVideoOutput];
  [NeoVLCFrameTap bindView:view sink:self.commentPiP];
  if (self.tsPositionPending || self.awaitingSeekVideo) { [self observeSeekFrames]; }
}
- (void)layoutVideoOutputIfNeeded {
  self.comments.frame = self.chrome.commentViewport.bounds;
  self.comments.referenceVideoSize = self.chrome.normalVideoFrame.size;
  self.comments.expandsToViewport = self.landscape;
  VLCMediaVideoTrack *video = self.player.media.videoTracks.firstObject.video;
  if (video.width > 0 && video.height > 0) {
    CGFloat pixelRatio = video.sourceAspectRatio > 0 && video.sourceAspectRatioDenominator > 0
      ? (CGFloat)video.sourceAspectRatio/video.sourceAspectRatioDenominator : 1;
    self.chrome.videoAspectRatio = (CGFloat)video.width/video.height*pixelRatio;
  }
  CGRect bounds = CGRectMake(0, 0, self.chrome.normalVideoFrame.size.width, self.chrome.normalVideoFrame.size.height);
  CGPoint center = CGPointMake(CGRectGetMidX(self.movieView.bounds), CGRectGetMidY(self.movieView.bounds));
  if (!CGRectEqualToRect(self.videoOutputView.bounds, bounds) ||
      !CGPointEqualToPoint(self.videoOutputView.center, center)) {
    [self alignVideoOutput];
  }
}
- (void)alignVideoOutput {
  // Resize VLC's outer drawable only. libVLC lays out its inner aspect-fit
  // sample-buffer view using the resulting video-output size notification.
  if (self.videoOutputView.superview != self.movieView) { return; }
  self.videoOutputView.transform = CGAffineTransformIdentity;
  // Expanding the clipping viewport must not resize VLC's drawable: its
  // inner sample-buffer layout updates asynchronously and can retain the old
  // video origin. Keep the normal drawable size, center it in the viewport,
  // and use only an affine transform for zoom/pan.
  CGSize size = self.chrome.normalVideoFrame.size;
  if (size.width <= 0 || size.height <= 0) { size = self.movieView.bounds.size; }
  self.videoOutputView.bounds = (CGRect){CGPointZero, size};
  self.videoOutputView.center = CGPointMake(CGRectGetMidX(self.movieView.bounds), CGRectGetMidY(self.movieView.bounds));
  [self.videoOutputView setNeedsLayout]; [self.videoOutputView layoutIfNeeded];
  [self applyVideoZoom:self.chrome.videoZoom];
}
- (void)applyVideoZoom:(CGFloat)scale {
  // Scale only VLC's drawable. HUD, comments, program info and PiP stay at
  // their own sizes; no input, byte range, decoder or playback clock changes.
  CGPoint offset = self.chrome.videoOffset;
  self.videoOutputView.transform = CGAffineTransformMake(scale, 0, 0, scale, offset.x, offset.y);
}
- (CGRect)bounds { return self.movieView.bounds; }
- (void)updatePiPState {
  if (self.closing) { return; }
  self.pipActive = self.commentPiP.active;
  [self.chrome updatePiP:self.pipActive];
  if (self.comments.coveredByPiP != self.pipActive) { self.comments.coveredByPiP = self.pipActive; }
  self.pipButton.enabled = self.frameTapInstalled && self.commentPiP.possible;
  if (!self.frameTapInstalled) { self.commentLabel.text = @"PiP · VLCの映像出力を取得できません。"; }
}
- (void)startPiP {
  [self showControls]; [self.commentPiP start];
}
#if TARGET_OS_SIMULATOR
- (void)runStreamingProbeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  NSMutableDictionary *checks = [[NeoPlayerChrome runSeekPresentationChecks] mutableCopy];
  [checks addEntriesFromDictionary:[NeoStreamingDialog runLayoutChecksWithSource:self.sourceURL]];
  [checks addEntriesFromDictionary:[NeoCommentOverlay runCanvasChecks]];
  [self waitStreamingPhase:0 target:49000 attempt:0 checks:checks completion:completion];
}
- (void)waitStreamingPhase:(NSInteger)phase target:(int64_t)target attempt:(NSInteger)attempt
                   checks:(NSMutableDictionary *)checks completion:(void (^)(NSDictionary *))completion {
  int64_t native = self.player.nativeTimeMs;
  BOOL ready = !self.tsPositionPending && !self.reloading && !self.networkReloadWaiting && !self.playbackFailed &&
    self.inputBufferReady && !self.lastSeekFailed && !self.seeking && llabs(native-target) < 3000 &&
    self.player.state == (phase == 0 ? VLCMediaPlayerStatePlaying : VLCMediaPlayerStatePaused);
  if (!ready && attempt < 450 && !self.playbackFailed) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self waitStreamingPhase:phase target:target attempt:attempt+1 checks:checks completion:completion];
    }); return;
  }
  checks[[NSString stringWithFormat:@"phase%ld.arrived", (long)phase]] = @(ready);
  checks[[NSString stringWithFormat:@"phase%ld.wholeFileClock", (long)phase]] = @(self.inputStartTime == 0 && llabs([self mediaTime]-target) < 2000);
  if (!ready) { completion(@{@"success": @NO, @"checks": checks, @"phase": @(phase), @"native": @(native), @"state": @(self.player.state)}); return; }
  checks[@"commentsPrepared"] = @(self.comments.ready);
  if (phase == 1) {
    checks[@"seekFinishesWithoutFallbackReload"] = @(self.reloadGeneration == 0 && !self.lastSeekFailed && CACurrentMediaTime()-self.seekStartedAt < 5);
    if (self.streamingSubtitles) { checks[@"externalSubtitleAttached"] = @(self.attachedSubtitles.count > 0); }
    [self performPlayerAction:@"quality:1"];
    [self waitStreamingPhase:2 target:target attempt:0 checks:checks completion:completion]; return;
  }
  if (phase == 2) {
    checks[@"qualityChanged"] = @([self.recordingContext[@"streamMode"] integerValue] == 1);
    NSURL *fault = [[self.sourceURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    fault = [fault URLByAppendingPathComponent:@"test-fault"];
    [[[NSURLSession sharedSession] dataTaskWithURL:fault completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadPlaybackAtTime:70000 completion:nil];
        [self waitStreamingPhase:3 target:70000 attempt:0 checks:checks completion:completion];
      });
    }] resume]; return;
  }
  int64_t start = native; uint64_t video = self.player.media.statistics.decodedVideo;
  [self setPlaybackIntent:YES];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    int64_t current = self.player.nativeTimeMs;
    // At startup the first native interpolation may still include TS PCR
    // preroll. Measure progress from the requested content position, not that
    // provisional value; later recovery already has a confirmed pause clock.
    int64_t origin = target;
    checks[[NSString stringWithFormat:@"phase%ld.clockAdvancesFromTarget", (long)phase]] = @(current > origin+1000 && current < origin+4000);
    checks[[NSString stringWithFormat:@"phase%ld.videoAdvances", (long)phase]] = @(self.player.media.statistics.decodedVideo > video+12);
    [NeoPlaybackDiagnostics record:@"hls.probeProgress" fields:@{@"phase": @(phase), @"targetMs": @(target), @"initialMs": @(start), @"afterMs": @(current),
      @"appMs": @([self mediaTime]), @"videoBefore": @(video), @"videoAfter": @(self.player.media.statistics.decodedVideo)}];
    checks[[NSString stringWithFormat:@"phase%ld.commentsFollowClock", (long)phase]] = @(fabs(self.comments.renderedTime-current/1000.0) < 1.5);
    checks[@"segmentRangesAvailable"] = @(self.streamingSession.downloadedRanges.count > 0);
    // During the five-second transition guard a native PCR correction can
    // legitimately lag the last confirmed app time. Check exact agreement
    // after that guard expires, while still requiring early video/progress.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      int64_t settled = self.player.nativeTimeMs, app = [self mediaTime];
      checks[[NSString stringWithFormat:@"phase%ld.runningClockMatchesNative", (long)phase]] = @(llabs(app-settled) < 250);
      checks[[NSString stringWithFormat:@"phase%ld.settledPlaybackAdvances", (long)phase]] =
        @(settled > current+2500 && settled < current+5500 && self.player.media.statistics.decodedVideo > video+60);
      checks[[NSString stringWithFormat:@"phase%ld.settledCommentsFollowClock", (long)phase]] = @(fabs(self.comments.renderedTime-settled/1000.0) < 1.5);
      [NeoPlaybackDiagnostics record:@"hls.probeSettled" fields:@{@"phase": @(phase), @"nativeMs": @(settled), @"appMs": @(app)}];
      [self setPlaybackIntent:NO];
      if (phase == 0) {
        BOOL cached = NO;
        for (NSArray<NSNumber *> *range in self.streamingSession.downloadedRanges) {
          if (range[0].doubleValue <= 50 && range[1].doubleValue > 50) { cached = YES; }
        }
        checks[@"cachedSeekTargetDownloaded"] = @(cached);
        [self setPlaybackIntent:YES];
        [self seekBy:50000-[self mediaTime] completion:^{
          checks[@"cachedSeekVerifiedWithoutReload"] = @(!self.lastSeekFailed && self.reloadGeneration == 0);
          [NeoPlaybackDiagnostics record:@"seek.cachedProbe" fields:@{@"durationMs": @((CACurrentMediaTime()-self.seekStartedAt)*1000),
            @"targetMs": @50000, @"cached": @(cached)}];
          [self setPlaybackIntent:NO];
          [self seekBy:20000-[self mediaTime] completion:^{ [self waitStreamingPhase:1 target:20000 attempt:0 checks:checks completion:completion]; }];
        }]; return;
      }
      BOOL passed = YES; for (NSNumber *value in checks.allValues) { passed &= value.boolValue; }
      [self closePlayer];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ completion(@{@"success": @(passed), @"checks": checks}); });
    });
  });
}
- (void)runTSResumeProbeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  NSMutableDictionary *checks = [NSMutableDictionary new];
  NSMutableArray *rows = [NSMutableArray new];
  [self waitTSResumePhase:0 target:49000 attempt:0 checks:checks rows:rows completion:completion];
}
- (void)waitTSResumePhase:(NSInteger)phase target:(int64_t)target attempt:(NSInteger)attempt
                  checks:(NSMutableDictionary *)checks rows:(NSMutableArray *)rows
              completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  int64_t native = self.player.nativeTimeMs;
  NSDictionary *clock = self.player.observedClock;
  BOOL ready = !self.tsPositionPending && !self.reloading && !self.playbackFailed && self.inputBufferReady &&
    llabs(native-target) < 2500 && llabs([clock[@"positionMs"] longLongValue]-target) < 2500 &&
    self.player.state == (phase == 0 ? VLCMediaPlayerStatePlaying : VLCMediaPlayerStatePaused);
  if (!ready && attempt < 125 && !self.playbackFailed) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self waitTSResumePhase:phase target:target attempt:attempt+1 checks:checks rows:rows completion:completion];
    }); return;
  }
  NSString *prefix = [NSString stringWithFormat:@"phase%ld", (long)phase];
  checks[[prefix stringByAppendingString:@".nativeArrival"]] = @(ready);
  checks[[prefix stringByAppendingString:@".wholeFileClock"]] = @(self.inputStartTime == 0 && llabs([self mediaTime]-native) < 100);
  [rows addObject:@{@"phase": @(phase), @"targetMs": @(target), @"nativeMs": @(native),
    @"observed": clock, @"appMs": @([self mediaTime]), @"state": @(self.player.state), @"commentsReady": @(self.comments.ready)}];
  if (!ready) { completion(@{@"success": @NO, @"checks": checks, @"rows": rows}); return; }
  checks[[prefix stringByAppendingString:@".commentsPrepared"]] = @(self.comments.ready);
  int64_t start = native;
  uint64_t frames = self.player.media.statistics.decodedVideo;
  [self setPlaybackIntent:YES];
  // A paused decoder can report a PCR point ahead of the displayed frame.
  // Observe three seconds so that ordinary preroll/resume latency does not
  // consume the whole 1.5-second advancement margin.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    int64_t current = self.player.nativeTimeMs;
    checks[[prefix stringByAppendingString:@".clockAdvancesWithoutTargetDelay"]] = @(current > start+1500 && current < start+4000);
    checks[[prefix stringByAppendingString:@".videoAdvances"]] = @(self.player.media.statistics.decodedVideo > frames+15);
    checks[[prefix stringByAppendingString:@".commentsFollowNativeClock"]] = @(self.comments.renderedTime > start/1000.0+1 && fabs(self.comments.renderedTime-current/1000.0) < 1.5);
    [rows addObject:@{@"phase": @(phase), @"afterMs": @(current), @"commentTime": @(self.comments.renderedTime)}];
    [self setPlaybackIntent:NO];
    if (phase == 2) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        int64_t retained = [self mediaTime];
        self.smokeTSRepairReloadBaseline = self.reloadGeneration;
        [self backgrounded];
        // The wrapper may publish a stale interpolated clock after suspension.
        // Deliberately corrupt that convenience getter while real native clock
        // points and the actual decoder keep running normally.
        self.player.smokeUntrustedTime = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [self foregrounded]; [self rebuildVideoAtCurrentPosition];
          checks[@"pausedRepairUsesRetainedPosition"] = @(llabs(self.videoResumeTime-retained) < 100);
          [self waitTSRetainedRepair:retained attempt:0 checks:checks rows:rows completion:completion];
        });
      });
      return;
    }
    // Later and earlier reopen targets must not reuse the initial 49s offset.
    int64_t next = phase == 0 ? 63000 : 53000;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self reloadPlaybackAtTime:next completion:^{
        [self waitTSResumePhase:phase+1 target:next attempt:0 checks:checks rows:rows completion:completion];
      }];
    });
  });
}
- (void)waitTSRetainedRepair:(int64_t)target attempt:(NSInteger)attempt checks:(NSMutableDictionary *)checks
                       rows:(NSMutableArray *)rows completion:(void (^)(NSDictionary *))completion {
  if ((self.videoResuming || self.tsPositionPending || self.reloading || self.videoReloadRecovery) && attempt < 180) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self waitTSRetainedRepair:target attempt:attempt+1 checks:checks rows:rows completion:completion];
    }); return;
  }
  checks[@"pausedRepairPositionConfirmed"] = @(!self.videoResuming && !self.reloading && !self.playbackFailed &&
    !self.wantsPlayback && llabs([self mediaTime]-target) < 2000 &&
    llabs(self.player.nativeTimeMs-target) < 2000);
  checks[@"damagedTSInputReopensExactlyOnce"] = @(self.reloadGeneration == self.smokeTSRepairReloadBaseline+1);
  uint64_t video = self.player.media.statistics.decodedVideo, audio = self.player.media.statistics.playedAudioBuffers;
  [self setPlaybackIntent:YES];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    int64_t current = [self mediaTime];
    checks[@"repairedClockIgnoresUntrustedWrapper"] = @(current > target+1500 && current < target+5000);
    checks[@"repairedVideoAndAudioAdvance"] = @(self.player.media.statistics.decodedVideo > video+15 &&
      self.player.media.statistics.playedAudioBuffers > audio+15);
    checks[@"repairedCommentsFollowWholeRecording"] = @(fabs(self.comments.renderedTime-current/1000.0) < 1.5);
    self.player.smokeUntrustedTime = NO;
    [rows addObject:@{@"repairTarget": @(target), @"afterMs": @(current), @"comments": @(self.comments.renderedTime)}];
    BOOL passed = YES; for (NSNumber *value in checks.allValues) { passed &= value.boolValue; }
    completion(@{@"success": @(passed), @"checks": checks, @"rows": rows});
  });
}
- (UIView *)aribSubtitleView:(UIView *)view {
  if ([NSStringFromClass(view.class) isEqualToString:@"VLCSampleBufferSubpictureView"]) { return view; }
  for (UIView *child in view.subviews) { UIView *found = [self aribSubtitleView:child]; if (found) { return found; } }
  return nil;
}
- (void)runARIBProbeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  NSMutableArray *rows = [NSMutableArray new];
  NSArray *checkpoints = @[@2, @4, @6.5, @8, @10, @12, @14, @17];
  __block NSUInteger next = 0; __block BOOL selected = NO; __block double selectedAt = -1;
  CFTimeInterval began = CACurrentMediaTime();
  __block NSTimer *probe;
  probe = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
    VLCMediaPlayerTrack *firstTrack = self.player.textTracks.firstObject;
    if (!selected && firstTrack.isSelected) {
      selected = YES; selectedAt = [self mediaTime]/1000.0;
    }
    double time = [self mediaTime]/1000.0;
    if (next < checkpoints.count && time >= [checkpoints[next] doubleValue]) {
      UIView *view = [self aribSubtitleView:self.movieView]; NSUInteger regions = 0;
      @try { regions = [[[view valueForKey:@"pendingSubpicture"] valueForKey:@"regions"] count]; } @catch (NSException *error) {}
      [rows addObject:@{@"time": @(time), @"regions": @(regions), @"viewFound": @(view != nil), @"selected": @(selected), @"sourceState": @([self.aribClock stateAt:time])}];
      UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:self.movieView.bounds.size];
      UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [self.movieView drawViewHierarchyInRect:self.movieView.bounds afterScreenUpdates:NO]; }];
      NSString *name = [NSString stringWithFormat:@"arib-%lu.png", (unsigned long)next];
      [UIImagePNGRepresentation(image) writeToURL:[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:name] atomically:YES];
      next++;
    }
    if (next == checkpoints.count || CACurrentMediaTime()-began > 40) {
      [probe invalidate]; probe = nil;
      BOOL comparison = rows.count == checkpoints.count;
      NSArray *expected = @[@YES, @YES, @YES, @YES, @YES, @NO, @YES, @NO];
      for (NSUInteger i=0; i<rows.count; i++) { comparison &= [rows[i][@"viewFound"] boolValue] && ([rows[i][@"regions"] unsignedIntegerValue] > 0) == [expected[i] boolValue]; }
      NSMutableArray *tracks = [NSMutableArray new];
      for (VLCMediaPlayerTrack *track in self.player.textTracks) { [tracks addObject:@{@"name": track.trackName ?: @"", @"description": track.trackDescription ?: @""}]; }
      completion(@{@"success": @(rows.count == checkpoints.count && selected && comparison), @"matchesWebTiming": @(comparison), @"rows": rows, @"tracks": tracks, @"selectedAt": @(selectedAt)});
    }
  }];
}
- (void)closeTapSmoke { [self closePlayer]; }
- (void)runNetworkProbeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self.comments loadNetworkSmokeComments];
  [self pollNetworkProbe:0 armedAt:0 rows:[NSMutableArray new] completion:completion];
}
- (void)pollNetworkProbe:(NSInteger)attempt armedAt:(double)armed rows:(NSMutableArray *)rows completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  double now = CACurrentMediaTime();
  VLCMediaStats native = self.player.media.statistics;
  NSDictionary *video = [NeoVLCFrameTap snapshot:self.movieView];
  [rows addObject:@{@"host": @(now), @"mediaMs": @([self mediaTime]), @"video": @(native.decodedVideo),
    @"nativeMs": @(self.inputStartTime+MAX(0,self.player.time.value.longLongValue)),
    @"confirmedMs": self.player.observedClock[@"positionMs"] ?: @(-1),
    @"pointAge": self.player.observedClock[@"age"] ?: @(-1), @"flowMuted": @(self.flowMuted),
    @"holding": @(self.networkFlow.holding), @"verifying": @(self.networkFlow.verifying),
    @"audio": @(native.decodedAudio), @"late": @(native.latePictures), @"lost": @(native.lostPictures),
    @"playedAudio": @(native.playedAudioBuffers), @"read": @(native.readBytes), @"demux": @(native.demuxReadBytes),
    @"arrivalAge": video[@"arrivalAge"] ?: @(-1), @"scheduledInMs": video[@"scheduledInMs"] ?: @(-1),
    @"changes": video[@"changes"] ?: @0, @"samples": video[@"samples"] ?: @0,
    @"commentTime": @(self.comments.renderedTime), @"waitingNetwork": @(self.networkReloadWaiting), @"restoreVerifying": @(self.videoReloadRecovery),
    @"state": @(self.player.state), @"buffering": @(self.buffering), @"loading": @(self.chrome.loadingVisible),
    @"reloading": @(self.reloading), @"reload": @(self.reloadGeneration)}];
  BOOL tunnel = [NSProcessInfo.processInfo.environment[@"NEO_EPG_NETWORK_MODE"] isEqual:@"tunnel"];
  if (!armed && [self mediaTime] >= (tunnel ? 94000 : 4000) && self.inputBufferReady && !self.buffering && native.decodedVideo > 10) {
    armed = now;
    NSString *base = NSProcessInfo.processInfo.environment[@"NEO_EPG_NETWORK_PROBE"];
    NSString *mode = NSProcessInfo.processInfo.environment[@"NEO_EPG_NETWORK_MODE"] ?: @"slow";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/fault/arm/%@", base, mode]];
    [[NSURLSession.sharedSession dataTaskWithURL:url] resume];
  }
  if ((armed && now-armed >= (tunnel ? 85 : 57)) || attempt >= (tunnel ? 220 : 150)) {
    VLCMedia *input = self.player.media;
    [self.chrome smokeZoomTo:2];
    BOOL stableDrawable = CGSizeEqualToSize(self.videoOutputView.bounds.size, self.chrome.normalVideoFrame.size);
    BOOL zoomedDrawableOnly = fabs(self.videoOutputView.transform.a-2) < 0.01 && CGAffineTransformIsIdentity(self.comments.transform) && self.player.media == input;
    [self showControls]; [self.chrome snapshot:@"player-pinch-zoom"];
    [self.chrome smokeZoomTo:1];
    completion(@{@"success": @(armed > 0), @"armedAt": @(armed), @"rows": rows,
      @"zoomedDrawableOnly": @(zoomedDrawableOnly && stableDrawable), @"zoomChecks": [self.chrome runZoomChecks]});
    [self.chrome smokeZoomTo:2];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [@"ready" writeToURL:[documents URLByAppendingPathComponent:@"zoom-screen-ready.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self pollNetworkProbe:attempt+1 armedAt:armed rows:rows completion:completion];
  });
}
- (void)waitForIPadWide:(BOOL)wide attempt:(NSInteger)attempt completion:(void (^)(BOOL))completion {
  BOOL ready = !self.rotatingPlayer && (self.chrome.bounds.size.width > self.chrome.bounds.size.height) == wide && self.landscape == wide;
  if (ready || attempt >= 100) { completion(ready); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self waitForIPadWide:wide attempt:attempt+1 completion:completion]; });
}
- (void)runIPadOrientationSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  int64_t before = [self mediaTime];
  VLCMedia *media = self.player.media;
  [self setOrientation:@"portrait"];
  [self waitForIPadWide:NO attempt:0 completion:^(BOOL initial) {
    [self.chrome smokePressRotation];
    [self waitForIPadWide:YES attempt:0 completion:^(BOOL button) {
      [self showControls]; [self.chrome snapshot:@"ipad-player-landscape"];
      BOOL smallThumb = [self.chrome smokeSeekThumbSize];
      [self.chrome smokeOrientationSwipe];
      [self waitForIPadWide:NO attempt:0 completion:^(BOOL swipeDown) {
        [self.chrome smokeOrientationSwipe];
        [self waitForIPadWide:YES attempt:0 completion:^(BOOL swipeUp) {
          // Exercise the same owned-content path even if this simulator permits scene rotation.
          BOOL rootWide = self.view.bounds.size.width > self.view.bounds.size.height;
          self.orientationMask = rootWide ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscapeRight;
          [self useInternalOrientation];
          [self waitForIPadWide:!rootWide attempt:0 completion:^(BOOL fallback) {
            BOOL fit = CGSizeEqualToSize(self.chrome.bounds.size, self.rotationContainer.bounds.size)
              && fabs(self.rotationContainer.center.x-self.view.bounds.size.width/2) < 1
              && fabs(self.rotationContainer.center.y-self.view.bounds.size.height/2) < 1;
            self.internalOrientation = NO; self.orientationMask = UIInterfaceOrientationMaskLandscapeRight;
            [self applyPlayerLayout:CGSizeMake(768, 1024)];
            BOOL fixedAcrossResize = self.landscape && self.chrome.bounds.size.width > self.chrome.bounds.size.height;
            [self applyPlayerLayout:self.view.bounds.size];
            [self setOrientation:@"auto"];
            BOOL automatic = !self.internalOrientation && self.landscape == (self.view.bounds.size.width > self.view.bounds.size.height);
            [self.chrome showTransientNotice:@"この表示環境では向きを変更できません。"];
            BOOL notice = self.chrome.transientNoticeVisible;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2800*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
              BOOL expired = !self.chrome.transientNoticeVisible && ![self.statusLabel.text containsString:@"向きを変更"];
              BOOL retained = self.player.media == media && !self.reloading && [self mediaTime] > before;
              NSDictionary *gestures = [self.chrome runIPadGestureChecks];
              BOOL gesturesOK = [[gestures allValues] indexOfObject:@NO] == NSNotFound;
              BOOL success = smallThumb && initial && button && swipeDown && swipeUp && fallback && fit && fixedAcrossResize && automatic && notice && expired && retained && gesturesOK;
              completion(@{@"success": @(success), @"ipadSeekThumbSmall": @(smallThumb), @"ipadSeekThumbMetrics": [self.chrome smokeSeekThumbMetrics], @"buttonRotates": @(button), @"swipeReturnsPortrait": @(swipeDown),
                @"swipeEntersLandscape": @(swipeUp), @"deniedSceneUsesOwnedRotation": @(fallback && fit),
                @"autoRestoresWindowLayout": @(automatic), @"rotationNoticeExpiresWhilePlaying": @(notice && expired),
                @"manualDirectionSurvivesWindowResize": @(fixedAcrossResize),
                @"rotationKeepsMediaAndPlayback": @(retained), @"playerGestureChecks": gestures, @"state": [self orientationDiagnosticFields]});
            });
          }];
        }];
      }];
    }];
  }];
}
- (NSDictionary<NSString *, id> *)runSeekStateSmokeChecks {
  BOOL prior = self.wantsPlayback; BOOL buffering = self.buffering;
  self.buffering = YES; [self setPlaybackIntent:YES];
  BOOL waitingIsPlaying = self.commentPiP.wantsPlaybackProvider();
  [self setPlaybackIntent:NO]; BOOL paused = !self.commentPiP.wantsPlaybackProvider();
  [self setPlaybackIntent:YES]; BOOL resumed = self.commentPiP.wantsPlaybackProvider();
  __block NSInteger count = 0;
  self.seeking = YES; NSInteger old = ++self.seekGeneration; self.seekCompletion = ^{ count++; };
  [self completeSeek:old failed:NO]; [self completeSeek:old failed:NO];
  BOOL once = count == 1;
  self.seeking = YES; NSInteger latest = ++self.seekGeneration; self.seekCompletion = ^{ count++; };
  [self completeSeek:old failed:NO]; BOOL ignoresOld = self.seeking && count == 1;
  [self completeSeek:latest failed:YES]; BOOL failedFinishes = !self.seeking && count == 2;
  self.buffering = buffering; [self setPlaybackIntent:prior];
  BOOL success = waitingIsPlaying && paused && resumed && once && ignoresOld && failedFinishes;
  return @{@"success": @(success),
    @"bufferingDoesNotMeanPaused": @(waitingIsPlaying), @"latestPauseIntent": @(paused), @"latestPlayIntent": @(resumed),
    @"completionExactlyOnce": @(once), @"lateSeekCallbackIgnored": @(ignoresOld), @"failedSeekCompletes": @(failedFinishes)};
}
- (void)runEndedSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self setPlaybackIntent:YES];
  [self seekBy:MAX(0, [self mediaLength]-1000)-[self mediaTime] completion:^{
    [self pollEndedSmoke:0 completion:completion];
  }];
}
- (void)pollEndedSmoke:(NSInteger)attempt completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (self.playbackEnded) {
    BOOL shown = self.chrome.controlsVisible;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      BOOL retained = self.chrome.controlsVisible && self.controlsHideTimer == nil;
      BOOL hidden = [self.chrome smokeTapVideoBackground] && !self.chrome.controlsVisible;
      BOOL revealed = [self.chrome smokeTapVideoBackground] && self.chrome.controlsVisible && self.controlsHideTimer == nil;
      BOOL success = shown && retained && hidden && revealed;
      completion(@{@"success": @(success), @"naturalEndShowsControls": @(shown),
        @"endedDoesNotAutoHide": @(retained), @"endedTapHides": @(hidden), @"endedTapShows": @(revealed)});
    }); return;
  }
  if (attempt >= 50) { completion(@{@"success": @NO, @"error": @"natural end timed out",
    @"state": @(self.player.state), @"time": @([self mediaTime]), @"mediaLength": @([self mediaLength]),
    @"observedTime": @(self.lastObservedTime), @"seeking": @(self.seeking), @"buffering": @(self.buffering),
    @"wantsPlayback": @(self.wantsPlayback)}); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollEndedSmoke:attempt+1 completion:completion]; });
}
- (void)runVideoTapSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self waitForTapSmokePlayback:0 completion:completion];
}
- (void)runMKVSeekSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self waitForTapSmokePlayback:0 completion:^(NSDictionary *tap) {
    if (!self.rewindCache.hasMatroskaSeekIndex) { completion(@{@"success": @NO, @"error": @"MKV video Cues unavailable"}); return; }
    int64_t expected = [self.rewindCache matroskaSeekOffset:90];
    [self.rewindCache clearMediaCacheForSmoke];
    NSTimeInterval began = CACurrentMediaTime();
    [self reloadPlaybackAtTime:90000 completion:^{
      NSDictionary *metrics = self.rewindCache.seekMetrics;
      BOOL jumped = [metrics[@"indexedRangeStart"] longLongValue] > 0 && expected > 1024*1024;
      BOOL bounded = [metrics[@"networkBytes"] longLongValue] < [metrics[@"fileBytes"] longLongValue]/2;
      BOOL ready = !self.playbackFailed && !self.reloading && llabs([self mediaTime]-90000) < 2000;
      VLCMedia *retained = self.player.media;
      [NeoVLCFrameTap monitorContent:self.movieView];
      NSInteger pictureChanges = [[NeoVLCFrameTap snapshot:self.movieView][@"changes"] integerValue];
      [self pollLatestRecoveryIntent:0 completion:^(BOOL advances) {
        NSDictionary *video = [NeoVLCFrameTap snapshot:self.movieView];
        BOOL pictures = [video[@"changes"] integerValue] >= pictureChanges+3 && [video[@"contentAge"] doubleValue] < 0.5 &&
          fabs([video[@"scheduledInMs"] doubleValue]) < 100;
        [self runLateReloadSmoke:^(BOOL late) {
          completion(@{@"success": @((BOOL)(jumped && bounded && ready && advances && pictures && late)), @"indexedTargetRange": @(jumped),
            @"boundedReloadNetwork": @(bounded), @"targetPositionPreserved": @(ready), @"videoAndTimeAdvance": @((BOOL)(advances && pictures)),
            @"pictureChanges": @([video[@"changes"] integerValue]-pictureChanges),
            @"latePreparationReusesInput": @((BOOL)(late && retained == self.player.media)), @"expectedOffset": @(expected),
            @"indexedRangeStart": metrics[@"indexedRangeStart"], @"networkBytes": metrics[@"networkBytes"],
            @"fileBytes": metrics[@"fileBytes"], @"reloadMs": @((CACurrentMediaTime()-began)*1000)});
        }];
      }];
    }];
  }];
}
- (void)runInitialResumeSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self pollInitialResumeSmoke:0 completion:completion];
}
- (void)pollInitialResumeSmoke:(NSInteger)attempt completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (self.player.isPlaying && [NeoVLCFrameTap videoViewInView:self.movieView]) {
    NSDictionary *metrics = self.rewindCache.seekMetrics;
    BOOL startsAtTarget = self.inputStartTime == 90000 && [self mediaTime] >= 90000 && [self mediaTime] < 100000 && self.reloadGeneration == 0;
    BOOL indexed = [metrics[@"indexedRangeStart"] longLongValue] > 1024*1024 && self.rewindCache.hasMatroskaSeekIndex;
    double commentsAt = self.comments.timeProvider();
    [NeoVLCFrameTap monitorContent:self.movieView];
    [self pollLatestRecoveryIntent:0 completion:^(BOOL advances) {
      [self waitForInitialVideoSmoke:0 completion:^(BOOL pictures, NSDictionary *video) {
      completion(@{@"success": @((BOOL)(startsAtTarget && indexed && advances && pictures && commentsAt >= 90 && commentsAt < 100)),
        @"startsWithoutReloadOrSeek": @(startsAtTarget), @"initialIndexedTargetRange": @(indexed),
        @"commentsUseResumePosition": @((BOOL)(commentsAt >= 90 && commentsAt < 100)), @"picturesAdvance": @(pictures),
        @"seekMetrics": metrics, @"video": video});
      }];
    }]; return;
  }
  if (attempt >= 100) { completion(@{@"success": @NO, @"state": @(self.player.state), @"time": @([self mediaTime])}); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollInitialResumeSmoke:attempt+1 completion:completion]; });
}
- (void)waitForInitialVideoSmoke:(NSInteger)attempt completion:(void (^)(BOOL, NSDictionary *))completion {
  NSDictionary *video = [NeoVLCFrameTap snapshot:self.movieView];
  BOOL pictures = [video[@"changes"] integerValue] >= 3 && [video[@"contentAge"] doubleValue] < 0.5;
  if (pictures || attempt >= 30) { completion(pictures, video); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self waitForInitialVideoSmoke:attempt+1 completion:completion];
  });
}
- (void)runLateReloadSmoke:(void (^)(BOOL))completion {
  VLCMedia *input = self.player.media; NSInteger generation = self.reloadGeneration;
  self.reloading = YES; self.restoringReload = YES; self.buffering = YES; self.inputBufferReady = NO;
  self.reloadTime = [self mediaTime]; [self armReloadDeadline]; [self.reloadTimer fire];
  BOOL retained = self.reloadTimedOut && !self.reloading && input == self.player.media;
  // Reproduce preparation finishing after the deadline on the same input.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    self.buffering = NO; self.inputBufferReady = YES; [self restoreReloadIfReady];
    [self setPlaybackIntent:YES];
    [self pollLatestRecoveryIntent:0 completion:^(BOOL playing) {
      completion(retained && playing && !self.playbackFailed && !self.reloadTimedOut && input == self.player.media && generation == self.reloadGeneration);
    }];
  });
}
- (void)runRecoverySmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  NeoBufferingUpdates *updates = [NeoBufferingUpdates new];
  __block NSInteger deliveries = 0, notifications = 0; __block float finalProgress = -1;
  updates.onUpdate = ^(float progress, NSInteger count) { deliveries++; notifications += count; finalProgress = progress; };
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (NSInteger i = 0; i < 2000; i++) { [updates submit:(float)i / 2000]; }
    [updates submit:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      BOOL coalesced = deliveries <= 4 && notifications == 2001 && finalProgress == 1;
      [updates submit:0]; [updates reset];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL reset = notifications == 2001;
        // Queue pause then play without waiting for VLC's pause notification.
        // This reproduces the window in which isPlaying still reads true.
        [self.player pause]; self.nowPlaying.playAction();
        [self pollLatestRecoveryIntent:0 completion:^(BOOL intentOrdered) {
        [self updateNowPlaying]; NSDictionary *metadata = [self.nowPlaying smokeMetadata];
        BOOL registered = [metadata[@"titleRegistered"] boolValue] && [metadata[@"targets"] integerValue] == 6 &&
          [metadata[@"seekEnabled"] boolValue] && [metadata[@"rate"] doubleValue] > 0;
        BOOL invalidRemoteSeek = !self.nowPlaying.seekAction(NAN);
        [self runLifecycleRecoverySmoke:^(NSDictionary *lifecycle) {
        [self runInterruptedVideoSmoke:^(NSDictionary *videoResult) {
        [self runStoppedVideoResumeSmoke:NO completion:^(NSDictionary *pausedFallback) {
        [self runStoppedVideoResumeSmoke:YES completion:^(NSDictionary *playingFallback) {
          NSMutableDictionary *result = [lifecycle mutableCopy]; [result addEntriesFromDictionary:videoResult];
          result[@"success"] = @([lifecycle[@"success"] boolValue] && [videoResult[@"success"] boolValue]);
          NSMutableDictionary *checks = [result mutableCopy];
          checks[@"bufferingBurstCoalesced"] = @(coalesced); checks[@"bufferingResetDropsOldUpdate"] = @(reset);
          checks[@"latestPlayFollowsQueuedPause"] = @(intentOrdered); checks[@"nowPlayingRegistered"] = @(registered);
          checks[@"invalidRemoteSeekRejected"] = @(invalidRemoteSeek);
          NSDictionary *monitor = [NeoVLCFrameTap monitoringSmoke]; [checks addEntriesFromDictionary:monitor];
          checks[@"stoppedRepairRestoresPausedPosition"] = pausedFallback;
          checks[@"stoppedRepairRestoresPlayingPosition"] = playingFallback;
          // A recreated input that never provides a usable picture must stop
          // showing a spinner and must not start another automatic reload.
          NSInteger reload = self.reloadGeneration;
          [NeoVLCFrameTap simulateResourceInterruption:self.movieView];
          self.videoReloadRecovery = YES; self.videoReloadDeadline = CACurrentMediaTime()-1;
          [self checkVideoRecovery]; [self updateControls];
          BOOL bounded = !self.videoReloadRecovery && !self.repairingVideo && !self.videoResuming &&
            self.playbackFailed && !self.chrome.loadingVisible && self.chrome.controlsVisible && self.reloadGeneration == reload;
          checks[@"failedVideoRecoveryStopsSpinnerAndReloadLoop"] = @(bounded);
          BOOL monitored = [monitor[@"freshOutputMonitored"] boolValue] && [monitor[@"freshOutputContentChangesMeasured"] boolValue] && [monitor[@"interruptedResourceSurvivesDisplayFlush"] boolValue] && [monitor[@"subtitleSnapshotSurvivesVLCMutation"] boolValue];
          // Delayed terminal notifications after failure must not route back
          // through the older background-connection recovery path.
          [self.player stop];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          BOOL noLateReload = !self.reloading && self.reloadGeneration == reload && self.playbackFailed;
          checks[@"failedVideoRecoveryIgnoresLateStop"] = @(noLateReload);
          checks[@"success"] = @((BOOL)([result[@"success"] boolValue] && coalesced && reset && intentOrdered && registered && invalidRemoteSeek && monitored &&
            [pausedFallback[@"success"] boolValue] && [playingFallback[@"success"] boolValue] && bounded && noLateReload)); completion(checks);
          });
        }];
        }];
        }];
        }];
        }];
      });
    });
  });
}
- (void)runInterruptedVideoSmoke:(void (^)(NSDictionary *))completion {
  [self setPlaybackIntent:NO];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    VLCMedia *media = self.player.media; NSURL *endpoint = self.playbackURL;
    NSInteger reload = self.reloadGeneration;
    NSInteger output = [[NeoVLCFrameTap snapshot:self.movieView][@"outputID"] integerValue];
    int64_t time = [self mediaTime];
    [self backgrounded]; [NeoVLCFrameTap simulateResourceInterruption:self.movieView]; [self foregrounded];
    BOOL preparing = self.videoResuming;
    // Commands during preparation change intent, not the paused native input.
    [self setPlaybackIntent:YES]; [self setPlaybackIntent:NO];
    [self pollInterruptedVideoSmoke:0 media:media endpoint:endpoint reload:reload output:output time:time preparing:preparing completion:completion];
  });
}
- (void)runStoppedVideoResumeSmoke:(BOOL)playing completion:(void (^)(NSDictionary *))completion {
  [self setPlaybackIntent:NO];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    int64_t time = [self mediaTime]; NSInteger reload = self.reloadGeneration;
    [self backgrounded]; [NeoVLCFrameTap simulateResourceInterruption:self.movieView];
    self.smokeStopVideoResume = YES; [self foregrounded];
    // The command while repair is pending must survive the fallback too.
    [self setPlaybackIntent:playing];
    [self pollStoppedVideoResumeSmoke:0 playing:playing time:time reload:reload completion:completion];
  });
}
- (void)pollStoppedVideoResumeSmoke:(NSInteger)attempt playing:(BOOL)playing time:(int64_t)time
                            reload:(NSInteger)reload completion:(void (^)(NSDictionary *))completion {
  if (self.reloadGeneration > reload && !self.reloading && !self.videoReloadRecovery && !self.videoResuming &&
      !self.playbackFailed && self.wantsPlayback == playing && self.player.state == (playing ? VLCMediaPlayerStatePlaying : VLCMediaPlayerStatePaused)) {
    BOOL position = llabs([self mediaTime]-time) < 2000;
    BOOL cleared = !self.repairingVideo && !self.chrome.loadingVisible;
    completion(@{@"success": @(position && cleared && self.reloadGeneration == reload+1),
      @"automaticReloadCount": @(self.reloadGeneration-reload), @"positionPreserved": @(position),
      @"loadingCleared": @(cleared), @"playingIntent": @(playing), @"mediaMs": @([self mediaTime]), @"targetMs": @(time)}); return;
  }
  if (attempt >= 150) {
    completion(@{@"success": @NO, @"state": @(self.player.state), @"reloading": @(self.reloading),
      @"videoResuming": @(self.videoResuming), @"videoReloadRecovery": @(self.videoReloadRecovery),
      @"mediaMs": @([self mediaTime]), @"targetMs": @(time), @"reloads": @(self.reloadGeneration-reload)}); return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self pollStoppedVideoResumeSmoke:attempt+1 playing:playing time:time reload:reload completion:completion];
  });
}
- (void)pollInterruptedVideoSmoke:(NSInteger)attempt media:(VLCMedia *)media endpoint:(NSURL *)endpoint
                          reload:(NSInteger)reload output:(NSInteger)output time:(int64_t)time preparing:(BOOL)preparing
                      completion:(void (^)(NSDictionary *))completion {
  NSDictionary *stats = [NeoVLCFrameTap snapshot:self.movieView];
  if (!self.videoResuming && !self.seeking && !self.reloading && self.player.state == VLCMediaPlayerStatePaused &&
      [stats[@"outputID"] integerValue] > 0 && [stats[@"outputID"] integerValue] != output) {
    BOOL sameInput = self.player.media == media && [endpoint isEqual:self.playbackURL] && self.reloadGeneration == reload;
    BOOL pausedPosition = !self.wantsPlayback && llabs([self mediaTime]-time) < 500;
    NSInteger changes = [stats[@"changes"] integerValue];
    NSInteger samples = [stats[@"samples"] integerValue];
    NSInteger decoded = self.player.media.statistics.decodedVideo;
    [self setPlaybackIntent:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSDictionary *current = [NeoVLCFrameTap snapshot:self.movieView];
      // libVLC publishes cumulative statistics from its input loop, not at
      // every displayed frame. Read-ahead can leave that snapshot unchanged
      // while queued decoded pictures are correctly being displayed.
      // Require changing, due pictures, not repeated paused-frame delivery.
      BOOL advancing = self.player.isPlaying && [self mediaTime] > time+1000 &&
        [current[@"samples"] integerValue] >= samples+24 && [current[@"changes"] integerValue] >= changes+3 &&
        [current[@"contentAge"] doubleValue] >= 0 && [current[@"contentAge"] doubleValue] < 0.5 &&
        fabs([current[@"scheduledInMs"] doubleValue]) < 100;
      completion(@{@"success": @((BOOL)(preparing && sameInput && pausedPosition && advancing)),
        @"interruptedVideoRebuiltWithoutInputReload": @((BOOL)(preparing && sameInput)),
        @"interruptedWasPreparing": @(preparing), @"interruptedSameInput": @(sameInput),
        @"interruptedReloadDelta": @(self.reloadGeneration-reload),
        @"interruptedVideoKeepsPausedPosition": @(pausedPosition),
        @"interruptedVideoResumesDecodedPictures": @(advancing),
        @"resumedPictureChanges": @([current[@"changes"] integerValue]-changes),
        @"resumedSamples": @([current[@"samples"] integerValue]-samples),
        @"resumedMediaAdvanceMs": @([self mediaTime]-time),
        @"resumedDecodedSnapshotDelta": @(self.player.media.statistics.decodedVideo-decoded)});
    }); return;
  }
  if (attempt >= 100) {
    completion(@{@"success": @NO, @"error": @"interrupted output did not prepare", @"videoResumeStage": @(self.videoResumeStage),
      @"videoResuming": @(self.videoResuming), @"seeking": @(self.seeking), @"state": @(self.player.state), @"output": stats}); return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self pollInterruptedVideoSmoke:attempt+1 media:media endpoint:endpoint reload:reload output:output time:time preparing:preparing completion:completion];
  });
}
- (void)runLifecycleRecoverySmoke:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self seekBy:5000-[self mediaTime] completion:^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSURL *oldEndpoint = self.playbackURL;
      [self setPlaybackIntent:YES]; [self inactive];
      [self backgrounded];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL keptInput = !self.transportSuspended && self.wantsPlayback && [oldEndpoint isEqual:self.playbackURL];
        [self foregrounded];
        BOOL noReload = !self.reloading && [oldEndpoint isEqual:self.playbackURL];
        BOOL backing = self.inlineBacking.superview == self.movieView &&
          [self.movieView.subviews indexOfObject:self.inlineBacking] > [self.movieView.subviews indexOfObject:self.commentPiP.view];
        [self setPlaybackIntent:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          VLCMedia *retainedMedia = self.player.media;
          [self backgrounded];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [self foregrounded];
          BOOL retained = self.player.media == retainedMedia && !self.reloading && !self.transportSuspended;
          [self pollRecoverySmoke:0 oldEndpoint:oldEndpoint completion:^(NSDictionary *result) {
            NSMutableDictionary *checks = [result mutableCopy];
            checks[@"playingBackgroundKeepsInputAndIntent"] = @((BOOL)(keptInput && noReload));
            checks[@"normalVideoMasksPiPPrimingImage"] = @(backing);
            checks[@"pausedBackgroundRetainsVLCInput"] = @(retained);
            checks[@"success"] = @((BOOL)([result[@"success"] boolValue] && keptInput && noReload && backing && retained));
            completion(checks);
          }];
          });
        });
      });
    });
  }];
}
- (void)pollRecoverySmoke:(NSInteger)attempt oldEndpoint:(NSURL *)oldEndpoint completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (!self.reloading && !self.restoringReload && !self.transportSuspended && self.player.isSeekable && self.player.state == VLCMediaPlayerStatePaused) {
    BOOL position = llabs([self mediaTime]-self.backgroundTime) < 1000;
    BOOL endpoint = self.rewindCache != nil && [oldEndpoint isEqual:self.playbackURL];
    int64_t originalLength = [self mediaLength];
    [self seekBy:2000-[self mediaTime] completion:^{
      NSInteger frames = self.commentPiP.capturedFrameCount;
      [self setPlaybackIntent:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL advancing = self.player.isPlaying && [self mediaTime] > 2500 && self.commentPiP.capturedFrameCount > frames;
        self.nowPlaying.pauseAction();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [self updateNowPlaying]; NSDictionary *metadata = [self.nowPlaying smokeMetadata];
          BOOL paused = !self.player.isPlaying && !self.wantsPlayback && [metadata[@"rate"] doubleValue] == 0;
          [self backgrounded];
          // Simulate an actually failed transport, not ordinary backgrounding.
          [self.rewindCache suspendTransport]; self.transportSuspended = YES;
          [self foregrounded];
          BOOL restoring = self.reloading;
          self.nowPlaying.playAction();
          [self pollLatestRecoveryIntent:0 completion:^(BOOL resumed) {
            BOOL savedStart = self.inputStartTime > 0 && llabs(self.inputStartTime-self.backgroundTime) < 1000;
            BOOL duration = llabs([self mediaLength]-originalLength) < 100;
            [self seekBy:-[self mediaTime] completion:^{
            BOOL earlier = !self.lastSeekFailed && self.inputStartTime == 0 && [self mediaTime] < 1000;
            [self pollLatestRecoveryIntent:0 completion:^(BOOL rewound) {
            completion(@{@"success": @(position && endpoint && advancing && paused && restoring && resumed && savedStart && duration && earlier && rewound),
              @"positionRestored": @(position), @"pausedEndpointPreserved": @(endpoint), @"rewindResumesVideoAndClock": @(advancing),
              @"remotePauseUpdatesMetadata": @(paused), @"remotePlayDuringRestoreResumes": @((BOOL)(restoring && resumed)),
              @"recoveryStartsAtSavedTime": @(savedStart),
              @"originalDurationPreserved": @(duration),
              @"rewindBeforeRecoveryPositionResumes": @(earlier && rewound),
              @"time": @([self mediaTime])});
            }];
            }];
          }];
        });
      });
    }]; return;
  }
  if (attempt >= 100) { completion(@{@"success": @NO, @"error": @"recovery timed out", @"state": VLCMediaPlayerStateToString(self.player.state), @"reloading": @(self.reloading), @"restoring": @(self.restoringReload)}); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollRecoverySmoke:attempt+1 oldEndpoint:oldEndpoint completion:completion]; });
}
- (void)pollLatestRecoveryIntent:(NSInteger)attempt completion:(void (^)(BOOL))completion {
  if (attempt >= 100) { completion(NO); return; }
  if (!self.reloading && !self.restoringReload && !self.buffering && self.player.isPlaying && self.wantsPlayback) {
    int64_t time = [self mediaTime];
    if (time < 0 || (self.lastObservedLength > 0 && time > self.lastObservedLength+1500)) { completion(NO); return; }
    NSInteger frames = self.commentPiP.capturedFrameCount;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      BOOL advancing = self.player.isPlaying && [self mediaTime] > time+400 && self.commentPiP.capturedFrameCount > frames;
      [NeoPlaybackDiagnostics record:@"smoke.playbackProgress" fields:@{@"fromMs": @(time), @"mediaMs": @([self mediaTime]),
        @"framesBefore": @(frames), @"framesAfter": @(self.commentPiP.capturedFrameCount), @"state": @(self.player.state), @"advancing": @(advancing)}];
      if (advancing) { completion(YES); }
      else { [self pollLatestRecoveryIntent:attempt+5 completion:completion]; }
    }); return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollLatestRecoveryIntent:attempt+1 completion:completion]; });
}
- (void)waitForTapSmokePlayback:(NSInteger)attempt completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  UIView *video = [NeoVLCFrameTap videoViewInView:self.movieView];
  if (!self.player.isPlaying || !video) {
    if (attempt >= 100) { completion(@{@"success": @NO, @"error": @"tap fixture playback did not start",
      @"state": @(self.player.state), @"wantsPlayback": @(self.wantsPlayback), @"buffering": @(self.buffering)}); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self waitForTapSmokePlayback:attempt + 1 completion:completion];
    }); return;
  }
  BOOL passive = NO;
  for (UIView *ancestor = video; ancestor && ancestor != self.movieView; ancestor = ancestor.superview) {
    if (!ancestor.userInteractionEnabled) { passive = YES; break; }
  }
  NSMutableDictionary *checks = [@{@"VLCOutputDoesNotReceiveTouches": @(passive), @"playingAtStart": @YES} mutableCopy];
  [self hideControls];
  BOOL shown = [self.chrome smokeTapVideoBackground] && self.chrome.controlsVisible;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    checks[@"playingTapShowsWithoutPausing"] = @(shown && self.player.isPlaying);
    BOOL hidden = [self.chrome smokeTapVideoBackground] && !self.chrome.controlsVisible;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      checks[@"playingTapHidesWithoutPausing"] = @(hidden && self.player.isPlaying);
      [self setPlaybackIntent:NO];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL paused = !self.player.isPlaying;
        BOOL revealed = [self.chrome smokeTapVideoBackground] && self.chrome.controlsVisible;
        BOOL concealed = [self.chrome smokeTapVideoBackground] && !self.chrome.controlsVisible;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          checks[@"pausedTapTogglesUIWithoutPlaying"] = @(paused && revealed && concealed && !self.player.isPlaying);
          checks[@"success"] = [[checks allValues] indexOfObject:@NO] == NSNotFound ? @YES : @NO;
          [self setPlaybackIntent:YES]; completion(checks);
        });
      });
    });
  });
}
- (void)runControlsSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  BOOL playing = self.player.isPlaying; [self setPlaybackIntent:NO];
  NSMutableDictionary *checks = [[self.chrome runInteractionChecks] mutableCopy];
  self.chrome.autoHide = YES; [self hideControls];
  BOOL showTap = [self.chrome smokeTapVideoBackground] && self.chrome.controlsVisible;
  BOOL hideTap = [self.chrome smokeTapVideoBackground] && !self.chrome.controlsVisible;
  checks[@"tapShows"] = @(showTap); checks[@"tapHides"] = @(hideTap);
  [self.chrome smokeTapVideoBackground];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CALayer *visibleLayer = self.chrome.controls.layer.presentationLayer ?: self.chrome.controls.layer;
    checks[@"fadeInCompletes"] = self.chrome.controlsVisible && visibleLayer.opacity > 0.99 ? @YES : @NO;
    [self performPlayerAction:@"interaction"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      checks[@"interactionRestartsHideTimer"] = @(self.chrome.controlsVisible);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Still visible at 2.2 seconds: this detects the previous 2s timeout.
        checks[@"visibleBeforeTwoPointFiveSeconds"] = self.chrome.controlsVisible ? @YES : @NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          checks[@"pausedIdleHides"] = self.chrome.controlsVisible ? @NO : @YES;
          // The auto-hide timer may execute late on a loaded simulator. Check
          // its 2.5s visibility separately, then wait for the actual fade end.
          [self waitForHiddenControlsFade:0 completion:^(BOOL faded) {
          checks[@"fadeOutCompletes"] = @(faded);
          [self beginScrubbing];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            checks[@"scrubbingStaysVisible"] = @(self.chrome.controlsVisible);
            [self cancelScrubbing];
            // Verify with the same run-loop timer ordering as auto-hide.
            // A due main-dispatch block can run before overdue NSTimers when
            // a loaded simulator resumes the run loop.
            NSTimer *verifyHide = [NSTimer timerWithTimeInterval:2.7 repeats:NO block:^(NSTimer *timer) {
              checks[@"scrubbingEndRestartsHide"] = self.chrome.controlsVisible ? @NO : @YES;
              checks[@"success"] = [[checks allValues] indexOfObject:@NO] == NSNotFound ? @YES : @NO;
              if (playing) { [self setPlaybackIntent:YES]; }
              completion(checks);
            }];
            [NSRunLoop.mainRunLoop addTimer:verifyHide forMode:NSRunLoopCommonModes];
          });
          }];
        });
      });
    });
  });
}
- (void)waitForHiddenControlsFade:(NSInteger)attempt completion:(void (^)(BOOL))completion {
  CALayer *layer = self.chrome.controls.layer.presentationLayer ?: self.chrome.controls.layer;
  BOOL faded = !self.chrome.controlsVisible && layer.opacity < 0.01;
  if (faded || attempt >= 40) { completion(faded); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.025*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self waitForHiddenControlsFade:attempt+1 completion:completion];
  });
}
- (NSDictionary<NSString *, id> *)runLayoutSmokeChecks {
  self.chrome.autoHide = NO; [self showControls];
  BOOL initialPortrait = [self.chrome checkInitialPortrait];
  [self.chrome snapshot:@"player-initial-portrait"];
  self.smokeSavedFrame = self.view.frame;
  self.view.frame = CGRectMake(0, 0, 844, 390);
  [self applyPlayerLayout:self.view.bounds.size]; [self.view layoutIfNeeded];
  UIEdgeInsets safe = self.view.safeAreaInsets;
  BOOL full = CGRectGetMinX(self.movieView.frame) >= safe.left && CGRectGetMaxX(self.movieView.frame) <= self.view.bounds.size.width - safe.right &&
    CGRectGetMinY(self.movieView.frame) >= safe.top && CGRectGetMaxY(self.movieView.frame) == self.view.bounds.size.height;
  BOOL overlay = self.header.frame.size.height < 80 && CGRectGetMaxY(self.controls.frame) <= 390;
  NSMutableDictionary *layout = [[self.chrome runLayoutChecks] mutableCopy];
  layout[@"initialPortrait"] = @(initialPortrait);
  layout[@"success"] = initialPortrait && [layout[@"success"] boolValue] ? @YES : @NO;
  NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  [[NSJSONSerialization dataWithJSONObject:layout options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"player-ui-smoke.json"] atomically:YES];
  return @{@"success": @(full && overlay && self.frameTapInstalled && self.commentPiP.consumedFrameCount >= 24 && self.commentPiP.composedFrameCount >= 24),
    @"landscapeFillsView": @(full), @"controlsOverlay": @(overlay), @"frameTapInstalled": @(self.frameTapInstalled),
    @"capturedFrames": @(self.commentPiP.capturedFrameCount), @"composedFrames": @(self.commentPiP.composedFrameCount),
    @"consumedFrames": @(self.commentPiP.consumedFrameCount),
    @"pipPossible": @(self.commentPiP.possible),
    @"pipStatus": self.commentPiP.status ?: @"", @"commentsReady": @(self.comments.ready)};
}
- (NSDictionary<NSString *, id> *)finishLayoutSmokeSnapshot {
  NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:self.view.bounds.size];
  NSData *landscape = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
    [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
  }];
  [landscape writeToFile:[directory stringByAppendingPathComponent:@"player-landscape-smoke.png"] atomically:YES];
  UIView *video = [NeoVLCFrameTap videoViewInView:self.movieView];
  CGRect rect = video ? [video convertRect:video.bounds toView:self.movieView] : CGRectZero;
  CGSize viewport = self.movieView.bounds.size;
  CGFloat ratio = 640.0 / 360.0; // The synthetic fixture's known presentation ratio.
  CGFloat width = MIN(viewport.width, viewport.height * ratio), height = width / ratio;
  BOOL fitted = fabs(rect.size.width - width) < 2 && fabs(rect.size.height - height) < 2 &&
    fabs(rect.origin.x - (viewport.width - width) / 2) < 2 && fabs(rect.origin.y - (viewport.height - height) / 2) < 2;
  self.view.frame = self.smokeSavedFrame; [self applyPlayerLayout:self.view.bounds.size]; [self.view layoutIfNeeded];
  return @{@"videoFillsFit": @(fitted), @"videoRect": NSStringFromCGRect(rect)};
}
- (void)runReloadSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (self.pipActive) { [self.commentPiP stop]; }
  [self setPlaybackIntent:NO]; [self performPlayerAction:@"rate:1.25"]; [self performPlayerAction:@"cache:7"];
  __weak typeof(self) weakSelf = self;
  [self seekBy:3000 - [self mediaTime] completion:^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf reloadPlayback]; [weakSelf pollReloadSmoke:0 expectedPlaying:NO completion:completion];
    });
  }];
}
- (void)pollReloadSmoke:(NSInteger)attempt expectedPlaying:(BOOL)playing completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (!self.reloading && !self.restoringReload && self.player.isPlaying == playing && self.player.isSeekable) {
    int64_t restored = [self mediaTime];
    BOOL position = llabs(restored - self.reloadTime) < 1000;
    BOOL settings = fabs(self.player.rate - 1.25) < 0.01 && self.networkCaching == 7000;
    BOOL statusCleared = self.statusLabel.isHidden && ![self.statusLabel.text containsString:@"再読み込み"];
    if (!position || !settings || !self.comments.ready || !statusCleared) {
      completion(@{@"success": @NO, @"phase": playing ? @"playing" : @"paused", @"position": @(restored), @"expected": @(self.reloadTime), @"rate": @(self.player.rate)}); return;
    }
    if (!playing) {
      [self.chrome updatePlayback:NO current:restored / 1000 duration:[self mediaLength] / 1000];
      [self.chrome showControls:YES]; [self.chrome snapshot:@"player-paused-portrait"];
      [self setPlaybackIntent:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reloadPlayback]; [self pollReloadSmoke:0 expectedPlaying:YES completion:completion];
      });
    } else {
      [self setOrientation:@"landscape"];
      [self waitForSmokeOrientation:UIInterfaceOrientationLandscapeRight attempt:0 completion:^(BOOL locked) {
        [self.chrome showSmokePanel:@"program"]; [self.chrome snapshot:@"player-info-landscape"];
        [self.chrome showSmokePanel:@"controls"]; [self.chrome snapshot:@"player-controls-landscape"];
        [self.chrome snapshotDrawer:@"player-drawer-landscape"];
        [self.chrome snapshotPiPNotice:@"player-pip-notice"];
        [self.chrome snapshotSettings:@"general" name:@"player-settings-landscape"];
        [self.chrome snapshotSettings:@"comments" name:@"player-comment-settings-landscape"];
        [self.chrome snapshotSettings:@"subtitles" name:@"player-subtitle-settings-landscape"];
        [self setOrientation:@"portrait"];
        [self waitForSmokeOrientation:UIInterfaceOrientationPortrait attempt:0 completion:^(BOOL portrait) {
          [self.chrome showSmokePanel:@"program"]; [self.chrome snapshot:@"player-info-portrait"];
          [self.chrome showSmokePanel:@"rules"]; [self.chrome snapshot:@"player-rules-portrait"];
          [self.chrome showSmokePanel:@"settings"]; [self.chrome snapshot:@"player-settings-portrait"];
          [self.chrome snapshotSettings:@"comments" name:@"player-comment-settings-portrait"];
          [self.chrome snapshotSettings:@"subtitles" name:@"player-subtitle-settings-portrait"];
          [self.chrome showSmokePanel:@"controls"]; [self.chrome snapshot:@"player-controls-portrait"];
          [self setOrientation:@"auto"];
          completion(@{@"success": locked && portrait ? @YES : @NO, @"reloadStatusCleared": @(statusCleared), @"pausedReload": @YES, @"playingReload": @YES, @"positionPreserved": @(position), @"ratePreserved": @(settings), @"commentsPreserved": @(self.comments.ready), @"landscapeLock": @(locked), @"portraitLock": @(portrait), @"autoOrientation": self.orientationMask == UIInterfaceOrientationMaskAllButUpsideDown ? @YES : @NO});
        }];
      }];
    }
    return;
  }
  if (attempt >= 30 || self.player.state == VLCMediaPlayerStateError) { completion(@{@"success": @NO, @"error": @"reload timed out", @"reloading": @(self.reloading), @"restoring": @(self.restoringReload), @"state": VLCMediaPlayerStateToString(self.player.state)}); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollReloadSmoke:attempt + 1 expectedPlaying:playing completion:completion]; });
}
// The simulator's scene rotation can outlast a fixed delay under CI load.
- (void)waitForSmokeOrientation:(UIInterfaceOrientation)orientation attempt:(NSInteger)attempt completion:(void (^)(BOOL))completion {
  UIInterfaceOrientationMask mask = orientation == UIInterfaceOrientationPortrait ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscapeRight;
  BOOL wide = orientation != UIInterfaceOrientationPortrait;
  BOOL settled = self.orientationMask == mask && self.view.window.windowScene.interfaceOrientation == orientation &&
    (self.view.bounds.size.width > self.view.bounds.size.height) == wide && !self.rotatingPlayer && !self.transitionCoordinator;
  if (settled || attempt >= 30) { [self.view layoutIfNeeded]; completion(settled); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self waitForSmokeOrientation:orientation attempt:attempt + 1 completion:completion];
  });
}
- (BOOL)startPiPSmoke {
  if (!self.commentPiP.possible) { return NO; }
  [self.commentPiP start]; return YES;
}
- (void)runExitSmokeFromHost:(UIViewController *)host completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  __block BOOL delivered = NO;
  void (^finish)(NSDictionary *) = ^(NSDictionary *result) { if (!delivered) { delivered = YES; completion(result); } };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (!delivered) { finish(@{@"success": @NO, @"error": @"interactive exit timed out", @"closing": @(self.closing),
      @"dismissing": @(self.dismissingPlayer), @"rotating": @(self.rotatingPlayer), @"interactive": @(self.playerTransition.interactive),
      @"hasCoordinator": @(self.transitionCoordinator != nil), @"nativeState": @(self.player.state)}); }
  });
  // Reload checks end by unlocking orientation, which may rotate the simulator
  // again. Exercise the portrait-only back gesture after that rotation settles.
  [self setOrientation:@"portrait"];
  [self waitForSmokeOrientation:UIInterfaceOrientationPortrait attempt:0 completion:^(BOOL portrait) {
    if (!portrait) { finish(@{@"success": @NO, @"error": @"portrait back fixture did not settle"}); return; }
    [self runInteractiveBackCancellationSmoke:host completion:^(NSDictionary *drag) {
      [self runCommittedExitSmokeFromHost:host drag:drag completion:finish];
    }];
  }];
}
- (void)runInteractiveBackCancellationSmoke:(UIViewController *)host completion:(void (^)(NSDictionary *))completion {
  VLCMedia *media = self.player.media; NSURL *endpoint = self.playbackURL;
  [self performPlayerAction:@"back-begin"];
  if (!self.dismissingPlayer || !self.playerTransition.interactive) {
    completion(@{@"playerBackTracksFinger": @NO, @"cancelledPlayerBackKeepsInput": @NO,
      @"playerDismissalStartsBeforeNativeStop": @NO, @"error": @"portrait back did not begin",
      @"rotatingAtBegin": @(self.rotatingPlayer), @"coordinatorAtBegin": @(self.transitionCoordinator != nil)}); return;
  }
  // A real pan supplies updates on successive display cycles. Do not send the
  // only update before UIKit has created and committed its dismissal context.
  [self waitForBackSmokeContext:0 completion:^(BOOL ready) {
  if (!ready) { [self performPlayerAction:@"back-cancel"]; completion(@{@"playerBackTracksFinger": @NO, @"error": @"interactive context was not ready"}); return; }
  [CATransaction flush];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC/30)), dispatch_get_main_queue(), ^{
  [self performPlayerAction:@"back-progress:0.2"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC/30)), dispatch_get_main_queue(), ^{
  [self performPlayerAction:@"back-progress:0.4"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CGFloat position = self.view.layer.presentationLayer.transform.m41;
    BOOL following = self.playerTransition.interactive && self.transitionCoordinator.isInteractive &&
      fabs(self.transitionCoordinator.percentComplete-0.4) < 0.02 && position > 1 && position < self.view.bounds.size.width-1;
    BOOL early = self.dismissingPlayer && !self.closing && self.player.media == media;
    [self performPlayerAction:@"back-cancel"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      BOOL retained = !self.dismissingPlayer && !self.closing && !self.playerTransition.interactive &&
        host.presentedViewController == self && self.player.media == media && [endpoint isEqual:self.playbackURL] &&
        CGAffineTransformIsIdentity(self.view.transform);
      completion(@{@"playerBackTracksFinger": @(following), @"cancelledPlayerBackKeepsInput": @(retained),
        @"playerDismissalStartsBeforeNativeStop": @(early), @"dragX": @(position)});
    });
  });
  });
  });
  }];
}
- (void)waitForBackSmokeContext:(NSInteger)attempt completion:(void (^)(BOOL))completion {
  BOOL ready = self.transitionCoordinator != nil && self.transitionCoordinator.isInteractive;
  if (ready || attempt >= 60) { completion(ready); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC/60)), dispatch_get_main_queue(), ^{
    [self waitForBackSmokeContext:attempt+1 completion:completion];
  });
}
- (void)runCommittedExitSmokeFromHost:(UIViewController *)host drag:(NSDictionary *)drag completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  BOOL horizontalDismissal = self.transitioningDelegate == self.playerTransition &&
    [[self.playerTransition animationControllerForDismissedController:self] isKindOfClass:NeoSwipeBackAnimator.class];
  [self setOrientation:@"landscape"];
  [self waitForSmokeOrientation:UIInterfaceOrientationLandscapeRight attempt:0 completion:^(BOOL locked) {
    if (!locked) { completion(@{@"success": @NO, @"landscapeBeforeExit": @NO}); return; }
    self.onNavigate = ^(NSString *route) {
      [self waitForHostPortrait:host attempt:0 completion:^(BOOL portrait) {
        BOOL faster = self.playerRotationDuration > 0 && self.playerRotationDuration < self.systemRotationDuration;
        BOOL cleanRotation = !self.rotatingPlayer && CGAffineTransformIsIdentity(self.rotationContainer.transform) && CGAffineTransformIsIdentity(self.chrome.transform);
        cleanRotation = cleanRotation && self.rotationHandoffDelta < 1;
        NSMutableDictionary *result = [@{@"success": portrait && horizontalDismissal && faster && cleanRotation &&
            [drag[@"playerBackTracksFinger"] boolValue] && [drag[@"cancelledPlayerBackKeepsInput"] boolValue] &&
            [drag[@"playerDismissalStartsBeforeNativeStop"] boolValue] && [route isEqualToString:@"recorded"] ? @YES : @NO,
          @"playerUsesHorizontalBackAnimator": @(horizontalDismissal), @"landscapeBeforeExit": @YES,
          @"playerRotationUsesShorterDuration": @(faster), @"playerRotationRestoresTransforms": @(cleanRotation),
          @"playerRotationHandoffDelta": @(self.rotationHandoffDelta),
          @"playerRotationDurationMs": @(self.playerRotationDuration*1000), @"systemRotationDurationMs": @(self.systemRotationDuration*1000),
          @"sidebarRouteDelivered": [route isEqualToString:@"recorded"] ? @YES : @NO, @"hostPortraitAfterExit": portrait ? @YES : @NO,
          @"hostPortraitOnly": host.supportedInterfaceOrientations == UIInterfaceOrientationMaskPortrait ? @YES : @NO,
          @"hostClass": NSStringFromClass(host.class), @"hostOrientationMask": @(host.supportedInterfaceOrientations),
          @"sceneOrientation": @(host.view.window.windowScene.interfaceOrientation), @"hostFrame": NSStringFromCGRect(host.view.bounds)} mutableCopy];
        [result addEntriesFromDictionary:drag]; completion(result);
      }];
    };
    self.pendingRoute = @"recorded";
    [self performPlayerAction:@"back-begin"];
    if (!self.dismissingPlayer || !self.playerTransition.interactive) {
      completion(@{@"success": @NO, @"error": @"committed back did not begin",
        @"rotatingAtBegin": @(self.rotatingPlayer), @"coordinatorAtBegin": @(self.transitionCoordinator != nil)}); return;
    }
    [self performPlayerAction:@"back-progress:0.65"];
    [self performPlayerAction:@"back-finish"];
  }];
}
- (void)waitForHostPortrait:(UIViewController *)host attempt:(NSInteger)attempt completion:(void (^)(BOOL))completion {
  BOOL portrait = host.presentedViewController == nil && host.view.window.windowScene.interfaceOrientation == UIInterfaceOrientationPortrait &&
    host.view.bounds.size.height > host.view.bounds.size.width && host.supportedInterfaceOrientations == UIInterfaceOrientationMaskPortrait && !host.transitionCoordinator;
  if (portrait || attempt >= 30) { completion(portrait); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self waitForHostPortrait:host attempt:attempt + 1 completion:completion];
  });
}
- (NSDictionary<NSString *, id> *)piPSmokeState {
  return @{@"pipActive": @(self.commentPiP.active), @"pipPossible": @(self.commentPiP.possible),
    @"pipSupported": @([AVPictureInPictureController isPictureInPictureSupported]),
    @"pipStatus": self.commentPiP.status ?: @"", @"capturedFrames": @(self.commentPiP.capturedFrameCount),
    @"composedFrames": @(self.commentPiP.composedFrameCount), @"consumedFrames": @(self.commentPiP.consumedFrameCount)};
}
#endif
- (void)play { [self setPlaybackIntent:YES]; }
- (void)pause { [self setPlaybackIntent:NO]; }
- (void)seekBy:(int64_t)offset completion:(dispatch_block_t)completion {
  if ((self.networkFlow.holding || self.networkFlow.verifying) && !self.flowResyncing) {
    int64_t target = [self mediaTime]+offset;
    [self resetNetworkFlow]; offset = target-[self mediaTime];
  }
  if (self.videoResuming && !self.videoResumePriming) {
    dispatch_block_t superseded = self.videoResumeDeferredCompletion;
    self.videoResumeDeferredTime = @(MAX(0, [self mediaTime]+offset)); self.videoResumeDeferredCompletion = completion;
    if (superseded) { superseded(); } return;
  }
  if (self.closing || !self.player.isSeekable) { completion(); return; }
  [NeoVLCFrameTap clearARIBView:self.movieView];
  [self sampleHistory]; [self.history flush];
  [self completeSeek:self.seekGeneration failed:NO];
  int64_t length = [self mediaLength];
  int64_t target = MAX(0, [self mediaTime] + offset);
  if (length > 0) { target = MIN(length, target); }
  if (!self.videoResumePriming) { self.backgroundPositionValid = NO; }
  if (target < self.inputStartTime) {
    [self reloadPlaybackAtTime:target completion:completion]; return;
  }
  self.inputClockGuardUntil = 0; // An explicit seek can legitimately jump far ahead.
  self.playbackEnded = NO; self.seeking = YES; self.seekCompletion = completion;
  self.lastSeekFailed = NO;
  NSInteger generation = ++self.seekGeneration;
  self.seekStartedAt = CACurrentMediaTime();
  self.awaitingSeekVideo = YES;
  [self observeSeekFrames];
  [NeoPlaybackDiagnostics beginSeek:generation];
  [NeoPlaybackDiagnostics record:@"seek.start" fields:@{@"fromMs": @([self mediaTime]), @"targetMs": @(target),
    @"pip": @(self.pipActive), @"restoring": @(self.restoringReload)}];
  [self.chrome previewSeek:target / 1000];
  [self.rewindCache beginSeek:target / 1000.0]; [self.streamingSession beginSeek:target / 1000.0]; [self.comments beginSeek:target / 1000.0]; [self.commentPiP seekDiscontinuity:target / 1000.0];
  __weak typeof(self) weakSelf = self;
  self.seekTimer = [NSTimer timerWithTimeInterval:20 repeats:NO block:^(NSTimer *timer) {
    if (weakSelf.seekGeneration != generation || !weakSelf.seeking || weakSelf.closing) { return; }
    BOOL wasRestoring = weakSelf.restoringReload;
    [NeoPlaybackDiagnostics record:@"seek.timeout" fields:@{@"restart": @(!wasRestoring), @"targetMs": @(target)}];
    [weakSelf completeSeek:generation failed:YES];
    if (wasRestoring) { return; }
    // Re-open the same Range endpoint at the requested time. Keep PiP alive;
    // a second deadline bounds recovery instead of leaving it stuck forever.
    weakSelf.reloadTime = target; weakSelf.reloadPlaying = weakSelf.wantsPlayback;
    NSMutableArray *tracks = [NSMutableArray new];
    for (VLCMediaPlayerTrack *track in weakSelf.player.textTracks) { if (track.isSelected) { [tracks addObject:track.trackId]; } }
    weakSelf.reloadTextTracks = tracks;
    weakSelf.reloadGeneration += 1;
    weakSelf.reloading = YES; weakSelf.restoringReload = NO; [weakSelf armReloadDeadline];
    [weakSelf.commentPiP seekDiscontinuity:target / 1000.0]; [weakSelf.player stop];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.seekTimer forMode:NSRunLoopCommonModes];
  dispatch_block_t finished = ^{
    [NeoPlaybackDiagnostics record:@"seek.callback" fields:@{@"generation": @(generation)}];
    [weakSelf completeSeek:generation failed:NO];
  };
  if ([self wholeFileClock]) {
    self.tsPositionPending = YES; self.tsPositionTarget = target;
    self.tsPositionIssued = NO; self.tsPositionCallback = NO;
    // A normal seek keeps the current picture and active input. Restoration
    // alone needs hidden/muted priming; both paths still verify new due video.
    BOOL priming = self.reloading || self.videoResumePriming || !self.wantsPlayback;
    self.tsPositionWaitForPause = NO; self.tsPositionResumeAt = -100;
    self.videoOutputView.hidden = priming;
    if ([self isStreaming] && priming) {
      if (!self.restoreMuted) { self.restorePreviousMute = self.player.audio.isMuted; self.restoreMuted = YES; }
      self.player.audio.muted = YES;
      self.tsPositionWaitForPause = self.player.state != VLCMediaPlayerStatePaused;
      [self.player pause];
    } else if (priming) { [self.player pause]; }
    [self armTSPosition]; [self updateLoadingState]; return;
  }
  BOOL accepted;
  if (!self.hasInputLength && self.player.media.length.value.longLongValue <= 0 && length > 0) {
    // HTTP TS cannot use VLC's PCR binary seek (HTTP is not CAN_FASTSEEK).
    // Use its supported byte-position seek with the Web file duration, rather
    // than silently resetting to zero or pretending the time seek succeeded.
    accepted = [self.player respondsToSelector:@selector(setOnSeekCompletion:)];
    if (accepted) { self.player.onSeekCompletion = finished; self.player.position = self.inputStartTime > 0 ? (double)(target-self.inputStartTime) / MAX(1, length-self.inputStartTime) : (double)target / length; }
  } else {
    // The offset convenience method reads VLC's clock again internally.
    // Set the relative input time directly so an invalid interpolation point
    // cannot turn the intended target into a completely different seek.
    accepted = [self.player respondsToSelector:@selector(setOnSeekCompletion:)];
    if (accepted) {
      self.player.onSeekCompletion = finished;
      self.player.time = [VLCTime timeWithInt:(int)(target-self.inputStartTime)];
    }
  }
  if (!accepted) { [self completeSeek:generation failed:YES]; }
  [NeoPlaybackDiagnostics record:@"seek.accepted" fields:@{@"accepted": @(accepted), @"bytePositionFallback": @(!self.hasInputLength && self.player.media.length.value.longLongValue <= 0 && length > 0)}];
  [NeoPlaybackDiagnostics record:@"seek.issued" fields:@{@"targetMs": @(target), @"afterMs": @((CACurrentMediaTime()-self.seekStartedAt)*1000)}];
  [self.commentPiP invalidatePlaybackState]; [self scheduleControlsHide];
}
- (void)completeSeek:(NSInteger)generation failed:(BOOL)failed {
  if (!self.seeking || generation != self.seekGeneration) { return; }
  if (!failed && self.tsPositionPending) { return; }
  if (failed && self.tsPositionPending) {
    self.tsPositionPending = NO; [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
    [NeoVLCFrameTap bindFrameArrival:self.movieView handler:nil];
  }
  if (!failed && self.player.state == VLCMediaPlayerStatePaused) {
    int64_t position = [self wholeFileClock]
      ? self.player.nativeTimeMs : self.inputStartTime+MAX(0,self.player.time.value.longLongValue);
    position = [self guardStreamingTime:position];
    if (position >= 0 && (self.lastObservedLength <= 0 || position <= self.lastObservedLength+1500)) { self.lastObservedTime = position; }
  }
  // Establish the new history position while it is still marked as a seek.
  // Even a short jump or a delayed completion must not become watched time.
  if (!self.closing) { [self sampleHistory]; }
  [self.seekTimer invalidate]; self.seekTimer = nil; self.seeking = NO; [self.comments endSeek];
  if (failed) { self.awaitingSeekVideo = NO; }
  [self updateSeekVideoReady];
  if (!failed && !self.playbackEnded) { [self rememberPlaybackTime]; }
  self.lastSeekFailed = failed;
  [NeoPlaybackDiagnostics record:@"seek.complete" fields:@{@"failed": @(failed), @"mediaMs": @([self mediaTime]),
    @"durationMs": @((CACurrentMediaTime() - self.seekStartedAt) * 1000)}];
  [self.chrome updatePlayback:self.wantsPlayback current:[self mediaTime] / 1000 duration:[self mediaLength] / 1000];
  [self.chrome finishSeekPreview];
  dispatch_block_t completion = self.seekCompletion; self.seekCompletion = nil;
  if (!self.closing) {
    [self applyPlaybackIntent]; [self sampleHistory]; [self.history flush];
    [self.commentPiP invalidatePlaybackState];
    if (failed) { self.statusLabel.text = @"シークできませんでした。再読み込みで再試行できます。"; [self.chrome updateDiagnostics]; [self showControls]; }
  }
  if (completion) { completion(); }
}
- (void)armReloadDeadline {
  [self.reloadTimer invalidate]; __weak typeof(self) weakSelf = self;
  NSInteger generation = self.reloadGeneration;
  self.reloadTimer = [NSTimer timerWithTimeInterval:25 repeats:NO block:^(NSTimer *timer) {
    if (!weakSelf || weakSelf.closing || !weakSelf.reloading || weakSelf.reloadGeneration != generation) { return; }
    BOOL pendingHealthyInput = weakSelf.player.state != VLCMediaPlayerStateStopped && weakSelf.player.state != VLCMediaPlayerStateError;
    if (weakSelf.rewindCache || weakSelf.streamingSession) {
      // Never reuse the late start-paused input after a network opening
      // deadline. Its decoder/clock queues can resume with obsolete deadlines.
      weakSelf.networkReloadWaiting = YES; weakSelf.reloading = NO; weakSelf.restoringReload = NO;
      weakSelf.reloadTimedOut = NO; weakSelf.awaitingEndpoint = YES; weakSelf.inputBufferReady = NO;
      weakSelf.tsPositionPending = NO; [weakSelf.tsPositionTimer invalidate]; weakSelf.tsPositionTimer = nil;
      weakSelf.player.onSeekCompletion = nil; [weakSelf.player stop];
      [NeoPlaybackDiagnostics record:@"input.retiredAfterDeadline" fields:@{@"targetMs": @(weakSelf.reloadTime)}];
      weakSelf.networkRetryTimer = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *retry) { [weakSelf retryNetworkReload]; }];
      [NSRunLoop.mainRunLoop addTimer:weakSelf.networkRetryTimer forMode:NSRunLoopCommonModes];
      [weakSelf retryNetworkReload]; [weakSelf updateLoadingState]; return;
    }
    [weakSelf completeSeek:weakSelf.seekGeneration failed:YES]; [weakSelf finishReload:YES];
    weakSelf.reloadTimedOut = pendingHealthyInput;
    [NeoPlaybackDiagnostics record:@"input.reloadDeadline" fields:@{@"retained": @(pendingHealthyInput), @"state": @(weakSelf.player.state)}];
    weakSelf.statusLabel.text = @"再読み込みできませんでした。接続を確認して再試行してください。";
    [weakSelf.chrome updateDiagnostics]; [weakSelf showControls];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.reloadTimer forMode:NSRunLoopCommonModes];
}
- (void)releaseRestoreMute {
  if (self.restoreMuted) { self.player.audio.muted = self.restorePreviousMute; self.restoreMuted = NO; }
}
- (void)waitForStreamingNetwork {
  if (self.closing) { return; }
  self.networkReloadWaiting = YES; self.reloading = NO; self.restoringReload = NO;
  self.reloadTimedOut = NO; self.awaitingEndpoint = YES; self.inputBufferReady = NO;
  self.tsPositionPending = NO; [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
  [self.reloadTimer invalidate]; self.reloadTimer = nil; self.player.onSeekCompletion = nil; [self.player stop];
  [self.networkRetryTimer invalidate];
  __weak typeof(self) weakSelf = self;
  self.networkRetryTimer = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) { [weakSelf retryNetworkReload]; }];
  [NSRunLoop.mainRunLoop addTimer:self.networkRetryTimer forMode:NSRunLoopCommonModes];
  [NeoPlaybackDiagnostics record:@"hls.networkWaiting" fields:@{@"targetMs": @(self.reloadTime)}];
  // A reachable control API may coexist with an unavailable encoder/playlist.
  // Let the two-second timer initiate the next attempt; probing immediately
  // here would recursively reopen a failing playlist without any backoff.
  [self updateLoadingState];
}
- (void)retryNetworkReload {
  if (self.closing || !self.networkReloadWaiting || self.networkProbePending) { return; }
  self.networkProbePending = YES; NSInteger generation = self.reloadGeneration;
  __weak typeof(self) weakSelf = self;
  void (^probe)(BOOL) = ^(BOOL available) {
    weakSelf.networkProbePending = NO;
    if (!weakSelf || weakSelf.closing || !weakSelf.networkReloadWaiting || generation != weakSelf.reloadGeneration || !available) { return; }
    [NeoPlaybackDiagnostics record:@"input.networkAvailable" fields:@{@"targetMs": @(weakSelf.reloadTime)}];
    weakSelf.videoReloadRecovery = YES;
    [weakSelf reloadPlaybackAtTime:weakSelf.reloadTime completion:nil];
  };
  if (self.streamingSession) { [self.streamingSession checkAvailability:probe]; }
  else { [self.rewindCache checkAvailability:probe]; }
}
- (int64_t)mediaLength { return MAX(self.lastObservedLength, MAX(0, self.player.media.length.value.longLongValue)); }
- (int64_t)mediaTime {
  if (self.networkReloadWaiting || (self.videoReloadRecovery && !self.reloading)) { return self.reloadTime; }
  if (self.tsPositionPending) { return self.tsPositionTarget; }
  if (self.videoResuming) { return self.videoResumeTime; }
  if (self.player.state == VLCMediaPlayerStatePaused && !self.reloading && !self.seeking && !self.videoResuming) {
    return self.lastObservedTime;
  }
  if (self.networkFlow.holding || self.networkFlow.verifying || self.flowResyncing) { return self.flowHoldTime; }
  BOOL ts = [self wholeFileClock];
  int64_t raw = ts ? self.player.nativeTimeMs : self.player.time.value.longLongValue;
  if (ts && raw < 0) { return self.lastObservedTime; }
  int64_t time = [self guardStreamingTime:self.inputStartTime + MAX(0, raw)];
  int64_t length = self.lastObservedLength;
  // VLCKit's interpolation can briefly reuse an old host-time point when
  // an input starts. Do not turn that impossible clock value into a seek,
  // comment jump, history position or rewind-cache eviction.
  BOOL startupJump = CACurrentMediaTime() < self.inputClockGuardUntil && time > self.inputStartTime+10000;
  if (startupJump || (length > 0 && time > length+1500)) {
    int64_t retained = MAX(self.inputStartTime, self.lastObservedTime);
    if (length > 0) { retained = MIN(length, retained); }
    if (!self.invalidClockReported) {
      self.invalidClockReported = YES;
      [NeoPlaybackDiagnostics record:@"clock.invalid" fields:@{@"rawMs": @(raw), @"mediaMs": @(time),
        @"retainedMs": @(retained), @"lengthMs": @(length)}];
    }
    return retained;
  }
  return time;
}
- (BOOL)isMediaSeekable { return self.player.isSeekable; }
- (BOOL)isMediaPlaying { return self.player.isPlaying; }

- (void)closePlayer {
  [NeoVLCFrameTap bindFrameArrival:self.movieView handler:nil];
  [self beginPlayerDismissal:NO];
}
- (void)beginPlayerDismissal:(BOOL)interactive {
  if (self.closing || self.dismissingPlayer || self.rotatingPlayer || self.transitionCoordinator) { return; }
  self.dismissalPresenter = self.view.window.rootViewController ?: self.presentingViewController;
  self.dismissalScene = self.view.window.windowScene;
  self.dismissingPlayer = YES;
  if (interactive) {
    if (![self.playerTransition beginInteractiveDismissal:self]) { self.dismissingPlayer = NO; }
  } else { [self dismissViewControllerAnimated:YES completion:nil]; }
}
- (void)completePlayerDismissal {
  if (self.closing) { return; }
  // A cancelled drag never tears down playback. On success the UI has already
  // returned; retain native resources until VLC's asynchronous stop completes.
  self.closingRetain = self;
  [self.dismissalPresenter setNeedsUpdateOfSupportedInterfaceOrientations];
  if (self.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
    [self.dismissalScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc]
      initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait] errorHandler:nil];
  }
  [NeoPlaybackDiagnostics record:@"player.close" fields:@{}];
  [self sampleHistory]; [self.history finish]; self.closing = YES;
  [self cancelVideoResume];
  self.videoReloadRecovery = NO;
  [self.nowPlaying stop];
  [self.bufferingUpdates reset]; self.bufferingUpdates.onUpdate = nil;
  [self completeSeek:self.seekGeneration failed:NO];
  [self.reloadTimer invalidate]; self.reloadTimer = nil;
  dispatch_block_t reloadCompletion = self.reloadCompletion; self.reloadCompletion = nil;
  if (reloadCompletion) { reloadCompletion(); }
  [self.streamingSubtitles close]; self.streamingSubtitles.onChange = nil;
  [self.streamingSession close]; self.streamingSession.onChange = nil; self.streamingSession.onTransportFailure = nil;
  [self.rewindCache close]; self.rewindCache.onChange = nil; self.rewindCache.onTransportFailure = nil;
  self.view.userInteractionEnabled = NO;
  [self.timer invalidate]; self.timer = nil;
  [self.tsPositionTimer invalidate]; self.tsPositionTimer = nil;
  [self.networkRetryTimer invalidate]; self.networkRetryTimer = nil;
  [self releaseRestoreMute];
  [self.controlsHideTimer invalidate]; self.controlsHideTimer = nil;
  [self.comments stop]; [self.chrome shutdown];
  self.orientationMask = UIInterfaceOrientationMaskPortrait; [self setNeedsUpdateOfSupportedInterfaceOrientations];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (self.loginReference) { [self.dialogs dismissDialogWithReference:self.loginReference]; }
  [NeoVLCFrameTap bindView:self.movieView sink:nil]; [self.commentPiP stop];
  [NeoVLCFrameTap bindARIBView:self.movieView state:nil];
  // VLC 4 stops asynchronously. Keep the drawable and player alive until stopped.
  if (!self.player || self.player.state == VLCMediaPlayerStateStopped || self.player.state == VLCMediaPlayerStateNothingSpecial) {
    [self finishClosing];
  } else {
    self.statusLabel.text = @"停止中…";
    [self.player stop];
  }
}
- (void)finishClosing {
  if (self.finishedClosing) { return; } self.finishedClosing = YES;
  self.player.delegate = nil;
  self.player.drawable = nil;
  self.dialogs.customRenderer = nil; self.dialogs = nil;
  self.username = @""; self.password = @"";
  self.player = nil;
  [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
  void (^callback)(void) = self.onClose; self.onClose = nil;
  void (^navigate)(NSString *) = self.onNavigate; self.onNavigate = nil;
  void (^recording)(NSInteger) = self.onRecording; self.onRecording = nil;
  NSString *route = self.pendingRoute; NSInteger recordingID = self.pendingRecording;
  if (callback) { callback(); }
  if (route && navigate) { navigate(route); }
  else if (recordingID > 0 && recording) { recording(recordingID); }
  self.playerTransition.onCompletion = nil; self.closingRetain = nil;
}
- (void)dealloc { [self.nowPlaying stop]; [self.timer invalidate]; [self.controlsHideTimer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
