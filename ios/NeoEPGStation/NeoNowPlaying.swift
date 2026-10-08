import UIKit
import MediaPlayer

// One owner per native playback session. Remove only our command targets when
// the player closes; an older session must not clear a newer player's card.
@objc(NeoNowPlaying)
final class NeoNowPlaying: NSObject {
  private static weak var owner: NeoNowPlaying?
  private var targets: [(MPRemoteCommand, Any)] = []
  private var info: [String: Any] = [:]
  private var artworkImage: UIImage?
  private var closed = false
  private var lastPosition = -Double.infinity, lastRate = -1.0, lastDuration = -1.0
  @objc var playAction: (() -> Void)?
  @objc var pauseAction: (() -> Void)?
  @objc var toggleAction: (() -> Void)?
  @objc var seekAction: ((Double) -> Bool)?
  @objc var skipAction: ((Double) -> Bool)?

  @objc(initWithTitle:channel:)
  init(title: String, channel: String) {
    super.init()
    Self.owner?.stop(); Self.owner = self
    info = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: channel,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0]
    let commands = MPRemoteCommandCenter.shared()
    register(commands.playCommand) { [weak self] _ in self?.playAction?(); return .success }
    register(commands.pauseCommand) { [weak self] _ in self?.pauseAction?(); return .success }
    register(commands.togglePlayPauseCommand) { [weak self] _ in self?.toggleAction?(); return .success }
    register(commands.changePlaybackPositionCommand) { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent,
        self?.seekAction?(event.positionTime) == true else { return .commandFailed }
      return .success
    }
    commands.skipBackwardCommand.preferredIntervals = [10]
    commands.skipForwardCommand.preferredIntervals = [10]
    register(commands.skipBackwardCommand) { [weak self] event in
      guard let event = event as? MPSkipIntervalCommandEvent,
        self?.skipAction?(-event.interval) == true else { return .commandFailed }
      return .success
    }
    register(commands.skipForwardCommand) { [weak self] event in
      guard let event = event as? MPSkipIntervalCommandEvent,
        self?.skipAction?(event.interval) == true else { return .commandFailed }
      return .success
    }
    commands.nextTrackCommand.isEnabled = false; commands.previousTrackCommand.isEnabled = false
    commands.seekBackwardCommand.isEnabled = false; commands.seekForwardCommand.isEnabled = false
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func register(_ command: MPRemoteCommand, action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
    command.isEnabled = true
    let target = command.addTarget { [weak self] event in
      guard let self, !self.closed, Self.owner === self else { return .noSuchContent }
      if Thread.isMainThread { return action(event) }
      // The handlers only enqueue native commands; never wait for decoding here.
      return DispatchQueue.main.sync { self.closed ? .noSuchContent : action(event) }
    }
    targets.append((command, target))
  }

  @objc(updateWithPosition:duration:rate:playing:seekable:artwork:)
  func update(position: Double, duration: Double, rate: Double, playing: Bool, seekable: Bool, artwork: UIImage?) {
    guard !closed, Self.owner === self else { return }
    let commands = MPRemoteCommandCenter.shared()
    commands.changePlaybackPositionCommand.isEnabled = seekable
    commands.skipBackwardCommand.isEnabled = seekable; commands.skipForwardCommand.isEnabled = seekable
    let actualRate = playing ? rate : 0
    var changed = abs(position-lastPosition) >= 0.5 || actualRate != lastRate || duration != lastDuration
    if let artwork, artwork !== artworkImage {
      artworkImage = artwork
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
      changed = true
    }
    guard changed else { return }
    lastPosition = position; lastRate = actualRate; lastDuration = duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, position)
    info[MPNowPlayingInfoPropertyPlaybackRate] = actualRate
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    else { info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration) }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  @objc func stop() {
    guard !closed else { return }; closed = true
    for (command, target) in targets { command.removeTarget(target) }
    targets.removeAll()
    if Self.owner === self { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; Self.owner = nil }
    playAction = nil; pauseAction = nil; toggleAction = nil; seekAction = nil; skipAction = nil
  }
  deinit { for (command, target) in targets { command.removeTarget(target) } }

#if targetEnvironment(simulator)
  @objc func smokeMetadata() -> [String: Any] {
    ["titleRegistered": info[MPMediaItemPropertyTitle] != nil,
      "position": info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?? -1,
      "rate": info[MPNowPlayingInfoPropertyPlaybackRate] ?? -1,
      "targets": targets.count, "seekEnabled": MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled]
  }
#endif
}
