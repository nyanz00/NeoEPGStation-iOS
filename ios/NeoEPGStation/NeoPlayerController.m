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
@property (nonatomic) CFTimeInterval lastControlsInteraction;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) BOOL pipActive;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL finishedClosing;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL resumeAfterInterruption;
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
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)];
  tap.cancelsTouchesInView = NO; [self.movieView addGestureRecognizer:tap];
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
  VLCMedia *media = [VLCMedia mediaWithURL:self.sourceURL];
  [media addOption:[NSString stringWithFormat:@":network-caching=%ld", (long)self.networkCaching]];
  self.player.media = media;
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
    return weakSelf.player.isPlaying && !weakSelf.scrubbing && !weakSelf.buffering && !weakSelf.closing && !weakSelf.reloading;
  };
  self.comments.onChange = ^{ [weakSelf updateCommentState]; };
  [self.movieView addSubview:self.comments];
  self.frameTapInstalled = [NeoVLCFrameTap install];
  self.commentPiP = [NeoCommentPiP new];
  self.commentPiP.view.frame = self.movieView.bounds;
  self.commentPiP.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.movieView insertSubview:self.commentPiP.view atIndex:0];
  self.commentPiP.timeProvider = self.comments.timeProvider;
  self.commentPiP.lengthProvider = ^double { return weakSelf.player.media.length.value.doubleValue / 1000.0; };
  self.commentPiP.runningProvider = self.comments.runningProvider;
  self.commentPiP.playAction = ^{ [weakSelf.player play]; };
  self.commentPiP.pauseAction = ^{ [weakSelf.player pause]; };
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
  [self showControls]; [self.player play];
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
- (void)showControls {
  self.lastControlsInteraction = CACurrentMediaTime();
  [self.chrome showControls:YES]; [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)toggleControls {
  if (self.chrome.interactionOpen) { [self showControls]; return; }
  [self.chrome showControls:!self.chrome.controlsVisible];
  self.lastControlsInteraction = CACurrentMediaTime(); [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)performPlayerAction:(NSString *)action {
  if (self.closing) { return; }
  [self showControls];
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
  else if ([action hasPrefix:@"subtitle:"]) {
    NSInteger index = [action substringFromIndex:9].integerValue;
    if (index < 0) { [self.player deselectAllTextTracks]; }
    else if (index < self.player.textTracks.count) {
      VLCMediaPlayerTrack *track = self.player.textTracks[index];
      if ([NeoCommentOverlay isCommentName:track.trackName] || [NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) { self.comments.enabled = NO; }
      [self.player selectTextTracks:@[track]];
    }
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
  self.reloadTime = MAX(0, self.player.time.value.longLongValue); self.reloadPlaying = self.player.isPlaying;
  NSMutableArray *tracks = [NSMutableArray new];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) { if (track.isSelected) { [tracks addObject:track.trackId]; } }
  self.reloadTextTracks = tracks; self.reloading = YES; self.restoringReload = NO;
  self.statusLabel.text = @"プレイヤーを再読み込みしています…"; [self.chrome updateDiagnostics];
  [self.commentPiP resetVideo];
  if (self.player.state == VLCMediaPlayerStateStopped || self.player.state == VLCMediaPlayerStateNothingSpecial) { [self restartMedia]; }
  else { [self.player stop]; }
}
- (void)restartMedia {
  VLCMedia *media = [VLCMedia mediaWithURL:self.sourceURL];
  [media addOption:[NSString stringWithFormat:@":network-caching=%ld", (long)self.networkCaching]];
  self.player.media = media; [self.player play];
}
- (void)restoreReloadIfReady {
  if (!self.reloading || self.restoringReload || !self.player.isSeekable || self.player.state != VLCMediaPlayerStatePlaying) { return; }
  self.restoringReload = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_block_t restore = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      if (weakSelf.closing) { return; }
      weakSelf.player.rate = weakSelf.playbackRate;
      [weakSelf.player deselectAllTextTracks];
      for (VLCMediaPlayerTrack *track in weakSelf.player.textTracks) { if ([weakSelf.reloadTextTracks containsObject:track.trackId]) { track.selected = YES; } }
      if (!weakSelf.reloadPlaying) { [weakSelf.player pause]; }
      weakSelf.reloading = NO; weakSelf.restoringReload = NO;
      [weakSelf.commentPiP invalidatePlaybackState]; [weakSelf updateControls];
    });
  };
  [self seekBy:self.reloadTime - self.player.time.value.longLongValue completion:restore];
}
- (void)togglePlayback { [self showControls]; if (self.player.isPlaying) { [self.player pause]; } else { [self.player play]; } }
- (void)beginScrubbing { [self showControls]; self.scrubbing = YES; }
- (void)cancelScrubbing { self.scrubbing = NO; }
- (void)endScrubbing { if (self.player.isSeekable) { self.player.position = self.timeline.value; } self.scrubbing = NO; }

- (void)showSubtitles {
  [self showControls]; NSMutableArray *names = [NSMutableArray new];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) { [names addObject:track.trackName ?: @"字幕"]; }
  [self.chrome showSubtitleChoices:names];
}

- (void)showComments { [self showControls]; [self presentViewController:[self.comments makeSettingsController] animated:YES completion:nil]; }

- (void)updateCommentState {
  if (self.closing) { return; }
  self.commentLabel.text = [NSString stringWithFormat:@"%@ · %@%@", self.comments.status,
    self.frameTapInstalled ? self.commentPiP.status ?: @"PiP · 準備中" : @"PiP · VLCの映像出力を取得できません。",
    self.comments.enabled ? @"" : @" · 専用描画オフ"];
  [self.commentPiP updateCommentsFrom:self.comments];
  if (self.chrome.commentVersion != self.comments.panelVersion) { [self.chrome setCommentRows:[self.comments panelComments] version:self.comments.panelVersion]; }
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
  self.timeline.enabled = self.player.isSeekable;
  if (!self.scrubbing) { self.timeline.value = self.player.position; }
  int64_t current = MAX(0, self.player.time.value.longLongValue / 1000);
  int64_t length = MAX(0, self.player.media.length.value.longLongValue / 1000);
  [self.chrome updatePlayback:self.player.isPlaying current:current duration:length];
  self.subtitleButton.enabled = self.player.textTracks.count > 0;
  CGSize size = self.player.videoSize;
  VLCMediaVideoTrack *video = self.player.media.videoTracks.firstObject.video;
  if (video.sourceAspectRatio > 0 && video.sourceAspectRatioDenominator > 0) {
    size.width *= (double)video.sourceAspectRatio / video.sourceAspectRatioDenominator;
  }
  self.comments.videoSize = size;
  [self updateCommentState];
  if (self.chrome.autoHide && !self.chrome.interactionOpen && self.player.isPlaying && !self.scrubbing && !self.presentedViewController &&
      CACurrentMediaTime() - self.lastControlsInteraction > 4) {
    [self.chrome showControls:NO]; [self setNeedsUpdateOfHomeIndicatorAutoHidden];
  }
}

- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)state {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.closing) {
      if (state == VLCMediaPlayerStateStopped) { [self finishClosing]; }
      return;
    }
    if (self.reloading && state == VLCMediaPlayerStateStopped && !self.restoringReload) { [self restartMedia]; return; }
    if (state == VLCMediaPlayerStateError) { self.reloading = NO; self.restoringReload = NO; }
    self.statusLabel.text = state == VLCMediaPlayerStateError
      ? @"再生エラー · 接続・ファイル形式・認証を確認してください。"
      : [NSString stringWithFormat:@"PLAY · %@ · キャッシュ %ld秒", VLCMediaPlayerStateToString(state), (long)self.networkCaching / 1000];
    [self.commentPiP invalidatePlaybackState]; [self updateControls];
    if (state == VLCMediaPlayerStateStopped) { [self.commentPiP resetVideo]; }
  });
}

- (void)mediaPlayerBufferingChanged:(float)progress {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.buffering = progress < 1;
    if (!self.closing && progress < 1) { self.statusLabel.text = [NSString stringWithFormat:@"バッファリング %.0f%%", progress * 100]; }
    [self.chrome updateDiagnostics];
  });
}
- (void)mediaPlayerLengthChanged:(int64_t)length { dispatch_async(dispatch_get_main_queue(), ^{ [self.commentPiP invalidatePlaybackState]; }); }

- (void)interrupted:(NSNotification *)notification {
  if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
    self.resumeAfterInterruption = self.player.isPlaying; [self.player pause];
  } else if (self.resumeAfterInterruption &&
    ([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume)) {
    [AVAudioSession.sharedInstance setActive:YES error:nil]; [self.player play]; self.resumeAfterInterruption = NO;
  }
}
- (void)backgrounded { if (!self.pipActive) { [self.player pause]; } }

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
  [self.movieView addSubview:view];
  [NeoVLCFrameTap bindView:view sink:self.commentPiP];
  if (self.comments) { [self.movieView bringSubviewToFront:self.comments]; }
}
- (CGRect)bounds { return self.movieView.bounds; }
- (void)updatePiPState {
  if (self.closing) { return; }
  BOOL wasActive = self.pipActive; self.pipActive = self.commentPiP.active;
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
- (NSDictionary<NSString *, id> *)runLayoutSmokeChecks {
  self.chrome.autoHide = NO; [self showControls];
  self.smokeSavedFrame = self.view.frame;
  self.view.frame = CGRectMake(0, 0, 844, 390);
  [self applyPlayerLayout:self.view.bounds.size]; [self.view layoutIfNeeded];
  BOOL full = CGRectEqualToRect(self.movieView.frame, self.view.bounds);
  BOOL overlay = self.header.frame.size.height < 80 && CGRectGetMaxY(self.controls.frame) <= 390;
  NSDictionary *layout = [self.chrome runLayoutChecks];
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
  [self.player pause]; [self performPlayerAction:@"rate:1.25"]; [self performPlayerAction:@"cache:7"];
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
    if (!position || !settings || !self.comments.ready) {
      completion(@{@"success": @NO, @"phase": playing ? @"playing" : @"paused", @"position": @(restored), @"expected": @(self.reloadTime), @"rate": @(self.player.rate)}); return;
    }
    if (!playing) {
      [self.player play];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reloadPlayback]; [self pollReloadSmoke:0 expectedPlaying:YES completion:completion];
      });
    } else {
      [self setOrientation:@"landscape"];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL locked = self.orientationMask == UIInterfaceOrientationMaskLandscapeRight && self.view.window.windowScene.interfaceOrientation == UIInterfaceOrientationLandscapeRight;
        [self setOrientation:@"portrait"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          BOOL portrait = self.orientationMask == UIInterfaceOrientationMaskPortrait && self.view.window.windowScene.interfaceOrientation == UIInterfaceOrientationPortrait;
          [self setOrientation:@"auto"];
          completion(@{@"success": @(locked && portrait), @"pausedReload": @YES, @"playingReload": @YES, @"positionPreserved": @(position), @"ratePreserved": @(settings), @"commentsPreserved": @(self.comments.ready), @"landscapeLock": @(locked), @"portraitLock": @(portrait), @"autoOrientation": @(self.orientationMask == UIInterfaceOrientationMaskAllButUpsideDown)});
        });
      });
    }
    return;
  }
  if (attempt >= 30 || self.player.state == VLCMediaPlayerStateError) { completion(@{@"success": @NO, @"error": @"reload timed out", @"reloading": @(self.reloading), @"restoring": @(self.restoringReload), @"state": VLCMediaPlayerStateToString(self.player.state)}); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollReloadSmoke:attempt + 1 expectedPlaying:playing completion:completion]; });
}
- (BOOL)startPiPSmoke {
  if (!self.commentPiP.possible) { return NO; }
  [self.commentPiP start]; return YES;
}
- (NSDictionary<NSString *, id> *)piPSmokeState {
  return @{@"pipActive": @(self.commentPiP.active), @"pipPossible": @(self.commentPiP.possible),
    @"pipSupported": @([AVPictureInPictureController isPictureInPictureSupported]),
    @"pipStatus": self.commentPiP.status ?: @"", @"capturedFrames": @(self.commentPiP.capturedFrameCount),
    @"composedFrames": @(self.commentPiP.composedFrameCount), @"consumedFrames": @(self.commentPiP.consumedFrameCount)};
}
#endif
- (void)play { [self.player play]; }
- (void)pause { [self.player pause]; }
- (void)seekBy:(int64_t)offset completion:(dispatch_block_t)completion {
  if (![self.player jumpWithOffset:(int)offset completion:completion]) { completion(); }
}
- (int64_t)mediaLength { return self.player.media.length.value.longLongValue; }
- (int64_t)mediaTime { return self.player.time.value.longLongValue; }
- (BOOL)isMediaSeekable { return self.player.isSeekable; }
- (BOOL)isMediaPlaying { return self.player.isPlaying; }

- (void)closePlayer {
  if (self.closing) { return; } self.closing = YES;
  self.view.userInteractionEnabled = NO;
  [self.timer invalidate]; self.timer = nil;
  [self.comments stop]; [self.chrome shutdown];
  self.orientationMask = UIInterfaceOrientationMaskAllButUpsideDown; [self setNeedsUpdateOfSupportedInterfaceOrientations];
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
  [self dismissViewControllerAnimated:YES completion:^{
    if (callback) { callback(); }
    if (route && navigate) { navigate(route); }
    else if (recordingID > 0 && recording) { recording(recordingID); }
  }];
}
- (void)dealloc { [self.timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
