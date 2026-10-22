# Built from these exact sources by scripts/build-vlckit.sh. CocoaPods only
# links the locally assembled xcframework; it must not fetch an unpatched zip.
Pod::Spec.new do |s|
  s.name = 'VLCKit'
  s.version = '4.0.0a25'
  s.summary = 'VideoLAN libVLC wrapper with AV1 VideoToolbox support'
  s.homepage = 'https://code.videolan.org/videolan/VLCKit'
  s.authors = 'VideoLAN'
  s.license = { :type => 'LGPL-2.1-or-later', :file => 'COPYING' }
  s.source = { :git => 'https://github.com/videolan/vlckit.git', :commit => '2e0868f5ed40fe59cd92f377645fdcc260c6e759' }
  s.vendored_frameworks = 'VLCKit.xcframework'
  s.ios.deployment_target = '18.0'
  s.frameworks = 'Foundation'
  s.libraries = 'iconv'
  s.requires_arc = false
end
