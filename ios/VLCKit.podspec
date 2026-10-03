# Binary and checksum from VideoLAN's Package.swift at revision
# 2e0868f5ed40fe59cd92f377645fdcc260c6e759.
Pod::Spec.new do |s|
  s.name = 'VLCKit'
  s.version = '4.0.0a25'
  s.summary = 'VideoLAN libVLC wrapper for Apple platforms'
  s.homepage = 'https://code.videolan.org/videolan/VLCKit'
  s.authors = 'VideoLAN'
  s.license = { :type => 'LGPL-2.1-or-later', :file => 'COPYING.txt' }
  s.source = {
    :http => 'https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip',
    :sha256 => 'f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb'
  }
  s.vendored_frameworks = 'VLCKit.xcframework'
  s.ios.deployment_target = '18.0'
  s.frameworks = 'Foundation'
  s.libraries = 'iconv'
  s.requires_arc = false
end
