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
@property (nonatomic) UIStackView *header;
@property (nonatomic) UIStackView *controls;
@property (nonatomic) NSArray<NSLayoutConstraint *> *portraitMovieConstraints;
@property (nonatomic) NSArray<NSLayoutConstraint *> *landscapeMovieConstraints;
@property (nonatomic) BOOL landscape;
@property (nonatomic) BOOL layoutConfigured;
@property (nonatomic) CFTimeInterval lastControlsInteraction;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) BOOL pipActive;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL finishedClosing;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL resumeAfterInterruption;
@end

@implementation NeoPlayerController
- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title username:(NSString *)username
                  password:(NSString *)password networkCaching:(NSInteger)networkCaching {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _sourceURL = url; _mediaTitle = title; _username = username;
    _password = password; _networkCaching = networkCaching;
  }
  return self;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setTitle:title forState:UIControlStateNormal];
  button.tintColor = [UIColor colorWithRed:0.13 green:0.59 blue:0.95 alpha:1];
  [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
  return button;
}

- (UILabel *)label {
  UILabel *label = [UILabel new]; label.textColor = UIColor.whiteColor;
  label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  label.numberOfLines = 0; return label;
}

- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
  self.movieView = [UIView new]; self.movieView.backgroundColor = UIColor.blackColor;
  self.movieView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.movieView];
  UILabel *title = [self label]; title.text = self.mediaTitle; title.numberOfLines = 1;
  self.statusLabel = [self label]; self.statusLabel.text = @"PLAY · 準備中";
  self.timeLabel = [self label]; self.timeLabel.text = @"0:00";
  self.playButton = [self button:@"一時停止" action:@selector(togglePlayback)];
  self.pipButton = [self button:@"PiP" action:@selector(startPiP)]; self.pipButton.enabled = NO;
  self.pipButton.accessibilityLabel = @"コメント付きPiP";
  self.subtitleButton = [self button:@"字幕" action:@selector(showSubtitles)];
  self.commentButton = [self button:@"コメント" action:@selector(showComments)];
  self.commentLabel = [self label];
  self.commentLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
  UIButton *back = [self button:@"−10秒" action:@selector(backward)];
  UIButton *forward = [self button:@"＋10秒" action:@selector(forward)];
  UIButton *close = [self button:@"閉じる" action:@selector(closePlayer)];
  [close setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [close setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  self.timeline = [UISlider new]; self.timeline.accessibilityLabel = @"再生位置";
  [self.timeline addTarget:self action:@selector(beginScrubbing) forControlEvents:UIControlEventTouchDown];
  [self.timeline addTarget:self action:@selector(endScrubbing) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
  [self.timeline addTarget:self action:@selector(cancelScrubbing) forControlEvents:UIControlEventTouchCancel];
  UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, close]];
  header.alignment = UIStackViewAlignmentCenter; header.spacing = 16;
  UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[back, self.playButton, forward, self.subtitleButton, self.commentButton, self.pipButton]];
  buttons.distribution = UIStackViewDistributionFillEqually; buttons.spacing = 4;
  UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusLabel, self.commentLabel, self.timeLabel, self.timeline, buttons]];
  controls.axis = UILayoutConstraintAxisVertical; controls.spacing = 6;
  self.header = header; self.controls = controls;
  header.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; header.layer.cornerRadius = 8;
  controls.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; controls.layer.cornerRadius = 8;
  header.translatesAutoresizingMaskIntoConstraints = NO; controls.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:header]; [self.view addSubview:controls];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    [controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
  ]];
  self.portraitMovieConstraints = @[
    [self.movieView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [self.movieView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [self.movieView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
    [self.movieView.bottomAnchor constraintEqualToAnchor:controls.topAnchor constant:-8],
  ];
  self.landscapeMovieConstraints = @[
    [self.movieView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.movieView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [self.movieView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [self.movieView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
  ];
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
    return weakSelf.player.isPlaying && !weakSelf.scrubbing && !weakSelf.buffering && !weakSelf.closing;
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
  [self.player play];
}

- (void)applyPlayerLayout:(CGSize)size {
  BOOL landscape = size.width > size.height;
  if (self.layoutConfigured && landscape == self.landscape) { return; }
  [NSLayoutConstraint deactivateConstraints:self.landscape ? self.landscapeMovieConstraints : self.portraitMovieConstraints];
  self.landscape = landscape; self.layoutConfigured = YES;
  [NSLayoutConstraint activateConstraints:landscape ? self.landscapeMovieConstraints : self.portraitMovieConstraints];
  self.statusLabel.hidden = landscape; self.commentLabel.hidden = landscape;
  self.timeLabel.numberOfLines = 1;
  [self showControls]; [self setNeedsStatusBarAppearanceUpdate];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self applyPlayerLayout:self.view.bounds.size]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    [self applyPlayerLayout:size]; [self.view layoutIfNeeded];
  } completion:nil];
}
- (BOOL)prefersStatusBarHidden { return self.landscape; }
- (BOOL)prefersHomeIndicatorAutoHidden { return self.landscape && self.controls.alpha == 0; }
- (void)showControls {
  self.lastControlsInteraction = CACurrentMediaTime();
  self.header.alpha = 1; self.controls.alpha = 1; [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)toggleControls {
  if (!self.landscape || self.controls.alpha < 1) { [self showControls]; }
  else { self.header.alpha = 0; self.controls.alpha = 0; [self setNeedsUpdateOfHomeIndicatorAutoHidden]; }
}
- (void)togglePlayback { [self showControls]; if (self.player.isPlaying) { [self.player pause]; } else { [self.player play]; } }
- (void)backward { [self showControls]; [self.player jumpWithOffset:-10000 completion:^{}]; }
- (void)forward { [self showControls]; [self.player jumpWithOffset:10000 completion:^{}]; }
- (void)beginScrubbing { [self showControls]; self.scrubbing = YES; }
- (void)cancelScrubbing { self.scrubbing = NO; }
- (void)endScrubbing { if (self.player.isSeekable) { self.player.position = self.timeline.value; } self.scrubbing = NO; }

- (void)showSubtitles {
  [self showControls];
  UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"字幕トラック" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
  __weak typeof(self) weakSelf = self;
  [menu addAction:[UIAlertAction actionWithTitle:@"オフ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    [weakSelf.player deselectAllTextTracks];
  }]];
  for (VLCMediaPlayerTrack *track in self.player.textTracks) {
    [menu addAction:[UIAlertAction actionWithTitle:track.trackName style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      // Explicit VLC selection remains available for comparison and unsupported ASS.
      if ([NeoCommentOverlay isCommentName:track.trackName] || [NeoCommentOverlay isCommentName:track.trackDescription ?: @""]) {
        weakSelf.comments.enabled = NO;
      }
      [weakSelf.player selectTextTracks:@[track]];
    }]];
  }
  [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
  menu.popoverPresentationController.sourceView = self.subtitleButton;
  menu.popoverPresentationController.sourceRect = self.subtitleButton.bounds;
  [self presentViewController:menu animated:YES completion:nil];
}

- (void)showComments { [self showControls]; [self presentViewController:[self.comments makeSettingsController] animated:YES completion:nil]; }

- (void)updateCommentState {
  if (self.closing) { return; }
  self.commentLabel.text = [NSString stringWithFormat:@"%@ · %@%@", self.comments.status,
    self.frameTapInstalled ? self.commentPiP.status ?: @"PiP · 準備中" : @"PiP · VLCの映像出力を取得できません。",
    self.comments.enabled ? @"" : @" · 専用描画オフ"];
  [self.commentPiP updateCommentsFrom:self.comments];
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
  [self.playButton setTitle:self.player.isPlaying ? @"一時停止" : @"再生" forState:UIControlStateNormal];
  self.timeline.enabled = self.player.isSeekable;
  if (!self.scrubbing) { self.timeline.value = self.player.position; }
  int64_t current = MAX(0, self.player.time.value.longLongValue / 1000);
  int64_t length = MAX(0, self.player.media.length.value.longLongValue / 1000);
  self.timeLabel.text = [NSString stringWithFormat:@"%lld:%02lld / %lld:%02lld · %.0f × %.0f",
    current / 60, current % 60, length / 60, length % 60, self.player.videoSize.width, self.player.videoSize.height];
  self.subtitleButton.enabled = self.player.textTracks.count > 0;
  CGSize size = self.player.videoSize;
  VLCMediaVideoTrack *video = self.player.media.videoTracks.firstObject.video;
  if (video.sourceAspectRatio > 0 && video.sourceAspectRatioDenominator > 0) {
    size.width *= (double)video.sourceAspectRatio / video.sourceAspectRatioDenominator;
  }
  self.comments.videoSize = size;
  [self updateCommentState];
  if (self.landscape && self.player.isPlaying && !self.scrubbing && !self.presentedViewController &&
      CACurrentMediaTime() - self.lastControlsInteraction > 4) {
    self.header.alpha = 0; self.controls.alpha = 0; [self setNeedsUpdateOfHomeIndicatorAutoHidden];
  }
}

- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)state {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.closing) {
      if (state == VLCMediaPlayerStateStopped) { [self finishClosing]; }
      return;
    }
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
  CGRect saved = self.view.frame;
  self.view.frame = CGRectMake(0, 0, 844, 390);
  [self applyPlayerLayout:self.view.bounds.size]; [self.view layoutIfNeeded];
  BOOL full = CGRectEqualToRect(self.movieView.frame, self.view.bounds);
  BOOL overlay = self.header.frame.size.height < 80 && CGRectGetMaxY(self.controls.frame) <= 390;
  NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:self.view.bounds.size];
  NSData *landscape = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
    [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
  }];
  [landscape writeToFile:[directory stringByAppendingPathComponent:@"player-landscape-smoke.png"] atomically:YES];
  self.view.frame = saved; [self applyPlayerLayout:self.view.bounds.size]; [self.view layoutIfNeeded];
  return @{@"success": @(full && overlay && self.frameTapInstalled && self.commentPiP.consumedFrameCount >= 24 && self.commentPiP.composedFrameCount >= 24),
    @"landscapeFillsView": @(full), @"controlsOverlay": @(overlay), @"frameTapInstalled": @(self.frameTapInstalled),
    @"capturedFrames": @(self.commentPiP.capturedFrameCount), @"composedFrames": @(self.commentPiP.composedFrameCount),
    @"consumedFrames": @(self.commentPiP.consumedFrameCount),
    @"pipPossible": @(self.commentPiP.possible),
    @"pipStatus": self.commentPiP.status ?: @"", @"commentsReady": @(self.comments.ready)};
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
  [self.comments stop];
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
  [self dismissViewControllerAnimated:YES completion:^{ if (callback) { callback(); } }];
}
- (void)dealloc { [self.timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
