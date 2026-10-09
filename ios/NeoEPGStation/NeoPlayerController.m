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

// Only fixed-format numeric timing messages leave libVLC. Never export its raw
// debug messages: they can contain the server URL, credentials or track text.
@interface NeoNativePlaybackLogger : NSObject <VLCLogging>
@property (nonatomic) VLCLogLevel level;
@end
@implementation NeoNativePlaybackLogger
- (void)handleMessage:(NSString *)message logLevel:(VLCLogLevel)level context:(VLCLogContext *)context {
  NSString *event = nil; long long first = 0, second = 0;
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
@property (nonatomic) VLCMediaPlayer *player;
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
@property (nonatomic) NSURL *playbackURL;
@property (nonatomic) NeoPlaybackHistory *history;
@property (nonatomic) BOOL wantsPlayback;
@property (nonatomic) BOOL seeking;
@property (nonatomic) BOOL playbackEnded;
@property (nonatomic) BOOL playbackFailed;
@property (nonatomic) NSInteger seekGeneration;
@property (nonatomic, copy) dispatch_block_t seekCompletion;
@property (nonatomic) NSTimer *seekTimer;
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
@property (atomic) BOOL invalidClockReported;
@property (nonatomic) NSTimeInterval inputClockGuardUntil;
@property (nonatomic, copy) dispatch_block_t reloadCompletion;
@property (nonatomic, copy) NSString *subtitleSignature;
@property (nonatomic) NSTimeInterval lastDiagnosticSample;
@property (nonatomic) NSTimeInterval seekStartedAt;
@property (nonatomic) BOOL awaitingSeekVideo;
@property (nonatomic) NSTimeInterval videoWatchStarted;
@property (nonatomic) NSTimeInterval videoWatchUntil;
@property (nonatomic) NSUInteger videoWatchSamples;
@property (nonatomic) int64_t videoWatchMedia;
@property (nonatomic) NSInteger videoRepairStage;
@property (nonatomic) NSInteger videoRepairGeneration;
@property (nonatomic) BOOL repairingVideo;
#if TARGET_OS_SIMULATOR
@property (nonatomic) CGRect smokeSavedFrame;
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
  }
  return self;
}


- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
  [NeoPlaybackDiagnostics begin];
  [NeoPlaybackDiagnostics record:@"player.start" fields:@{@"networkCachingMs": @(self.networkCaching)}];
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  self.chrome = [[NeoPlayerChrome alloc] initWithTitle:self.mediaTitle];
  self.chrome.frame = self.view.bounds; self.chrome.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.chrome];
  if (self.recordingContext) { [self.chrome configure:self.recordingContext]; }
  self.movieView = self.chrome.videoView;
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
  self.player = [[VLCMediaPlayer alloc] initWithOptions:@[]];
  NeoNativePlaybackLogger *nativeLogger = [NeoNativePlaybackLogger new]; nativeLogger.level = kVLCLogLevelDebug;
  self.player.libraryInstance.loggers = @[nativeLogger];
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
    if (!remoteSelf || remoteSelf.closing || remoteSelf.reloading || !remoteSelf.player.isSeekable || !isfinite(seconds)) { return NO; }
    double bounded = fmin(fmax(0, seconds), [remoteSelf mediaLength] / 1000.0);
    [remoteSelf seekBy:(int64_t)(bounded*1000)-[remoteSelf mediaTime] completion:^{}]; return YES;
  };
  self.nowPlaying.skipAction = ^BOOL(double seconds) {
    if (!remoteSelf || remoteSelf.closing || remoteSelf.reloading || !remoteSelf.player.isSeekable || !isfinite(seconds)) { return NO; }
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
  self.bufferingUpdates.onUpdate = ^(float progress, NSInteger count) { [weakSelf applyBufferingProgress:progress notifications:count]; };
  self.suppressedCommentTracks = [NSMutableSet new];
  self.comments = [[NeoCommentOverlay alloc] initWithFrame:self.movieView.bounds];
  self.comments.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.comments.rateProvider = ^double { return weakSelf.playbackRate; };
  self.comments.timeProvider = ^double { return (double)[weakSelf mediaTime] / 1000.0; };
  self.comments.wantsPlaybackProvider = ^BOOL { return weakSelf.wantsPlayback && !weakSelf.playbackEnded && !weakSelf.closing; };
  self.comments.runningProvider = ^BOOL {
    return weakSelf.player.isPlaying && weakSelf.wantsPlayback && !weakSelf.seeking && !weakSelf.scrubbing && !weakSelf.buffering && !weakSelf.closing && !weakSelf.reloading;
  };
  self.comments.onChange = ^{ [weakSelf updateCommentState]; [weakSelf updateLoadingState]; };
  [self.chrome bindCommentSettings:self.comments];
  [self.movieView addSubview:self.comments];
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
  { [self.comments configureWithSource:self.sourceURL username:self.username password:self.password]; }
  [self updateCommentState];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf updateControls]; }];
  NSNumber *recordingID = self.recordingContext[@"id"];
  NSURL *base = [NSURL URLWithString:self.recordingContext[@"baseURL"] ?: @""];
  if (![self.recordingContext[@"disableHistory"] boolValue] && base && recordingID.integerValue > 0) {
    self.history = [[NeoPlaybackHistory alloc] initWithBase:base recordingID:recordingID.integerValue
      user:self.recordingContext[@"user"] ?: @"master" username:self.username password:self.password];
    self.history.onChange = ^{ [weakSelf updateControls]; };
  }
  [self showControls];
  if (self.sourceURL.isFileURL || [self.recordingContext[@"isRecording"] boolValue]) { [self startWhenCommentsReady]; }
  else {
    self.rewindCache = [[NeoPlaybackCache alloc] initWithSource:self.sourceURL username:self.username password:self.password];
    self.rewindCache.onChange = ^{ [weakSelf updateControls]; };
    self.rewindCache.onTransportFailure = ^{
      if (!weakSelf || weakSelf.closing || weakSelf.transportSuspended || weakSelf.reloading) { return; }
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

- (void)applyPlayerLayout:(CGSize)size {
  BOOL changed = self.landscape != (size.width > size.height);
  self.landscape = size.width > size.height;
  self.chrome.frame = CGRectMake(0, 0, size.width, size.height);
  [self.chrome setNeedsLayout]; [self.chrome layoutIfNeeded];
  [self alignVideoOutput];
  if (changed) { [self setNeedsStatusBarAppearanceUpdate]; }
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self applyPlayerLayout:self.view.bounds.size]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    [self applyPlayerLayout:size];
  } completion:nil];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.orientationMask; }
- (BOOL)shouldAutorotate { return YES; }
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
  if ([action isEqualToString:@"toggle-controls"]) { [self toggleControls]; return; }
  [self showControls];
  if (self.reloading && ([action hasPrefix:@"jump:"] || [action hasPrefix:@"seekto:"] || [action hasPrefix:@"scrub-"])) { return; }
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
  else if ([action hasPrefix:@"subtitle:"]) {
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
  self.orientationMask = [mode isEqualToString:@"portrait"] ? UIInterfaceOrientationMaskPortrait
    : [mode isEqualToString:@"landscape"] ? UIInterfaceOrientationMaskLandscapeRight : UIInterfaceOrientationMaskAllButUpsideDown;
  [self setNeedsUpdateOfSupportedInterfaceOrientations];
  UIWindowScene *scene = self.view.window.windowScene;
  if (!scene) { return; }
  UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:self.orientationMask];
  __weak typeof(self) weakSelf = self;
  [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.statusLabel.text = @"画面回転エラー · この表示環境では向きを変更できません。"; [weakSelf.chrome updateDiagnostics]; });
  }];
}
- (void)reloadPlayback {
  if (self.reloading) { return; }
  if (self.pipActive) {
    self.statusLabel.text = @"再読み込み · PiPを閉じてから実行してください。"; [self.chrome updateDiagnostics]; return;
  }
  [self reloadPlaybackAtTime:[self mediaTime] completion:nil];
}
- (void)reloadPlaybackAtTime:(int64_t)time completion:(dispatch_block_t)completion {
  if (self.closing || self.reloading) { if (completion) { completion(); } return; }
  NSInteger generation = ++self.reloadGeneration;
  [self sampleHistory]; [self.history flush];
  self.reloadTime = MAX(0, time); self.reloadPlaying = self.wantsPlayback;
  self.reloadCompletion = completion;
  self.transportSuspended = NO;
  [self completeSeek:self.seekGeneration failed:NO];
  NSMutableArray *tracks = [NSMutableArray new];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) { if (track.isSelected) { [tracks addObject:track.trackId]; } }
  self.scrubbing = NO; self.reloadTextTracks = tracks; self.reloading = YES; self.restoringReload = NO;
  self.statusLabel.text = @"プレイヤーを再読み込みしています…"; [self.chrome updateDiagnostics];
  [self.commentPiP resetVideo];
  [self armReloadDeadline];
  __weak typeof(self) weakSelf = self;
  if (self.rewindCache) {
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
    else if (self.reloading || self.transportSuspended) { message = @"再接続中"; }
    else if (self.repairingVideo) { message = @"映像を復旧中"; }
    else if (self.seeking || self.awaitingSeekVideo) { message = @"シーク先を読み込み中"; }
    else if (self.awaitingEndpoint || self.player.state == VLCMediaPlayerStateOpening ||
      (self.wantsPlayback && self.commentPiP.capturedFrameCount == 0)) { message = @"動画を読み込み中"; }
  }
  if (self.playbackEnded || self.playbackFailed || self.closing) { [self.chrome updateBuffering:NO progress:1]; }
  [self.chrome updateLoading:message];
}
- (void)checkVideoRecovery {
  NSTimeInterval now = CACurrentMediaTime();
  if (!self.videoWatchUntil || now > self.videoWatchUntil || self.closing || self.inputInBackground || self.pipActive ||
      self.reloading || self.seeking || self.buffering || !self.wantsPlayback || !self.player.isPlaying) {
    self.videoWatchStarted = 0; return;
  }
  NSDictionary *stats = [NeoVLCFrameTap snapshot:self.movieView];
  if (!stats.count) { return; }
  if (!self.videoWatchStarted) {
    self.videoWatchStarted = now; self.videoWatchSamples = [stats[@"samples"] unsignedIntegerValue]; self.videoWatchMedia = [self mediaTime]; return;
  }
  double elapsed = now-self.videoWatchStarted;
  if (elapsed < 3 || [self mediaTime]-self.videoWatchMedia < 1500) { return; }
  double fps = ([stats[@"samples"] unsignedIntegerValue]-self.videoWatchSamples)/elapsed;
  double age = [stats[@"contentAge"] doubleValue];
  // Static scenes alone must not trigger a repair: also require the paused
  // refresh cadence, missing output or a failed/blocked presentation queue.
  BOOL frozen = (age >= 2.5 && (fps < 15 || [stats[@"scheduledInMs"] doubleValue] > 500)) ||
    [stats[@"layerStatus"] integerValue] == AVQueuedSampleBufferRenderingStatusFailed || [stats[@"requiresFlush"] boolValue];
  if (!frozen) {
    self.videoWatchStarted = now; self.videoWatchSamples = [stats[@"samples"] unsignedIntegerValue]; self.videoWatchMedia = [self mediaTime]; return;
  }
  NSMutableDictionary *fields = [stats mutableCopy]; fields[@"stage"] = @(self.videoRepairStage); fields[@"mediaMs"] = @([self mediaTime]); fields[@"sampleFPS"] = @(fps);
  [NeoPlaybackDiagnostics record:@"video.repair" fields:fields];
  self.videoWatchStarted = 0;
  if (self.videoRepairStage == 0) {
    self.videoRepairStage = 1; [NeoVLCFrameTap flushVideoQueue:self.movieView]; [self alignVideoOutput]; return;
  }
  if (self.videoRepairStage != 1) { return; }
  self.videoRepairStage = 2;
  VLCMediaPlayerTrack *selected = nil;
  for (VLCMediaPlayerTrack *track in self.player.videoTracks) { if (track.isSelected) { selected = track; break; } }
  if (!selected) { return; }
  self.repairingVideo = YES; NSInteger generation = ++self.videoRepairGeneration; VLCMedia *mediaAtRepair = self.player.media;
  // Only restart the selected video decoder/output. Input, audio, cache and
  // media position stay alive; never seek to the beginning to repair video.
  selected.selected = NO;
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (!weakSelf || weakSelf.closing || weakSelf.player.media != mediaAtRepair) { return; }
    selected.selected = YES;
    if (weakSelf.videoRepairGeneration != generation) { return; } weakSelf.repairingVideo = NO;
    [weakSelf applyPlaybackIntentForced:YES]; [weakSelf updateLoadingState];
    [NeoPlaybackDiagnostics record:@"video.trackRestored" fields:@{@"mediaMs": @([weakSelf mediaTime])}];
  });
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
  // Opening the replacement input is asynchronous. An older Stopped event
  // must not open it again while start-paused is still preparing it.
  if (self.reloading && self.restoringReload) { return; }
  self.restoringReload = self.reloading;
  self.playbackEnded = NO; self.playbackFailed = NO; self.buffering = NO;
  self.inputBufferReady = NO; self.lastIntentCommandAt = 0;
  [self.chrome updateBuffering:NO progress:1];
  [NeoPlaybackDiagnostics record:@"input.restart" fields:@{@"restoring": @(self.reloading), @"targetMs": @(self.reloadTime)}];
  self.subtitleSignature = nil;
  self.inputStartTime = self.reloading ? self.reloadTime : 0;
  self.invalidClockReported = NO;
  self.inputClockGuardUntil = CACurrentMediaTime()+3;
  self.lastObservedTime = self.inputStartTime;
  [self.rewindCache beginSeek:self.inputStartTime / 1000.0];
  if (self.reloading) { [self.comments beginSeek:self.inputStartTime / 1000.0]; }
  VLCMedia *media = [VLCMedia mediaWithURL:self.playbackURL ?: self.sourceURL];
  [media addOption:[NSString stringWithFormat:@":network-caching=%ld", (long)self.networkCaching]];
  if (self.inputStartTime > 0) {
    [media addOption:[NSString stringWithFormat:@":start-time=%.3f", self.inputStartTime / 1000.0]];
  }
  // Initialise at the requested position, paused. Never play the beginning
  // to prepare a later seek, including when the user wants playback resumed.
  if (self.reloading) { [media addOption:@":start-paused"]; }
  [NeoPlaybackDiagnostics record:@"input.startPosition" fields:@{@"targetMs": @(self.inputStartTime), @"paused": @(self.reloading)}];
  self.player.media = media; [self.player play];
}
- (void)finishReload:(BOOL)failed {
  self.reloading = NO; self.restoringReload = NO;
  self.inputClockGuardUntil = CACurrentMediaTime()+3;
  [self.reloadTimer invalidate]; self.reloadTimer = nil;
  self.lastSeekFailed = failed;
  [self.comments endSeek];
  if (failed) { [self setPlaybackIntent:NO]; }
  else {
    self.transportRecoveryAttempted = NO;
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
  if (completion) { completion(); }
}
- (void)restoreReloadIfReady {
  VLCMediaPlayerState state = self.player.state;
  if (!self.reloading || self.awaitingEndpoint || !self.inputBufferReady || self.buffering ||
      state != VLCMediaPlayerStatePaused) { return; }
  // start-time is handled by the demuxer during initialisation. There is no
  // second, post-buffering seek from the beginning of the recording.
  // Opening also announces Playing before start-paused takes effect. Wait
  // for that initial pause before applying the user's latest playback intent.
  [NeoPlaybackDiagnostics record:@"input.restoreReady" fields:@{@"targetMs": @(self.reloadTime),
    @"mediaMs": @([self mediaTime]), @"bufferReady": @(self.inputBufferReady), @"wantsPlayback": @(self.wantsPlayback)}];
  [self finishReload:NO];
}
- (void)togglePlayback { [self showControls]; [self setPlaybackIntent:!self.wantsPlayback]; }
- (void)setPlaybackIntent:(BOOL)playing {
  [self sampleHistory]; [self.history flush];
  self.wantsPlayback = playing;
  [NeoPlaybackDiagnostics record:@"playback.intent" fields:@{@"playing": @(playing), @"reloading": @(self.reloading)}];
  [self.commentPiP updateAutomaticPlayback];
  if (!self.reloading && !self.awaitingComments && !self.awaitingEndpoint && playing &&
      (self.transportSuspended || self.playbackEnded || self.playbackFailed || self.player.state == VLCMediaPlayerStateStopped)) {
    if (self.playbackEnded) {
      self.backgroundPositionValid = NO; self.lastObservedTime = 0;
      [self.rewindCache beginSeek:0];
      if (!self.awaitingComments && !self.reloading) { [self restartMedia]; }
    } else { [self reloadPlaybackAtTime:MAX(self.lastObservedTime, self.backgroundPositionValid ? self.backgroundTime : 0) completion:nil]; }
  } else { [self applyPlaybackIntentForced:YES]; }
  [self.commentPiP invalidatePlaybackState]; [self updateControls]; [self scheduleControlsHide];
}
- (void)applyPlaybackIntent {
  [self applyPlaybackIntentForced:NO];
}
- (void)applyPlaybackIntentForced:(BOOL)force {
  if (self.closing || self.reloading || self.playbackEnded || self.playbackFailed) { return; }
  // Buffering/seek callbacks can arrive after EOF. Only reconcile an active
  // input; starting a stopped input belongs to an explicit play/reload action.
  if (self.player.state != VLCMediaPlayerStatePlaying && self.player.state != VLCMediaPlayerStatePaused) { return; }
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
    running:self.player.isPlaying && self.wantsPlayback && !self.buffering
    seeking:self.seeking || self.scrubbing || self.reloading rate:self.playbackRate];
}
- (void)beginScrubbing { [self showControls]; self.scrubbing = YES; }
- (void)cancelScrubbing { self.scrubbing = NO; [self.chrome finishSeekPreview]; [self showControls]; }
- (void)endScrubbing {
  if (self.player.isSeekable) { [self seekBy:(int64_t)(self.timeline.value * [self mediaLength]) - [self mediaTime] completion:^{}]; }
  else { [self.chrome finishSeekPreview]; }
  self.scrubbing = NO; [self showControls];
}

- (BOOL)isOrdinarySubtitle:(VLCMediaPlayerTrack *)track {
  return ![NeoCommentOverlay isCommentName:track.trackName ?: @""] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""];
}
- (void)restoreSubtitlePreference {
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
  [self restoreSubtitlePreference];
  NSMutableArray *tracks = [NSMutableArray new]; NSInteger index = 0;
  for (VLCMediaPlayerTrack *track in self.player.textTracks) {
    [tracks addObject:@{@"index": @(index++), @"name": track.trackName ?: @"字幕", @"detail": track.trackDescription ?: @"", @"selected": @(track.isSelected)}];
  }
  [self.chrome updateSubtitleTracks:tracks];
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

- (void)updateControls {
  if (self.closing) { return; }
  [self restoreReloadIfReady];
  [self applyPlaybackIntent];
  [self updateNowPlaying];
  [self sampleHistory];
  self.timeline.enabled = self.player.isSeekable && !self.reloading; self.playButton.enabled = YES;
  int64_t current = MAX(0, [self mediaTime] / 1000);
  int64_t length = [self mediaLength] / 1000;
  if (!self.scrubbing && length > 0) { self.timeline.value = self.playbackEnded ? 1 : MIN(1, MAX(0, (double)[self mediaTime] / [self mediaLength])); }
  [self rememberPlaybackTime];
  [self.rewindCache observeTime:current running:self.player.isPlaying && !self.buffering && !self.seeking];
  [self.chrome updatePlayback:self.wantsPlayback && !self.playbackEnded current:self.playbackEnded ? self.lastObservedLength / 1000 : current duration:length > 0 ? length : self.lastObservedLength / 1000];
  [self.chrome updateDownloadedRanges:self.rewindCache.downloadedRanges ?: @[]];
  NSString *warning = self.rewindCache.status.length ? self.rewindCache.status : self.history.status;
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
  if (self.awaitingSeekVideo && !self.seeking && !self.buffering && self.commentPiP.videoPresentationHostTime > self.seekStartedAt) {
    self.awaitingSeekVideo = NO;
    [NeoPlaybackDiagnostics record:@"seek.videoResume" fields:@{@"mediaMs": @([self mediaTime]),
      @"durationMs": @((now - self.seekStartedAt) * 1000)}];
  }
  if (now - self.lastDiagnosticSample >= 1) {
    self.lastDiagnosticSample = now;
    [NeoPlaybackDiagnostics record:@"video.sample" fields:[NeoVLCFrameTap snapshot:self.movieView]];
    [NeoPlaybackDiagnostics record:@"player.sample" fields:@{@"mediaMs": @([self mediaTime]),
      @"state": @(self.player.state), @"buffering": @(self.buffering), @"seeking": @(self.seeking),
      @"nativePlaying": @(self.player.isPlaying), @"appState": @(UIApplication.sharedApplication.applicationState),
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
    if ((state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError) && self.player.state != state) {
      [NeoPlaybackDiagnostics record:@"player.staleTerminalState" fields:@{@"state": @(state), @"currentState": @(self.player.state)}];
      return;
    }
    if (state == VLCMediaPlayerStateStopped || state == VLCMediaPlayerStateError) {
      [self.bufferingUpdates reset];
      self.buffering = NO; [self.chrome updateBuffering:NO progress:1];
    }
    if (self.reloading && state == VLCMediaPlayerStateStopped && !self.restoringReload && !self.awaitingEndpoint) { [self restartMedia]; return; }
    if (state == VLCMediaPlayerStateError && (self.transportSuspended || self.awaitingEndpoint || self.player.state != state)) { return; }
    if (state == VLCMediaPlayerStateError && self.backgroundPositionValid && !self.reloading && !self.transportRecoveryAttempted) {
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
    if (state == VLCMediaPlayerStateStopped && !self.playbackEnded && !self.reloading && self.lastObservedTime > 0) {
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
      [self applyPlaybackIntent];
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
    playing:self.wantsPlayback && self.player.isPlaying && !self.buffering && !self.reloading && !self.playbackEnded
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
  self.videoWatchStarted = 0; self.videoWatchUntil = 0; self.repairingVideo = NO;
  self.inputInBackground = YES;
  self.backgroundTime = self.reloading ? self.reloadTime : MAX(0, [self mediaTime]);
  self.backgroundPositionValid = YES;
  [self.commentPiP enterBackground];
  // A paused app can be suspended by iOS without destroying its input.
  // Keep the listener, retained data and VLC demux/decoder state intact.
}
- (void)foregrounded {
  if (self.closing) { return; }
  [NeoPlaybackDiagnostics record:@"lifecycle.foreground" fields:@{@"wantsPlayback": @(self.wantsPlayback), @"needsRecovery": @(self.transportSuspended), @"mediaMs": @([self mediaTime])}];
  self.inputInBackground = NO;
  [self.commentPiP enterForeground];
  [AVAudioSession.sharedInstance setActive:YES error:nil];
  [self alignVideoOutput];
  [NeoVLCFrameTap prepareForeground:self.movieView];
  self.videoWatchUntil = CACurrentMediaTime()+45; self.videoWatchStarted = 0; self.videoRepairStage = 0;
  self.repairingVideo = NO; self.videoRepairGeneration += 1;
  [NeoPlaybackDiagnostics record:@"video.foregroundFlush" fields:[NeoVLCFrameTap snapshot:self.movieView]];
  VLCMediaPlayerState state = self.player.state;
  if (!self.reloading && !self.playbackEnded && self.backgroundPositionValid &&
      (self.transportSuspended || state == VLCMediaPlayerStateError || state == VLCMediaPlayerStateStopped)) {
    self.transportRecoveryAttempted = YES;
    [self reloadPlaybackAtTime:MAX(self.backgroundTime, self.lastObservedTime) completion:nil];
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
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  view.frame = self.movieView.bounds;
  [self.movieView addSubview:view];
  [NeoVLCFrameTap bindView:view sink:self.commentPiP];
  if (self.comments) { [self.movieView bringSubviewToFront:self.comments]; }
}
- (void)alignVideoOutput {
  // Resize VLC's outer drawable only. libVLC lays out its inner aspect-fit
  // sample-buffer view using the resulting video-output size notification.
  if (self.videoOutputView.superview != self.movieView) { return; }
  self.videoOutputView.frame = self.movieView.bounds;
  [self.videoOutputView setNeedsLayout]; [self.videoOutputView layoutIfNeeded];
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
- (void)closeTapSmoke { [self closePlayer]; }
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
        [self runLifecycleRecoverySmoke:^(NSDictionary *result) {
          NSMutableDictionary *checks = [result mutableCopy];
          checks[@"bufferingBurstCoalesced"] = @(coalesced); checks[@"bufferingResetDropsOldUpdate"] = @(reset);
          checks[@"latestPlayFollowsQueuedPause"] = @(intentOrdered); checks[@"nowPlayingRegistered"] = @(registered);
          checks[@"invalidRemoteSeekRejected"] = @(invalidRemoteSeek);
          checks[@"success"] = @((BOOL)([result[@"success"] boolValue] && coalesced && reset && intentOrdered && registered && invalidRemoteSeek)); completion(checks);
        }];
        }];
      });
    });
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
    checks[@"fadeInCompletes"] = self.chrome.controls.layer.presentationLayer.opacity > 0.99 ? @YES : @NO;
    [self performPlayerAction:@"interaction"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      checks[@"interactionRestartsHideTimer"] = @(self.chrome.controlsVisible);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Still visible at 2.2 seconds: this detects the previous 2s timeout.
        checks[@"visibleBeforeTwoPointFiveSeconds"] = self.chrome.controlsVisible ? @YES : @NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          checks[@"pausedIdleHides"] = self.chrome.controlsVisible ? @NO : @YES;
          checks[@"fadeOutCompletes"] = self.chrome.controls.layer.presentationLayer.opacity < 0.01 ? @YES : @NO;
          [self beginScrubbing];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            checks[@"scrubbingStaysVisible"] = @(self.chrome.controlsVisible);
            [self cancelScrubbing];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              checks[@"scrubbingEndRestartsHide"] = self.chrome.controlsVisible ? @NO : @YES;
              checks[@"success"] = [[checks allValues] indexOfObject:@NO] == NSNotFound ? @YES : @NO;
              if (playing) { [self setPlaybackIntent:YES]; }
              completion(checks);
            });
          });
        });
      });
    });
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
    (self.view.bounds.size.width > self.view.bounds.size.height) == wide && !self.transitionCoordinator;
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
  [self setOrientation:@"landscape"];
  [self waitForSmokeOrientation:UIInterfaceOrientationLandscapeRight attempt:0 completion:^(BOOL locked) {
    if (!locked) { completion(@{@"success": @NO, @"landscapeBeforeExit": @NO}); return; }
    self.onNavigate = ^(NSString *route) {
      [self waitForHostPortrait:host attempt:0 completion:^(BOOL portrait) {
        completion(@{@"success": portrait && [route isEqualToString:@"recorded"] ? @YES : @NO, @"landscapeBeforeExit": @YES,
          @"sidebarRouteDelivered": [route isEqualToString:@"recorded"] ? @YES : @NO, @"hostPortraitAfterExit": portrait ? @YES : @NO,
          @"hostPortraitOnly": host.supportedInterfaceOrientations == UIInterfaceOrientationMaskPortrait ? @YES : @NO,
          @"hostClass": NSStringFromClass(host.class), @"hostOrientationMask": @(host.supportedInterfaceOrientations),
          @"sceneOrientation": @(host.view.window.windowScene.interfaceOrientation), @"hostFrame": NSStringFromCGRect(host.view.bounds)});
      }];
    };
    [self performPlayerAction:@"navigate:recorded"];
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
  if (self.closing || !self.player.isSeekable) { completion(); return; }
  [self sampleHistory]; [self.history flush];
  [self completeSeek:self.seekGeneration failed:NO];
  int64_t length = [self mediaLength];
  int64_t target = MAX(0, [self mediaTime] + offset);
  if (length > 0) { target = MIN(length, target); }
  self.backgroundPositionValid = NO;
  if (target < self.inputStartTime) {
    [self reloadPlaybackAtTime:target completion:completion]; return;
  }
  self.inputClockGuardUntil = 0; // An explicit seek can legitimately jump far ahead.
  self.playbackEnded = NO; self.seeking = YES; self.seekCompletion = completion;
  self.lastSeekFailed = NO;
  NSInteger generation = ++self.seekGeneration;
  self.seekStartedAt = CACurrentMediaTime();
  self.awaitingSeekVideo = YES;
  [NeoPlaybackDiagnostics beginSeek:generation];
  [NeoPlaybackDiagnostics record:@"seek.start" fields:@{@"fromMs": @([self mediaTime]), @"targetMs": @(target),
    @"pip": @(self.pipActive), @"restoring": @(self.restoringReload)}];
  [self.chrome previewSeek:target / 1000];
  [self.rewindCache beginSeek:target / 1000.0]; [self.comments beginSeek:target / 1000.0]; [self.commentPiP seekDiscontinuity:target / 1000.0];
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
  [self.commentPiP invalidatePlaybackState]; [self scheduleControlsHide];
}
- (void)completeSeek:(NSInteger)generation failed:(BOOL)failed {
  if (!self.seeking || generation != self.seekGeneration) { return; }
  // Establish the new history position while it is still marked as a seek.
  // Even a short jump or a delayed completion must not become watched time.
  if (!self.closing) { [self sampleHistory]; }
  [self.seekTimer invalidate]; self.seekTimer = nil; self.seeking = NO; [self.comments endSeek];
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
    [weakSelf completeSeek:weakSelf.seekGeneration failed:YES]; [weakSelf finishReload:YES];
    weakSelf.statusLabel.text = @"再読み込みできませんでした。接続を確認して再試行してください。";
    [weakSelf.chrome updateDiagnostics]; [weakSelf showControls];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.reloadTimer forMode:NSRunLoopCommonModes];
}
- (int64_t)mediaLength { return MAX(self.lastObservedLength, MAX(0, self.player.media.length.value.longLongValue)); }
- (int64_t)mediaTime {
  int64_t raw = self.player.time.value.longLongValue;
  int64_t time = self.inputStartTime + MAX(0, raw);
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
  if (self.closing) { return; }
  [NeoPlaybackDiagnostics record:@"player.close" fields:@{}];
  [self sampleHistory]; [self.history finish]; self.closing = YES;
  [self.nowPlaying stop];
  [self.bufferingUpdates reset]; self.bufferingUpdates.onUpdate = nil;
  [self completeSeek:self.seekGeneration failed:NO];
  [self.reloadTimer invalidate]; self.reloadTimer = nil;
  dispatch_block_t reloadCompletion = self.reloadCompletion; self.reloadCompletion = nil;
  if (reloadCompletion) { reloadCompletion(); }
  [self.rewindCache close]; self.rewindCache.onChange = nil; self.rewindCache.onTransportFailure = nil;
  self.view.userInteractionEnabled = NO;
  [self.timer invalidate]; self.timer = nil;
  [self.controlsHideTimer invalidate]; self.controlsHideTimer = nil;
  [self.comments stop]; [self.chrome shutdown];
  self.orientationMask = UIInterfaceOrientationMaskPortrait; [self setNeedsUpdateOfSupportedInterfaceOrientations];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (self.loginReference) { [self.dialogs dismissDialogWithReference:self.loginReference]; }
  [NeoVLCFrameTap bindView:self.movieView sink:nil]; [self.commentPiP stop];
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
  self.player.libraryInstance.loggers = nil;
  self.player.drawable = nil;
  self.dialogs.customRenderer = nil; self.dialogs = nil;
  self.username = @""; self.password = @"";
  self.player = nil;
  [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
  void (^callback)(void) = self.onClose; self.onClose = nil;
  void (^navigate)(NSString *) = self.onNavigate; self.onNavigate = nil;
  void (^recording)(NSInteger) = self.onRecording; self.onRecording = nil;
  NSString *route = self.pendingRoute; NSInteger recordingID = self.pendingRecording;
  UIViewController *presenter = self.view.window.rootViewController ?: self.presentingViewController;
  UIWindowScene *scene = self.view.window.windowScene;
  [self dismissViewControllerAnimated:YES completion:^{
    // Reset the scene as well as the mask: a manually locked landscape scene
    // can otherwise stay horizontal after the player has been dismissed.
    [presenter setNeedsUpdateOfSupportedInterfaceOrientations];
    [scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait] errorHandler:nil];
    if (callback) { callback(); }
    if (route && navigate) { navigate(route); }
    else if (recordingID > 0 && recording) { recording(recordingID); }
  }];
}
- (void)dealloc { [self.nowPlaying stop]; [self.timer invalidate]; [self.controlsHideTimer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
