#import "NeoPlayerController.h"
#import <AVFoundation/AVFoundation.h>
#import <VLCKit/VLCKit.h>
#import "NeoEPGStation-Swift.h"

@interface NeoPlayerController () <VLCDrawable, VLCPictureInPictureDrawable,
  VLCPictureInPictureMediaControlling, VLCMediaPlayerDelegate, VLCCustomDialogRendererProtocol>
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
@property (nonatomic, weak) id<VLCPictureInPictureWindowControlling> pipController;
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
  UILabel *title = [self label]; title.text = self.mediaTitle;
  self.statusLabel = [self label]; self.statusLabel.text = @"PLAY · 準備中";
  self.timeLabel = [self label]; self.timeLabel.text = @"0:00";
  self.playButton = [self button:@"一時停止" action:@selector(togglePlayback)];
  self.pipButton = [self button:@"PiP" action:@selector(startPiP)]; self.pipButton.enabled = NO;
  self.pipButton.accessibilityLabel = @"PiP（専用コメントの合成は未対応）";
  self.subtitleButton = [self button:@"字幕" action:@selector(showSubtitles)];
  self.commentButton = [self button:@"コメント" action:@selector(showComments)];
  self.commentLabel = [self label];
  self.commentLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
  UIButton *back = [self button:@"−10秒" action:@selector(backward)];
  UIButton *forward = [self button:@"＋10秒" action:@selector(forward)];
  UIButton *close = [self button:@"閉じる" action:@selector(closePlayer)];
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
    [self.movieView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [self.movieView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [self.movieView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
    [self.movieView.bottomAnchor constraintEqualToAnchor:controls.topAnchor constant:-8],
  ]];
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
  [self.comments configureWithSource:self.sourceURL username:self.username password:self.password];
  [self updateCommentState];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf updateControls]; }];
  [self.player play];
}

- (void)togglePlayback { if (self.player.isPlaying) { [self.player pause]; } else { [self.player play]; } }
- (void)backward { [self.player jumpWithOffset:-10000 completion:^{}]; }
- (void)forward { [self.player jumpWithOffset:10000 completion:^{}]; }
- (void)beginScrubbing { self.scrubbing = YES; }
- (void)cancelScrubbing { self.scrubbing = NO; }
- (void)endScrubbing { if (self.player.isSeekable) { self.player.position = self.timeline.value; } self.scrubbing = NO; }

- (void)showSubtitles {
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

- (void)showComments { [self presentViewController:[self.comments makeSettingsController] animated:YES completion:nil]; }

- (void)updateCommentState {
  if (self.closing) { return; }
  self.commentLabel.text = [NSString stringWithFormat:@"%@%@", self.comments.status,
    self.comments.enabled ? (self.comments.ready ? @" · PiP合成未対応" : @"") : @" · 専用描画オフ"];
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
    [self.pipController invalidatePlaybackState]; [self updateControls];
  });
}

- (void)mediaPlayerBufferingChanged:(float)progress {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.buffering = progress < 1;
    if (!self.closing && progress < 1) { self.statusLabel.text = [NSString stringWithFormat:@"バッファリング %.0f%%", progress * 100]; }
  });
}
- (void)mediaPlayerLengthChanged:(int64_t)length { dispatch_async(dispatch_get_main_queue(), ^{ [self.pipController invalidatePlaybackState]; }); }

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
  if (self.comments) { [self.movieView bringSubviewToFront:self.comments]; }
}
- (CGRect)bounds { return self.movieView.bounds; }
- (id<VLCPictureInPictureMediaControlling>)mediaController { return self; }
- (void (^)(id<VLCPictureInPictureWindowControlling>))pictureInPictureReady {
  __weak typeof(self) weakSelf = self;
  return ^(id<VLCPictureInPictureWindowControlling> controller) {
    dispatch_async(dispatch_get_main_queue(), ^{
      weakSelf.pipController = controller; weakSelf.pipButton.enabled = YES;
      controller.stateChangeEventHandler = ^(BOOL started) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.pipActive = started; });
      };
    });
  };
}
- (void)startPiP {
  [self.pipController startPictureInPicture];
}
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
  self.pipController.stateChangeEventHandler = nil; [self.pipController stopPictureInPicture]; self.pipController = nil;
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
