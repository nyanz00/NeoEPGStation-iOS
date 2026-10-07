#import "NeoPlayerController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <VLCKit/VLCKit.h>
#import "NeoEPGStation-Swift.h"
#import "NeoVLCFrameTap.h"

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
@property (nonatomic) UILabel *statusLabel;
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
@property (nonatomic) BOOL lastSeekFailed;
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
  self.dialogs = [[VLCDialogProvider alloc] initWithLibrary:self.player.libraryInstance customUI:YES];
  self.dialogs.customRenderer = self;
  self.player.delegate = self; self.player.drawable = self;
  // The comment display link samples VLC's native clock, not the 0.5s UI timer.
  self.player.timeChangeUpdateInterval = 1.0 / 60.0;
  self.playbackURL = self.sourceURL;
  self.wantsPlayback = YES;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(interrupted:)
    name:AVAudioSessionInterruptionNotification object:audio];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded)
    name:UIApplicationDidEnterBackgroundNotification object:nil];
  __weak typeof(self) weakSelf = self;
  self.suppressedCommentTracks = [NSMutableSet new];
  self.comments = [[NeoCommentOverlay alloc] initWithFrame:self.movieView.bounds];
  self.comments.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.comments.timeProvider = ^double { return weakSelf.player.time.value.doubleValue / 1000.0; };
  self.comments.runningProvider = ^BOOL {
    return weakSelf.player.isPlaying && !weakSelf.seeking && !weakSelf.scrubbing && !weakSelf.buffering && !weakSelf.closing && !weakSelf.reloading;
  };
  self.comments.onChange = ^{ [weakSelf updateCommentState]; };
  [self.chrome bindCommentSettings:self.comments];
  [self.movieView addSubview:self.comments];
  self.frameTapInstalled = [NeoVLCFrameTap install];
  self.commentPiP = [NeoCommentPiP new];
  self.commentPiP.view.frame = self.movieView.bounds;
  self.commentPiP.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.movieView insertSubview:self.commentPiP.view atIndex:0];
  self.commentPiP.timeProvider = self.comments.timeProvider;
  self.commentPiP.lengthProvider = ^double { return [weakSelf mediaLength] / 1000.0; };
  self.commentPiP.runningProvider = self.comments.runningProvider;
  self.commentPiP.wantsPlaybackProvider = ^BOOL { return weakSelf.wantsPlayback && !weakSelf.playbackEnded && !weakSelf.closing; };
  self.commentPiP.playAction = ^{ [weakSelf setPlaybackIntent:YES]; };
  self.commentPiP.pauseAction = ^{ [weakSelf setPlaybackIntent:NO]; };
  self.commentPiP.seekAction = ^(double seconds, void (^completion)(void)) {
    [weakSelf seekBy:(int64_t)(seconds * 1000) completion:completion];
  };
  self.commentPiP.onChange = ^{ [weakSelf updatePiPState]; };
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
  if (base && recordingID.integerValue > 0) {
    self.history = [[NeoPlaybackHistory alloc] initWithBase:base recordingID:recordingID.integerValue
      user:self.recordingContext[@"user"] ?: @"master" username:self.username password:self.password];
    self.history.onChange = ^{ [weakSelf updateControls]; };
  }
  [self showControls];
  if (self.sourceURL.isFileURL || [self.recordingContext[@"isRecording"] boolValue]) { [self restartMedia]; }
  else {
    self.rewindCache = [[NeoPlaybackCache alloc] initWithSource:self.sourceURL username:self.username password:self.password];
    self.rewindCache.onChange = ^{ [weakSelf updateControls]; };
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
        [weakSelf restartMedia]; return;
      }
      weakSelf.playbackURL = url; [weakSelf restartMedia];
    }];
  }
}

- (void)applyPlayerLayout:(CGSize)size {
  BOOL changed = self.landscape != (size.width > size.height);
  self.landscape = size.width > size.height;
  self.chrome.frame = CGRectMake(0, 0, size.width, size.height);
  [self.chrome setNeedsLayout]; [self.chrome layoutIfNeeded];
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
  else if ([action isEqualToString:@"scrub-begin"]) { [self beginScrubbing]; }
  else if ([action isEqualToString:@"scrub-end"]) { [self endScrubbing]; }
  else if ([action isEqualToString:@"scrub-cancel"]) { [self cancelScrubbing]; }
  else if ([action isEqualToString:@"reload"]) { [self reloadPlayback]; }
  else if ([action isEqualToString:@"rotate"]) { [self setOrientation:self.landscape ? @"portrait" : @"landscape"]; }
  else if ([action hasPrefix:@"orientation:"]) { [self setOrientation:[action substringFromIndex:12]]; }
  else if ([action hasPrefix:@"jump:"]) { [self seekBy:[action substringFromIndex:5].longLongValue * 1000 completion:^{}]; }
  else if ([action hasPrefix:@"seekto:"]) {
    int64_t target = (int64_t)([action substringFromIndex:7].doubleValue * 1000);
    [self seekBy:target - self.player.time.value.longLongValue completion:^{}];
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
      for (VLCMediaPlayerTrack *track in self.player.textTracks) {
        if (![NeoCommentOverlay isCommentName:track.trackName ?: @""] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) { track.selected = NO; }
      }
    } else if (index < self.player.textTracks.count) {
      VLCMediaPlayerTrack *track = self.player.textTracks[index];
      if (![NeoCommentOverlay isCommentName:track.trackName ?: @""] && ![NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) { [self.player selectTextTracks:@[track]]; }
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
  [self sampleHistory]; [self.history flush];
  self.reloadTime = MAX(0, self.player.time.value.longLongValue); self.reloadPlaying = self.wantsPlayback;
  [self completeSeek:self.seekGeneration failed:NO];
  NSMutableArray *tracks = [NSMutableArray new];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) { if (track.isSelected) { [tracks addObject:track.trackId]; } }
  self.scrubbing = NO; self.reloadTextTracks = tracks; self.reloading = YES; self.restoringReload = NO;
  self.statusLabel.text = @"プレイヤーを再読み込みしています…"; [self.chrome updateDiagnostics];
  [self.commentPiP resetVideo];
  [self armReloadDeadline];
  if (self.player.state == VLCMediaPlayerStateStopped || self.player.state == VLCMediaPlayerStateNothingSpecial) { [self restartMedia]; }
  else { [self.player stop]; }
}
- (void)restartMedia {
  self.playbackEnded = NO; self.playbackFailed = NO; self.buffering = NO;
  self.lastObservedTime = 0;
  VLCMedia *media = [VLCMedia mediaWithURL:self.playbackURL ?: self.sourceURL];
  [media addOption:[NSString stringWithFormat:@":network-caching=%ld", (long)self.networkCaching]];
  self.player.media = media; [self.player play];
}
- (void)restoreReloadIfReady {
  if (!self.reloading || self.restoringReload || self.player.state != VLCMediaPlayerStatePlaying) { return; }
  if (!self.player.isSeekable) {
    if (!self.wantsPlayback) { [self.player pause]; }
    self.player.rate = self.playbackRate; self.reloading = NO;
    self.statusLabel.text = @"再読み込み · このファイルは再生位置を復元できません。";
    [self.chrome updateDiagnostics]; [self.commentPiP invalidatePlaybackState]; return;
  }
  self.restoringReload = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_block_t restore = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      if (weakSelf.closing) { return; }
      weakSelf.player.rate = weakSelf.playbackRate;
      if (weakSelf.lastSeekFailed) { weakSelf.reloading = NO; weakSelf.restoringReload = NO; [weakSelf setPlaybackIntent:NO]; return; }
      [weakSelf.player deselectAllTextTracks];
      for (VLCMediaPlayerTrack *track in weakSelf.player.textTracks) { if ([weakSelf.reloadTextTracks containsObject:track.trackId]) { track.selected = YES; } }
      weakSelf.reloading = NO; weakSelf.restoringReload = NO;
      [weakSelf.reloadTimer invalidate]; weakSelf.reloadTimer = nil;
      [weakSelf applyPlaybackIntent];
      weakSelf.statusLabel.text = weakSelf.wantsPlayback ? @"PLAY · 再生中" : @"PLAY · 一時停止";
      [weakSelf.commentPiP invalidatePlaybackState]; [weakSelf updateControls];
    });
  };
  [self seekBy:self.reloadTime - self.player.time.value.longLongValue completion:restore];
}
- (void)togglePlayback { [self showControls]; [self setPlaybackIntent:!self.wantsPlayback]; }
- (void)setPlaybackIntent:(BOOL)playing {
  [self sampleHistory]; [self.history flush];
  self.wantsPlayback = playing;
  if (playing && (self.playbackEnded || self.playbackFailed || self.player.state == VLCMediaPlayerStateStopped)) {
    self.lastObservedTime = 0; [self.rewindCache beginSeek:0]; [self restartMedia];
  } else { [self applyPlaybackIntent]; }
  [self.commentPiP invalidatePlaybackState]; [self updateControls]; [self scheduleControlsHide];
}
- (void)applyPlaybackIntent {
  if (self.closing || self.reloading || self.playbackEnded || self.playbackFailed) { return; }
  // Buffering/seek callbacks can arrive after EOF. Only reconcile an active
  // input; starting a stopped input belongs to an explicit play/reload action.
  if (self.player.state != VLCMediaPlayerStatePlaying && self.player.state != VLCMediaPlayerStatePaused) { return; }
  if (self.wantsPlayback) { if (!self.player.isPlaying) { [self.player play]; } }
  else if (self.player.isPlaying) { [self.player pause]; }
}
- (void)sampleHistory {
  [self.history sample:self.playbackEnded ? self.lastObservedLength / 1000.0 : MAX(0, self.player.time.value.doubleValue / 1000.0)
    duration:[self mediaLength] / 1000.0
    running:self.player.isPlaying && self.wantsPlayback && !self.buffering
    seeking:self.seeking || self.scrubbing || self.reloading rate:self.playbackRate];
}
- (void)beginScrubbing { [self showControls]; self.scrubbing = YES; }
- (void)cancelScrubbing { self.scrubbing = NO; [self showControls]; }
- (void)endScrubbing {
  if (self.player.isSeekable) { [self seekBy:(int64_t)(self.timeline.value * [self mediaLength]) - self.player.time.value.longLongValue completion:^{}]; }
  self.scrubbing = NO; [self showControls];
}

- (void)updateSubtitleSettings {
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
  if (self.chrome.commentVersion != self.comments.panelVersion) { [self.chrome setCommentRows:[self.comments panelComments] version:self.comments.panelVersion]; }
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
  [self sampleHistory];
  self.timeline.enabled = self.player.isSeekable && !self.reloading; self.playButton.enabled = YES;
  if (!self.scrubbing) { self.timeline.value = self.player.position; }
  int64_t current = MAX(0, self.player.time.value.longLongValue / 1000);
  int64_t length = [self mediaLength] / 1000;
  [self rememberPlaybackTime];
  [self.rewindCache observeTime:current running:self.player.isPlaying && !self.buffering && !self.seeking];
  [self.chrome updatePlayback:self.wantsPlayback && !self.playbackEnded current:self.playbackEnded ? self.lastObservedLength / 1000 : current duration:length > 0 ? length : self.lastObservedLength / 1000];
  NSString *warning = self.rewindCache.status.length ? self.rewindCache.status : self.history.status;
  if (warning.length) { self.statusLabel.text = warning; [self.chrome updateDiagnostics]; }
  self.subtitleButton.enabled = !self.reloading;
  [self updateSubtitleSettings];
  CGSize size = self.player.videoSize;
  VLCMediaVideoTrack *video = self.player.media.videoTracks.firstObject.video;
  if (video.sourceAspectRatio > 0 && video.sourceAspectRatioDenominator > 0) {
    size.width *= (double)video.sourceAspectRatio / video.sourceAspectRatioDenominator;
  }
  self.comments.videoSize = size;
  [self updateCommentState];
}

- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)state {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.closing) {
      if (state == VLCMediaPlayerStateStopped) { [self finishClosing]; }
      return;
    }
    if (self.reloading && state == VLCMediaPlayerStateStopped && !self.restoringReload) { [self restartMedia]; return; }
    if (state == VLCMediaPlayerStateError) {
      self.playbackFailed = YES; self.wantsPlayback = NO;
      [self completeSeek:self.seekGeneration failed:YES];
      self.reloading = NO; self.restoringReload = NO;
      [self.reloadTimer invalidate]; self.reloadTimer = nil; [self showControls]; [self.history flush];
    }
    if (state == VLCMediaPlayerStateStopping) { [self rememberPlaybackTime]; }
    if (state == VLCMediaPlayerStateStopped && !self.playbackFailed && !self.reloading &&
      self.lastObservedLength > 0 && self.lastObservedTime >= self.lastObservedLength - 1500) {
      self.playbackEnded = YES; self.wantsPlayback = NO;
      [self completeSeek:self.seekGeneration failed:NO];
      [self.history sample:self.lastObservedLength / 1000.0 duration:self.lastObservedLength / 1000.0 running:NO seeking:NO rate:self.playbackRate];
      [self.history flush]; [self showControls];
    }
    if (state == VLCMediaPlayerStateStopped && !self.playbackEnded && !self.reloading && self.lastObservedTime > 0) {
      self.playbackFailed = YES; self.wantsPlayback = NO;
      [self completeSeek:self.seekGeneration failed:YES]; [self.history flush]; [self showControls];
    }
    if (state == VLCMediaPlayerStatePlaying && !self.reloading && !self.wantsPlayback) { [self.player pause]; }
    self.statusLabel.text = state == VLCMediaPlayerStateError || self.playbackFailed
      ? @"再生エラー · 接続・ファイル形式・認証を確認してください。"
      : [NSString stringWithFormat:@"PLAY · %@ · キャッシュ %ld秒", VLCMediaPlayerStateToString(state), (long)self.networkCaching / 1000];
    [self.commentPiP invalidatePlaybackState]; [self updateControls];
    if (state == VLCMediaPlayerStateStopped) { [self.commentPiP resetVideo]; }
  });
}

- (void)mediaPlayerBufferingChanged:(float)progress {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.buffering = progress < 1;
    if (!self.closing) {
      self.statusLabel.text = progress < 1 ? [NSString stringWithFormat:@"バッファリング %.0f%%", progress * 100]
        : self.reloading ? @"プレイヤーを再読み込みしています…" : @"PLAY · 再生準備完了";
    }
    [self.chrome updateDiagnostics];
    if (!self.buffering) { [self applyPlaybackIntent]; }
    [self.commentPiP invalidatePlaybackState];
  });
}
- (void)mediaPlayerLengthChanged:(int64_t)length {
  dispatch_async(dispatch_get_main_queue(), ^{
    // VLC 4 reports input duration here even when VLCMedia has not been parsed.
    // The pinned VLCKit delegate already converts microseconds to milliseconds.
    if (length > 0) { self.lastObservedLength = length; }
    [self.commentPiP invalidatePlaybackState];
  });
}
- (void)rememberPlaybackTime {
  VLCMediaPlayerState state = self.player.state;
  if (self.playbackEnded || self.seeking ||
      (state != VLCMediaPlayerStatePlaying && state != VLCMediaPlayerStatePaused && state != VLCMediaPlayerStateStopping)) { return; }
  int64_t length = [self mediaLength];
  if (length > 0) {
    self.lastObservedLength = length;
    self.lastObservedTime = MAX(0, self.player.time.value.longLongValue);
  }
}
- (void)mediaPlayerTimeChanged:(NSNotification *)notification { [self rememberPlaybackTime]; }

- (void)interrupted:(NSNotification *)notification {
  if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
    self.resumeAfterInterruption = self.wantsPlayback; [self setPlaybackIntent:NO];
  } else if (self.resumeAfterInterruption &&
    ([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume)) {
    [AVAudioSession.sharedInstance setActive:YES error:nil]; [self setPlaybackIntent:YES]; self.resumeAfterInterruption = NO;
  }
}
- (void)backgrounded { [self.history flush]; if (!self.pipActive) { [self setPlaybackIntent:NO]; } }

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
  [self.movieView addSubview:view];
  [NeoVLCFrameTap bindView:view sink:self.commentPiP];
  if (self.comments) { [self.movieView bringSubviewToFront:self.comments]; }
}
- (CGRect)bounds { return self.movieView.bounds; }
- (void)updatePiPState {
  if (self.closing) { return; }
  BOOL wasActive = self.pipActive; self.pipActive = self.commentPiP.active;
  [self.chrome updatePiP:self.pipActive];
  self.pipButton.enabled = self.frameTapInstalled && self.commentPiP.possible;
  if (!self.frameTapInstalled) { self.commentLabel.text = @"PiP · VLCの映像出力を取得できません。"; }
  if (wasActive && !self.pipActive && UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
    [self.player pause];
  }
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
  return @{@"success": @(waitingIsPlaying && paused && resumed && once && ignoresOld && failedFinishes),
    @"bufferingDoesNotMeanPaused": @(waitingIsPlaying), @"latestPauseIntent": @(paused), @"latestPlayIntent": @(resumed),
    @"completionExactlyOnce": @(once), @"lateSeekCallbackIgnored": @(ignoresOld), @"failedSeekCompletes": @(failedFinishes)};
}
- (void)runEndedSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self setPlaybackIntent:YES];
  [self seekBy:MAX(0, [self mediaLength]-1000)-self.player.time.value.longLongValue completion:^{
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
      completion(@{@"success": @(shown && retained && hidden && revealed), @"naturalEndShowsControls": @(shown),
        @"endedDoesNotAutoHide": @(retained), @"endedTapHides": @(hidden), @"endedTapShows": @(revealed)});
    }); return;
  }
  if (attempt >= 50) { completion(@{@"success": @NO, @"error": @"natural end timed out",
    @"state": @(self.player.state), @"time": self.player.time.value ?: @0, @"mediaLength": @([self mediaLength]),
    @"observedTime": @(self.lastObservedTime), @"seeking": @(self.seeking), @"buffering": @(self.buffering),
    @"wantsPlayback": @(self.wantsPlayback)}); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollEndedSmoke:attempt+1 completion:completion]; });
}
- (void)runVideoTapSmokeWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [self waitForTapSmokePlayback:0 completion:completion];
}
- (void)waitForTapSmokePlayback:(NSInteger)attempt completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  UIView *video = [NeoVLCFrameTap videoViewInView:self.movieView];
  if (!self.player.isPlaying || !video) {
    if (attempt >= 30) { completion(@{@"success": @NO, @"error": @"tap fixture playback did not start"}); return; }
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
  [self seekBy:3000 - self.player.time.value.longLongValue completion:^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf reloadPlayback]; [weakSelf pollReloadSmoke:0 expectedPlaying:NO completion:completion];
    });
  }];
}
- (void)pollReloadSmoke:(NSInteger)attempt expectedPlaying:(BOOL)playing completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (!self.reloading && !self.restoringReload && self.player.isPlaying == playing && self.player.isSeekable) {
    int64_t restored = self.player.time.value.longLongValue;
    BOOL position = llabs(restored - self.reloadTime) < 1000;
    BOOL settings = fabs(self.player.rate - 1.25) < 0.01 && self.networkCaching == 7000;
    BOOL statusCleared = self.statusLabel.isHidden && ![self.statusLabel.text containsString:@"再読み込み"];
    if (!position || !settings || !self.comments.ready || !statusCleared) {
      completion(@{@"success": @NO, @"phase": playing ? @"playing" : @"paused", @"position": @(restored), @"expected": @(self.reloadTime), @"rate": @(self.player.rate)}); return;
    }
    if (!playing) {
      [self.chrome updatePlayback:NO current:restored / 1000 duration:self.player.media.length.value.longLongValue / 1000];
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
  int64_t target = MAX(0, self.player.time.value.longLongValue + offset);
  if (length > 0) { target = MIN(length, target); }
  self.playbackEnded = NO; self.seeking = YES; self.seekCompletion = completion;
  self.lastSeekFailed = NO;
  NSInteger generation = ++self.seekGeneration;
  [self.rewindCache beginSeek:target / 1000.0]; [self.commentPiP seekDiscontinuity];
  __weak typeof(self) weakSelf = self;
  self.seekTimer = [NSTimer timerWithTimeInterval:20 repeats:NO block:^(NSTimer *timer) {
    if (weakSelf.seekGeneration != generation || !weakSelf.seeking || weakSelf.closing) { return; }
    BOOL wasRestoring = weakSelf.restoringReload;
    [weakSelf completeSeek:generation failed:YES];
    if (wasRestoring) { return; }
    // Re-open the same Range endpoint at the requested time. Keep PiP alive;
    // a second deadline bounds recovery instead of leaving it stuck forever.
    weakSelf.reloadTime = target; weakSelf.reloadPlaying = weakSelf.wantsPlayback;
    NSMutableArray *tracks = [NSMutableArray new];
    for (VLCMediaPlayerTrack *track in weakSelf.player.textTracks) { if (track.isSelected) { [tracks addObject:track.trackId]; } }
    weakSelf.reloadTextTracks = tracks;
    weakSelf.reloading = YES; weakSelf.restoringReload = NO; [weakSelf armReloadDeadline];
    [weakSelf.commentPiP seekDiscontinuity]; [weakSelf.player stop];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.seekTimer forMode:NSRunLoopCommonModes];
  BOOL accepted = [self.player jumpWithOffset:(int)(target - self.player.time.value.longLongValue) completion:^{
    [weakSelf completeSeek:generation failed:NO];
  }];
  if (!accepted) { [self completeSeek:generation failed:YES]; }
  [self.commentPiP invalidatePlaybackState]; [self scheduleControlsHide];
}
- (void)completeSeek:(NSInteger)generation failed:(BOOL)failed {
  if (!self.seeking || generation != self.seekGeneration) { return; }
  // Establish the new history position while it is still marked as a seek.
  // Even a short jump or a delayed completion must not become watched time.
  if (!self.closing) { [self sampleHistory]; }
  [self.seekTimer invalidate]; self.seekTimer = nil; self.seeking = NO;
  if (!failed && !self.playbackEnded) { [self rememberPlaybackTime]; }
  self.lastSeekFailed = failed;
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
  self.reloadTimer = [NSTimer timerWithTimeInterval:25 repeats:NO block:^(NSTimer *timer) {
    if (!weakSelf || weakSelf.closing || !weakSelf.reloading) { return; }
    weakSelf.reloading = NO; weakSelf.restoringReload = NO;
    [weakSelf completeSeek:weakSelf.seekGeneration failed:YES]; [weakSelf setPlaybackIntent:NO];
    weakSelf.statusLabel.text = @"再読み込みできませんでした。接続を確認して再試行してください。";
    [weakSelf.chrome updateDiagnostics]; [weakSelf showControls];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.reloadTimer forMode:NSRunLoopCommonModes];
}
- (int64_t)mediaLength { return MAX(self.lastObservedLength, MAX(0, self.player.media.length.value.longLongValue)); }
- (int64_t)mediaTime { return self.player.time.value.longLongValue; }
- (BOOL)isMediaSeekable { return self.player.isSeekable; }
- (BOOL)isMediaPlaying { return self.player.isPlaying; }

- (void)closePlayer {
  if (self.closing) { return; }
  [self sampleHistory]; [self.history finish]; self.closing = YES;
  [self completeSeek:self.seekGeneration failed:NO];
  [self.reloadTimer invalidate]; self.reloadTimer = nil;
  [self.rewindCache close]; self.rewindCache.onChange = nil;
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
- (void)dealloc { [self.timer invalidate]; [self.controlsHideTimer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
